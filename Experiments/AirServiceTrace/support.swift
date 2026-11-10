import Foundation
import Metal
import MetalPerformanceShaders
import Darwin

/// Scalar snapshot. Zero timing fields are unavailable unless their validity bit is set.
/// validityMask: 1=create observation, 2=commit bracket, 4=wait bracket, 8=status,
/// 16=GPU interval, 32=kernel interval. coverageFlags: 1=tracked, 2=unobserved root,
/// 4=incomplete/error, 8=capacity overflow. commitKind: 0=none, 1=explicit, 2=MPS split.
public struct AirServiceTraceRecord: Sendable {
    public var jobID: UInt64 = 0
    public var stage: UInt32 = 0
    public var rootIndex: UInt32 = 0
    public var createHostTicks: UInt64 = 0
    public var commitBeginHostTicks: UInt64 = 0
    public var commitEndHostTicks: UInt64 = 0
    public var waitBeginHostTicks: UInt64 = 0
    public var waitEndHostTicks: UInt64 = 0
    public var commitKind: UInt32 = 0
    public var status: UInt32 = 0
    public var validityMask: UInt32 = 0
    public var coverageFlags: UInt32 = 0
    public var gpuStartSeconds: Double = 0
    public var gpuEndSeconds: Double = 0
    public var kernelStartSeconds: Double = 0
    public var kernelEndSeconds: Double = 0

    public init() {}
}

/// Single-context scratch, serialized by the caller's existing execution path.
/// No callbacks mutate this storage. Begin/read must not run concurrently with inference.
/// Stages: 1=stream creation, 2=cache prime, 3=main push, 4=stateless fallback.
package final class AirServiceTraceCollector {
    private static let capacity = 128
    private var rows = [AirServiceTraceRecord](repeating: .init(), count: AirServiceTraceCollector.capacity)
    private var roots = [MTLCommandBuffer?](repeating: nil, count: AirServiceTraceCollector.capacity)
    private var jobID: UInt64 = 0
    private var stage: UInt32 = 0
    private var nextRootIndex: UInt32 = 0
    package private(set) var isActive = false
    package private(set) var count = 0
    package private(set) var overflow: UInt64 = 0

    package init() {}

    package func begin(jobID: UInt64, stage: UInt32) {
        // Normally every old reference was released after an existing wait. If inference
        // threw first, preserve pending roots and their original IDs until a later wait.
        // Such rows may recur in a later snapshot: last copied (jobID,stage,rootIndex) wins.
        var kept = 0
        for index in 0..<count {
            if let root = roots[index] {
                rows[kept] = rows[index]
                roots[kept] = root
                if kept != index { roots[index] = nil }
                kept += 1
            }
        }
        for index in kept..<Self.capacity {
            rows[index] = .init()
            roots[index] = nil
        }
        self.jobID = jobID
        self.stage = stage
        nextRootIndex = 0
        for index in 0..<kept where rows[index].jobID == jobID && rows[index].stage == stage {
            nextRootIndex = max(nextRootIndex, rows[index].rootIndex &+ 1)
        }
        count = kept
        overflow = 0
        isActive = true
    }

    package func record(at index: Int) -> AirServiceTraceRecord {
        guard index >= 0 && index < count else { return .init() }
        return rows[index]
    }

    @discardableResult
    package func observe(_ root: MTLCommandBuffer, knownNew: Bool) -> Int? {
        for index in 0..<count {
            if let candidate = roots[index], candidate === root { return index }
        }
        guard count < Self.capacity else {
            overflow &+= 1
            for index in 0..<count { rows[index].coverageFlags |= 4 | 8 }
            return nil
        }
        let index = count
        count += 1
        var row = AirServiceTraceRecord()
        row.jobID = jobID
        row.stage = stage
        row.rootIndex = nextRootIndex
        nextRootIndex &+= 1
        // First-observed tick, not Apple's private allocation instant. In a split the
        // new root becomes observable only when super.commitAndContinue returns.
        row.createHostTicks = mach_absolute_time()
        row.validityMask = 1
        row.coverageFlags = knownNew ? (1 | 4) : (1 | 2 | 4)
        rows[index] = row
        roots[index] = root
        return index
    }

    package func beginCommit(_ root: MTLCommandBuffer, kind: UInt32) -> Int? {
        guard let index = observe(root, knownNew: false) else { return nil }
        rows[index].commitKind = kind
        rows[index].commitBeginHostTicks = mach_absolute_time()
        return index
    }

    package func endCommit(_ index: Int?) {
        guard let index else { return }
        rows[index].commitEndHostTicks = mach_absolute_time()
        rows[index].validityMask |= 2
    }

    package func beginWait(_ root: MTLCommandBuffer) -> Int? {
        guard let index = observe(root, knownNew: false) else { return nil }
        rows[index].waitBeginHostTicks = mach_absolute_time()
        return index
    }

    package func endWait(_ index: Int?) {
        if let index {
            rows[index].waitEndHostTicks = mach_absolute_time()
            rows[index].validityMask |= 4
        }
        // Called only after the runtime's original wait. Earlier split roots remain on
        // the same serial Metal queue. A nonterminal row stays incomplete and retained.
        for slot in 0..<count {
            guard let root = roots[slot] else { continue }
            let status = root.status
            rows[slot].status = UInt32(status.rawValue)
            rows[slot].validityMask |= 8
            if status == .completed {
                let gpuStart = root.gpuStartTime
                let gpuEnd = root.gpuEndTime
                if gpuStart.isFinite && gpuEnd.isFinite && gpuStart > 0 && gpuEnd >= gpuStart {
                    rows[slot].gpuStartSeconds = gpuStart
                    rows[slot].gpuEndSeconds = gpuEnd
                    rows[slot].validityMask |= 16
                }
                let kernelStart = root.kernelStartTime
                let kernelEnd = root.kernelEndTime
                if kernelStart.isFinite && kernelEnd.isFinite && kernelStart > 0 && kernelEnd >= kernelStart {
                    rows[slot].kernelStartSeconds = kernelStart
                    rows[slot].kernelEndSeconds = kernelEnd
                    rows[slot].validityMask |= 32
                }
                if rows[slot].validityMask & (2 | 16) == (2 | 16),
                   rows[slot].coverageFlags & (2 | 8) == 0 {
                    rows[slot].coverageFlags &= ~UInt32(4)
                }
            }
            if status == .completed || status == .error ||
               (status == .notEnqueued && rows[slot].commitKind == 0) {
                roots[slot] = nil
            }
        }
    }
}

private final class AirServiceTraceCommandBuffer: MPSCommandBuffer {
    private let trace: AirServiceTraceCollector

    init(commandBuffer: MTLCommandBuffer, collector: AirServiceTraceCollector) {
        trace = collector
        super.init(commandBuffer: commandBuffer)
        collector.observe(rootCommandBuffer, knownNew: true)
    }

    override func commitAndContinue() {
        let oldRoot = rootCommandBuffer
        let index = trace.beginCommit(oldRoot, kind: 2)
        // This bracket includes MPS's replacement-root creation. It is not an exact
        // timestamp of the private underlying MTLCommandBuffer.commit invocation.
        super.commitAndContinue()
        trace.endCommit(index)
        trace.observe(rootCommandBuffer, knownNew: true)
    }
}

package func airServiceTraceMakeMPSCommandBuffer(
    commandBuffer: MTLCommandBuffer, collector: AirServiceTraceCollector?
) -> MPSCommandBuffer {
    guard let collector, collector.isActive else {
        return MPSCommandBuffer(commandBuffer: commandBuffer)
    }
    return AirServiceTraceCommandBuffer(commandBuffer: commandBuffer, collector: collector)
}

/// The before/after-encode sentinel cannot reconstruct a bypassed private split. It
/// marks an unexpected root as unobserved/incomplete instead of claiming full coverage.
package func airServiceTraceObserveRoot(
    _ command: MPSCommandBuffer, collector: AirServiceTraceCollector?
) {
    guard let collector, collector.isActive else { return }
    collector.observe(command.rootCommandBuffer, knownNew: false)
}

package func airServiceTraceCommit(
    _ command: MPSCommandBuffer, collector: AirServiceTraceCollector?
) {
    guard let collector, collector.isActive else { command.commit(); return }
    let index = collector.beginCommit(command.rootCommandBuffer, kind: 1)
    command.commit()
    collector.endCommit(index)
}

package func airServiceTraceWaitUntilCompleted(
    _ command: MPSCommandBuffer, collector: AirServiceTraceCollector?
) {
    guard let collector, collector.isActive else { command.waitUntilCompleted(); return }
    let index = collector.beginWait(command.rootCommandBuffer)
    command.waitUntilCompleted()
    collector.endWait(index)
}
