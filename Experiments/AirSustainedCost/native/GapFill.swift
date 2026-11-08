import Foundation
import Metal

struct GapFillRecord: Encodable {
    let fillID: UInt64
    let phase: String
    let iterations: UInt32
    let plannedNextTickNs: UInt64?
    let guardNs: UInt64?
    let commitBeginNs: UInt64
    let commitEndNs: UInt64
    let guardBoundary: String
    var status: UInt32 = 0
    var validityMask: UInt32 = 1
    var gpuStartSeconds: Double = 0
    var gpuEndSeconds: Double = 0
    var durationMs: Double?
    var completedObservationNs: UInt64?
    var error: String?
}

struct GapFillCalibration: Encodable {
    let initialIterations: UInt32 = 256
    let targetMilliseconds: Double = 1
    let pilotCount = 5, validationCount = 5
    let minimumValidationMs: Double = 0.5, maximumValidationMs: Double = 2
    let iterationConversion = "initialIterations * 1ms / pilotMedianMs; nearest, tiesAwayFromZero; out-of-UInt32 or <1 fails, no clamping/recalibration"
    var status = "not_started"
    var pilotMedianMs: Double?
    var scaledIterations: UInt32?
    var validationMedianMs: Double?
    var passed = false
    var firstFailure: String?
    var records: [GapFillRecord] = []
}

struct GapFillReport: Encodable {
    let enabled = true
    let contractVersion = "opus-gap-fill-20261109-v1"
    let deviceRegistryID: UInt64
    let queueLabel = "ODF independent gap-fill diagnostic"
    let gridThreads = 65_536, scratchBytes = 262_144
    let storageMode = "private; fill-only, no model resource shared"
    let guardMilliseconds = 3
    let recordCapacity = 1_000_000
    let recordAccounting = "fillID and recordsAttempted include all committed pilot, validation and operational CBs; recordsDropped has the same scope. Guard-rejected uncommitted encodings are counted separately."
    let validityMaskMeaning = "1=commit bracket, 2=terminal status, 4=valid completed GPU interval; complete=7"
    let gpuTimeScope = "Command-buffer residency seconds, not active cycles or measured frequency. No RIFE trace helper is used."
    let cpuClock = "DispatchTime.uptimeNanoseconds, same coordinate as real job walls and targetNs"
    var calibration = GapFillCalibration()
    var fills: [GapFillRecord] = []
    var recordsAttempted = 0
    var recordsDropped = 0
    var overflow = false
    var guardRejectedBeforeCommitCount = 0
    var boundaryUnknownCount = 0
    var unknownTimingCount = 0
    var completionFailure: String?
    var pendingFillIDAtFinish: UInt64?
    var pendingStatusAtFinish: UInt32?
    var finishWaitBeginNs: UInt64?
    var finishWaitEndNs: UInt64?
    var finalPendingUnresolved = false
}

struct GapFillAtRealStart {
    let lastFillID: UInt64?
    let inFlight: Bool
    let observedNs: UInt64
}

/// One serial caller; at most one independently queued fill CB in flight.
final class GapFill {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let scratch: MTLBuffer
    private var pending: (buffer: MTLCommandBuffer, record: GapFillRecord)?
    private var nextID: UInt64 = 1
    private var lastCommittedID: UInt64?
    private var iterations: UInt32 = 256
    private(set) var report: GapFillReport

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 1),
              let scratch = device.makeBuffer(length: 262_144, options: .storageModePrivate),
              let libraryURL = Bundle.module.url(forResource: "gap-fill", withExtension: "metallib") else {
            throw SustainedError.native("gap-fill independent resources unavailable")
        }
        let library = try device.makeLibrary(URL: libraryURL)
        guard let function = library.makeFunction(name: "air_gap_fill") else {
            throw SustainedError.native("offline gap-fill function missing")
        }
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue; self.scratch = scratch
        self.queue.label = "ODF independent gap-fill diagnostic"
        self.scratch.label = "ODF gap-fill private scratch"
        report = .init(deviceRegistryID: device.registryID)
        report.fills.reserveCapacity(200_000)
    }

    @discardableResult
    private func collectCompleted() -> Bool {
        guard let current = pending else { return false }
        let status = current.buffer.status
        guard status == .completed || status == .error else { return false }
        var row = current.record
        row.status = UInt32(status.rawValue)
        row.validityMask |= 2
        row.completedObservationNs = nowNs()
        row.gpuStartSeconds = current.buffer.gpuStartTime
        row.gpuEndSeconds = current.buffer.gpuEndTime
        if status == .completed, row.gpuStartSeconds.isFinite, row.gpuEndSeconds.isFinite,
           row.gpuStartSeconds > 0, row.gpuEndSeconds >= row.gpuStartSeconds {
            row.validityMask |= 4
            row.durationMs = (row.gpuEndSeconds - row.gpuStartSeconds) * 1000
        } else { report.unknownTimingCount += 1 }
        if status == .error {
            row.error = String(describing: current.buffer.error)
            if report.completionFailure == nil { report.completionFailure = row.error }
        }
        if row.phase.hasPrefix("calibration_") { report.calibration.records.append(row) }
        else { report.fills.append(row) }
        pending = nil
        return true
    }

    private func checkFailure() throws {
        if let failure = report.completionFailure { throw SustainedError.native("gap-fill: \(failure)") }
    }

    /// False means encoding reached the guard before commit; no CB was submitted.
    @discardableResult
    private func submit(phase: String, iterations: UInt32, nextTick: UInt64? = nil) throws -> Bool {
        guard pending == nil else { throw SustainedError.native("gap-fill single-inflight invariant") }
        guard report.recordsAttempted < report.recordCapacity else {
            report.overflow = true
            throw SustainedError.capacity
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw SustainedError.native("gap-fill command encoder unavailable")
        }
        var count = iterations
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(scratch, offset: 0, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        let groupWidth = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: 65_536, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1))
        encoder.endEncoding()
        let guardNs = nextTick.map { $0 - 3_000_000 }
        command.label = "gap-fill-\(nextID)-\(phase)"
        let begin = nowNs()
        if let guardNs, begin >= guardNs {
            report.guardRejectedBeforeCommitCount += 1
            return false
        }
        command.commit()
        let end = nowNs()
        let id = nextID; nextID &+= 1
        let boundary: String
        if let guardNs {
            if begin >= guardNs { boundary = "after_violation" }
            else if end > guardNs { boundary = "crossed_unknown"; report.boundaryUnknownCount += 1 }
            else { boundary = "before" }
        } else { boundary = "not_applicable" }
        let row = GapFillRecord(fillID: id, phase: phase, iterations: iterations,
                    plannedNextTickNs: nextTick, guardNs: guardNs,
                    commitBeginNs: begin, commitEndNs: end, guardBoundary: boundary)
        pending = (command, row); lastCommittedID = id
        report.recordsAttempted += 1
        return true
    }

    func calibrate(checkCancel: () throws -> Void) throws {
        func median(_ phase: String) throws -> Double {
            let rows = report.calibration.records.filter { $0.phase == phase }
            let values = rows.compactMap { $0.durationMs }.sorted()
            guard rows.count == 5, values.count == 5,
                  rows.allSatisfy({ $0.validityMask == 7 && $0.status == 4 }),
                  values[2].isFinite, values[2] > 0 else {
                throw SustainedError.calibration("incomplete or invalid \(phase) GPU timestamps")
            }
            return values[2]
        }
        func five(_ phase: String, iterations: UInt32) throws {
            for _ in 0..<5 {
                try autoreleasepool {
                    try checkCancel()
                    try submit(phase: phase, iterations: iterations)
                    pending!.buffer.waitUntilCompleted()
                    _ = collectCompleted()
                    if report.completionFailure != nil {
                        throw SustainedError.calibration("calibration command buffer error")
                    }
                }
            }
        }
        do {
            report.calibration.status = "pilot"
            try five("calibration_pilot", iterations: report.calibration.initialIterations)
            let pilot = try median("calibration_pilot")
            report.calibration.pilotMedianMs = pilot
            let scaled = (Double(report.calibration.initialIterations) / pilot).rounded()
            guard scaled.isFinite, scaled >= 1, scaled <= Double(UInt32.max) else {
                throw SustainedError.calibration("one-shot iteration conversion out of range")
            }
            iterations = UInt32(scaled)
            report.calibration.scaledIterations = iterations
            report.calibration.status = "validation"
            try five("calibration_validation", iterations: iterations)
            let validation = try median("calibration_validation")
            report.calibration.validationMedianMs = validation
            guard validation >= 0.5, validation <= 2 else {
                throw SustainedError.calibration("validation median outside [0.5,2]ms; no recalibration")
            }
            report.calibration.passed = true; report.calibration.status = "passed"
        } catch {
            report.calibration.status = "failed"
            report.calibration.firstFailure = String(describing: error)
            if case SustainedError.cancelled = error { throw error }
            throw SustainedError.calibration(String(describing: error))
        }
    }

    /// Only the existing paced waiting interval is filled. No GPU-duration margin.
    func fillUntil(nextTick: UInt64, phase: String, checkCancel: () throws -> Void) throws {
        let guardNs = nextTick - 3_000_000
        while nowNs() < guardNs {
            let keepFilling = try autoreleasepool {
                try checkCancel()
                _ = collectCompleted(); try checkFailure()
                if pending == nil {
                    return try submit(phase: phase, iterations: iterations, nextTick: nextTick)
                }
                Thread.sleep(forTimeInterval: 0.00005)
                return true
            }
            if !keepFilling { break }
        }
        _ = collectCompleted(); try checkFailure()
    }

    func atRealStart() throws -> GapFillAtRealStart {
        _ = collectCompleted(); try checkFailure()
        return .init(lastFillID: lastCommittedID, inFlight: pending != nil, observedNs: nowNs())
    }

    /// Tail wait is after all phase clocks, never in front of a real tick/push.
    func finish() {
        if let current = pending {
            report.pendingFillIDAtFinish = current.record.fillID
            report.pendingStatusAtFinish = UInt32(current.buffer.status.rawValue)
            if current.buffer.status != .completed && current.buffer.status != .error {
                report.finishWaitBeginNs = nowNs()
                current.buffer.waitUntilCompleted()
                report.finishWaitEndNs = nowNs()
            }
            _ = collectCompleted()
        }
        report.finalPendingUnresolved = pending != nil
        if let current = pending {
            var row = current.record
            row.status = UInt32(current.buffer.status.rawValue)
            row.completedObservationNs = nowNs()
            row.error = "pending at final export; GPU interval unavailable"
            report.unknownTimingCount += 1
            if row.phase.hasPrefix("calibration_") { report.calibration.records.append(row) }
            else { report.fills.append(row) }
        }
    }
}
