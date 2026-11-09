import Foundation
import Metal

struct ResidentKeepAliveRecord: Encodable {
    let cbID: UInt64
    let phase: String
    let iterations: UInt32
    let commitBeginNs: UInt64
    let commitEndNs: UInt64
    var terminalObservedNs: UInt64?
    var status: UInt32 = 0
    var validityMask: UInt32 = 1
    var gpuStartSeconds: Double = 0
    var gpuEndSeconds: Double = 0
    var gpuDurationMs: Double?
    var error: String?
}

struct ResidentKeepAliveCalibration: Encodable {
    let initialPilotIterations: UInt32 = 65_536
    let targetMilliseconds: Double = 1
    let pilotCount = 5, validationCount = 5
    let minimumValidationMs: Double = 0.5, maximumValidationMs: Double = 2
    let iterationConversion = "initialPilotIterations * targetMilliseconds / pilotMedianMs; nearest, tiesAwayFromZero; out-of-UInt32 or <1 fails; one conversion, no retry"
    var status = "not_started"
    var pilotMedianMs: Double?
    var scaledIterations: UInt32?
    var validationMedianMs: Double?
    var passed = false
    var firstFailure: String?
    var records: [ResidentKeepAliveRecord] = []
}

struct ResidentKeepAliveConfiguration: Encodable {
    let deviceRegistryID: UInt64
    let deviceName: String
    let queueLabel = "ODF resident keepalive diagnostic"
    let kernel = "air_gap_fill"
    let maximumQueuedCommandBuffers = 2
    let threadgroups = [1, 1, 1]
    let threadsPerThreadgroup: [Int]
    let threadExecutionWidth: Int
    let scratchBytes: Int
    let storageMode = "private"
    let hazardTrackingMode = "tracked"
    let resourceUsage = "write; explicit encoder.useResource"
    let resourceSharing = "Only keeper CBs share scratch; no model input/output/resource is shared"
    let recordCapacity = 1_000_000
    let recordAccounting = "cbID and recordsAttempted include 5 pilot, 5 validation and operational committed CBs; recordsDropped has the same scope. Calibration records are separate and do not contribute formal coverage."
    let validityMaskMeaning = "1=commit bracket, 2=terminal status, 4=completed finite positive GPU interval; complete=7"
    let cpuClock = "DispatchTime.uptimeNanoseconds, same coordinate as real job wall and phase clocks"
    let gpuTimeScope = "Command-buffer residency seconds; single-SIMD-group ALU duration is a process-internal frequency proxy, not active cycles or direct frequency"
    let phaseAssignment = "Phase captured under state lock at commit; phase marks retain actual CPU boundaries. markPhase never drains or joins the worker."
}

struct ResidentKeepAlivePhaseMark: Encodable {
    let phase: String
    let stampNs: UInt64
}

struct ResidentKeepAliveLifecycle: Encodable {
    var startRequestedNs: UInt64?
    var workerBeganNs: UInt64?
    var firstOperationalCommitBeginNs: UInt64?
    var stopRequestedNs: UInt64?
    var stopReason: String?
    var drainBeginNs: UInt64?
    var drainEndNs: UInt64?
    var workerEndedNs: UInt64?
    var pendingAtDrainStart = 0
    var maximumPendingObserved = 0
    var pendingAtEnd = 0
}

struct ResidentKeepAliveReport: Encodable {
    let enabled = true
    let contractVersion = "opus-resident-keepalive-20261109-v1"
    let configuration: ResidentKeepAliveConfiguration
    var calibration = ResidentKeepAliveCalibration()
    var lifecycle = ResidentKeepAliveLifecycle()
    var phaseMarks: [ResidentKeepAlivePhaseMark] = []
    var records: [ResidentKeepAliveRecord] = []
    var recordsAttempted = 0
    var recordsDropped = 0
    var overflow = false
    var unknownTimingCount = 0
    var firstFailure: String?
}

/// This worker owns its two pending CBs and result arrays. The state lock protects
/// only stop/phase/lifecycle fields and commit admission, never a GPU or queue wait.
final class ResidentKeepAlive {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let scratch: MTLBuffer
    private let worker = DispatchQueue(label: "ODF resident keepalive worker", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stopRequested = false
    private var started = false
    private var currentPhase = "baseline"
    private var lifecycle = ResidentKeepAliveLifecycle()
    private var phaseMarks: [ResidentKeepAlivePhaseMark] = []
    private var firstFailure: String?
    private var nextID: UInt64 = 1
    private var iterations: UInt32 = 65_536
    private var pending: [(buffer: MTLCommandBuffer, record: ResidentKeepAliveRecord)] = []
    private var report: ResidentKeepAliveReport

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 2),
              let url = Bundle.module.url(forResource: "gap-fill", withExtension: "metallib") else {
            throw SustainedError.native("resident keepalive independent queue/metallib unavailable")
        }
        let library = try device.makeLibrary(URL: url)
        guard let function = library.makeFunction(name: "air_gap_fill") else {
            throw SustainedError.native("resident keepalive offline function unavailable")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let threads = pipeline.threadExecutionWidth
        let bytes = threads * MemoryLayout<UInt32>.stride
        guard threads > 0, threads <= pipeline.maxTotalThreadsPerThreadgroup,
              let scratch = device.makeBuffer(length: bytes, options: [.storageModePrivate, .hazardTrackingModeTracked]),
              scratch.hazardTrackingMode == .tracked else {
            throw SustainedError.native("resident keepalive one-SIMD-group tracked scratch unavailable")
        }
        self.queue = queue; self.pipeline = pipeline; self.scratch = scratch
        queue.label = "ODF resident keepalive diagnostic"
        scratch.label = "ODF resident keepalive private tracked scratch"
        report = .init(configuration: .init(deviceRegistryID: device.registryID, deviceName: device.name,
                       threadsPerThreadgroup: [threads, 1, 1], threadExecutionWidth: threads, scratchBytes: bytes))
        report.records.reserveCapacity(200_000)
        pending.reserveCapacity(2)
    }

    private func fail(_ message: String) {
        stateLock.lock()
        if firstFailure == nil { firstFailure = message }
        requestStopLocked(reason: "keeper_error")
        stateLock.unlock()
    }

    private func requestStopLocked(reason: String) {
        if !stopRequested {
            stopRequested = true
            lifecycle.stopRequestedNs = nowNs()
            lifecycle.stopReason = reason
        }
    }

    private func shouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    /// Called only by calibration before start, then only by the serial worker.
    private func submit(phase: String? = nil) throws -> Bool {
        guard pending.count < 2 else { throw SustainedError.native("resident keepalive max-two invariant") }
        guard report.recordsAttempted < report.configuration.recordCapacity else {
            report.overflow = true
            throw SustainedError.capacity
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw SustainedError.native("resident keepalive command encoder unavailable")
        }
        var count = iterations
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(scratch, offset: 0, index: 0)
        encoder.useResource(scratch, usage: .write)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        stateLock.lock()
        if stopRequested { stateLock.unlock(); return false }
        let phase = phase ?? currentPhase
        command.label = "resident-keepalive-\(nextID)-\(phase)"
        let begin = nowNs()
        command.commit()
        let end = nowNs()
        if started, lifecycle.firstOperationalCommitBeginNs == nil {
            lifecycle.firstOperationalCommitBeginNs = begin
        }
        stateLock.unlock()
        let row = ResidentKeepAliveRecord(cbID: nextID, phase: phase, iterations: iterations,
                                         commitBeginNs: begin, commitEndNs: end)
        nextID &+= 1
        pending.append((command, row))
        report.recordsAttempted += 1
        stateLock.lock()
        lifecycle.maximumPendingObserved = max(lifecycle.maximumPendingObserved, pending.count)
        stateLock.unlock()
        return true
    }

    /// The keeper thread may wait its own oldest CB. The real ticker never does.
    private func collectOldest() {
        let current = pending.removeFirst()
        current.buffer.waitUntilCompleted()
        var row = current.record
        row.terminalObservedNs = nowNs()
        row.status = UInt32(current.buffer.status.rawValue)
        if current.buffer.status == .completed || current.buffer.status == .error { row.validityMask |= 2 }
        row.gpuStartSeconds = current.buffer.gpuStartTime
        row.gpuEndSeconds = current.buffer.gpuEndTime
        if current.buffer.status == .completed, row.gpuStartSeconds.isFinite, row.gpuEndSeconds.isFinite,
           row.gpuStartSeconds > 0, row.gpuEndSeconds > row.gpuStartSeconds {
            row.validityMask |= 4
            row.gpuDurationMs = (row.gpuEndSeconds - row.gpuStartSeconds) * 1000
        } else {
            report.unknownTimingCount += 1
            row.error = current.buffer.error.map { String(describing: $0) } ?? "missing valid completed GPU interval"
            fail(row.error!)
        }
        if row.phase.hasPrefix("calibration_") { report.calibration.records.append(row) }
        else { report.records.append(row) }
    }

    func calibrate(checkCancel: () throws -> Void) throws {
        func five(_ phase: String) throws -> Double {
            for _ in 0..<5 {
                try autoreleasepool {
                    try checkCancel()
                    guard try submit(phase: phase) else { throw SustainedError.calibration("keeper stopped during calibration") }
                    collectOldest()
                    if let failure = firstFailure { throw SustainedError.calibration(failure) }
                }
            }
            let values = report.calibration.records.filter { $0.phase == phase }.compactMap { $0.gpuDurationMs }.sorted()
            guard values.count == 5, values[2].isFinite, values[2] > 0 else {
                throw SustainedError.calibration("resident keepalive invalid calibration timestamps")
            }
            return values[2]
        }
        do {
            report.calibration.status = "pilot"
            let pilot = try five("calibration_pilot")
            report.calibration.pilotMedianMs = pilot
            let scaled = (Double(report.calibration.initialPilotIterations) * report.calibration.targetMilliseconds / pilot).rounded()
            guard scaled.isFinite, scaled >= 1, scaled <= Double(UInt32.max) else {
                throw SustainedError.calibration("resident keepalive one-shot iteration conversion out of range")
            }
            iterations = UInt32(scaled)
            report.calibration.scaledIterations = iterations
            report.calibration.status = "validation"
            let validation = try five("calibration_validation")
            report.calibration.validationMedianMs = validation
            guard validation >= 0.5, validation <= 2 else {
                throw SustainedError.calibration("resident keepalive validation median outside [0.5,2]ms; no recalibration")
            }
            report.calibration.passed = true
            report.calibration.status = "passed"
        } catch {
            report.calibration.status = "failed"
            report.calibration.firstFailure = String(describing: error)
            fail(String(describing: error))
            if case SustainedError.cancelled = error { throw error }
            throw SustainedError.calibration(String(describing: error))
        }
    }

    func start() throws {
        guard report.calibration.passed, !started else { throw SustainedError.native("resident keepalive start requires one calibration") }
        let ready = DispatchSemaphore(value: 0)
        stateLock.lock()
        started = true
        lifecycle.startRequestedNs = nowNs()
        stateLock.unlock()
        worker.async { self.runWorker(ready: ready) }
        // Setup only. Acknowledge the first submission batch before the prefix
        // clock starts, without waiting for its GPU completion.
        ready.wait()
        stateLock.lock()
        let failure = firstFailure
        stateLock.unlock()
        if let failure { throw SustainedError.native(failure) }
    }

    private func runWorker(ready: DispatchSemaphore) {
        stateLock.lock()
        lifecycle.workerBeganNs = nowNs()
        stateLock.unlock()
        var acknowledgedStart = false
        while !shouldStop() {
            autoreleasepool {
                do {
                    while pending.count < 2 && !shouldStop() {
                        if !(try submit()) { break }
                    }
                } catch { fail(String(describing: error)) }
                if !acknowledgedStart { ready.signal(); acknowledgedStart = true }
                if !pending.isEmpty { collectOldest() }
            }
        }
        if !acknowledgedStart { ready.signal() }
        stateLock.lock()
        lifecycle.drainBeginNs = nowNs()
        lifecycle.pendingAtDrainStart = pending.count
        stateLock.unlock()
        while !pending.isEmpty { autoreleasepool { collectOldest() } }
        stateLock.lock()
        lifecycle.drainEndNs = nowNs()
        lifecycle.pendingAtEnd = pending.count
        lifecycle.workerEndedNs = nowNs()
        stateLock.unlock()
    }

    func markPhase(_ name: String) {
        stateLock.lock()
        currentPhase = name
        phaseMarks.append(.init(phase: name, stampNs: nowNs()))
        stateLock.unlock()
    }

    /// Called after real phase clocks end. The state lock is released before the
    /// worker join, so no GPU completion or worker exit needs a lock held by us.
    func stopAndDrain(reason: String) -> ResidentKeepAliveReport {
        stateLock.lock()
        requestStopLocked(reason: reason)
        let needsJoin = started
        stateLock.unlock()
        if needsJoin { worker.sync {} }
        report.lifecycle = lifecycle
        report.phaseMarks = phaseMarks
        report.firstFailure = firstFailure
        return report
    }
}
