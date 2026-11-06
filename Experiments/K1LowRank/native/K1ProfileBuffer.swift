import Foundation
import Metal
import MetalPerformanceShaders

/// Serial benchmark only. This deliberately tests whether deferring MPS's
/// intermediate submissions is viable; it is not an application capability.
public enum K1BenchmarkSubmission {
    public static var deferIntermediateCommits = false
}

public enum K1BenchmarkGraph {
    public static var nativeLeakyReLU = false
}

/// Diagnostic only. Cost comparisons leave this switch off and use the
/// unmodified MPSCommandBuffer class. No extra commits or synchronization.
enum K1CommandBuffers {
    static let profiling = ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] == "1"

    static func make(_ buffer: MTLCommandBuffer) -> MPSCommandBuffer {
        if profiling { return K1ProfileBuffer(commandBuffer: buffer) }
        if K1BenchmarkSubmission.deferIntermediateCommits { return K1DeferredBuffer(commandBuffer: buffer) }
        return MPSCommandBuffer(commandBuffer: buffer)
    }
}

private final class K1DeferredBuffer: MPSCommandBuffer {
    // Experimental scheduling intervention. The caller still commits/waits at
    // the ordinary end. MPS may require intermediate commits on other paths;
    // this override must not be promoted without broader runtime validation.
    override func commitAndContinue() {}
}

private final class K1ProfileBuffer: MPSCommandBuffer {
    private let deferred = K1BenchmarkSubmission.deferIntermediateCommits
    private let began = DispatchTime.now().uptimeNanoseconds
    private var roots: [MTLCommandBuffer] = []
    private var identities = Set<ObjectIdentifier>()
    private var checkpoints: [[String: Any]] = []
    private var splits = 0

    override init(commandBuffer: MTLCommandBuffer) {
        super.init(commandBuffer: commandBuffer)
        mark("created")
    }

    private func rememberRoot() {
        let root = rootCommandBuffer
        if identities.insert(ObjectIdentifier(root as AnyObject)).inserted { roots.append(root) }
    }

    override func commitAndContinue() {
        rememberRoot()
        splits += 1
        if deferred { return }
        super.commitAndContinue()
        rememberRoot()
    }

    func mark(_ name: String) {
        rememberRoot()
        checkpoints.append(["name": name, "host_ms": Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6,
                            "observed_buffers": roots.count])
    }

    func snapshot() -> [String: Any] {
        mark("completed")
        let segments: [[String: Any]] = roots.enumerated().map { index, buffer in
            ["index": index, "status": buffer.status.rawValue,
             "gpu_start_s": buffer.gpuStartTime, "gpu_end_s": buffer.gpuEndTime,
             "kernel_start_s": buffer.kernelStartTime, "kernel_end_s": buffer.kernelEndTime]
        }
        return ["segments": segments, "checkpoints": checkpoints, "observed_split_calls": splits,
                "intermediate_commits_deferred": deferred,
                "all_observed_buffers_completed": roots.allSatisfy { $0.status == .completed },
                "coverage": "roots observed at overridden commitAndContinue and explicit checkpoints; requires independent trace before claiming exhaustive coverage",
                "timing_scope": "command-buffer GPU residency intervals, not active shader cycles"]
    }
}

extension MPSCommandBuffer {
    func k1Mark(_ name: String) { (self as? K1ProfileBuffer)?.mark(name) }
    func k1ProfileSnapshot() -> [String: Any] { (self as? K1ProfileBuffer)?.snapshot() ?? [:] }
}
