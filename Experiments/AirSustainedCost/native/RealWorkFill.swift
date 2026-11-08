import Foundation
import CoreVideo
import Metal
import RifeMetal
import RifeMetalCore

struct FrozenExtraBudget: Encodable {
    let source = "extra_warmup20_wall_type7_p95"
    let numerator: UInt64
    let denominator: UInt64 = 20
    let exactNs: Double
    let admissionNs: UInt64
    let rounding = "Type7 p95=(19*x[18]+x[19])/20; ceil to integer nanoseconds for admission; frozen once"
}

struct ExtraJob: Encodable {
    let role = "extra"
    let contextID: UInt64 = 2
    let stage: UInt32 = 3
    let jobID: UInt64
    let requestID: UInt64
    let phase: String
    let sequence: Int
    let inputShift: Int
    let workerDecisionNs: UInt64
    let targetNs: UInt64?
    let wallStartNs: UInt64
    let wallEndNs: UInt64
    let wallNs: UInt64
    let generated: Bool
    let traceRecordCount: Int
    let traceOverflow: UInt64
    let warmOutputRepresentationValid: Bool?
    let error: String?
}

struct ExtraAdmission: Encodable {
    let offerID: UInt64
    let sourceRealJobID: UInt64
    let phase: String
    let realSlot: Int
    let nextTickNs: UInt64
    let nextTickSlot: Int
    let offerDecisionNs: UInt64
    let remainingNs: UInt64
    let frozenFAdmissionNs: UInt64
    let guardNs: UInt64 = 3_000_000
    let timeEligible: Bool
    let busy: Bool
    let offerAdmitted: Bool
    let reason: String
}

struct ExtraWorkerDecision: Encodable {
    let offerID: UInt64
    let workerDecisionNs: UInt64
    let nextTickNs: UInt64
    let remainingNs: UInt64
    let timeEligible: Bool
    let disposition: String
    let extraJobID: UInt64
}

struct ExtraOutputValidation: Encodable {
    let representation = "CVPixelBuffer BGRA8; unsigned 8-bit output, not a float tensor API"
    let internalFloatTensorsObserved = false
    let finiteScope = "BGRA8 representation only; no claim that internal FP16 flow/mask/RGB are free of NaN/Inf"
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let iosurfaceBacked: Bool
    let bytesPerRow: Int
    let outputSHA256: String
    let representationValid: Bool
    let sampleRule = "Fixed64x64 grid, cell-center floor coordinates, BGRA luma=.2126R+.7152G+.0722B, Welford population variance; once after final warm output"
    let sampleCount: Int
    let sampleLuminanceMean: Double
    let sampleLuminanceVariance: Double
    let sampleVariancePositive: Bool
}

struct RealWorkFillReport: Encodable {
    let enabled = true
    let contractVersion = "opus-real-work-fill-c4-20261109-v1"
    let role = "extra"
    let contextID: UInt64 = 2
    let deviceRegistryID: UInt64
    let interpolatorInstance: String?
    let fillerModelIdentityObserved: ModelIdentitySnapshot?
    let fillerModelIdentityValidated: ModelIdentity?
    let outputValidation: ExtraOutputValidation?
    let frozenF: FrozenExtraBudget?
    let extraJobs: [ExtraJob]
    let extraRoots: [Root]
    let admissions: [ExtraAdmission]
    let workerDecisions: [ExtraWorkerDecision]
    let maximumExtraJobs = 20_000, maximumExtraRoots = 300_000, maximumAdmissions = 20_000
    let rootObservationsAttempted: Int
    let rootObservationsDropped: Int
    let traceOverflowTotal: UInt64
    let overflow: Bool
    let firstFailure: String?
    let activeOfferIDAtDrain: UInt64
    let drainStartNs: UInt64
    let drainEndNs: UInt64
    let scope = "Independent worker/context/stream/output/collector. Shared immutable fixture and device only; extra output discarded. No real-ticker join. Energy unknown."
}

struct ExtraAtRealStart {
    let lastID: UInt64
    let inFlight: Bool
    let observedNs: UInt64
}

/// State lock guards only a handful of scalars; it is never held around GPU work,
/// root copying, hashing or JSON. Arrays are confined to their owning executor.
final class RealWorkFill: @unchecked Sendable {
    private let worker = DispatchQueue(label: "ODF independent C4 filler", qos: .userInitiated)
    private let stateLock = NSLock()
    private var busy = false, stopping = false
    private var lastStartedID: UInt64 = 0, activeOfferID: UInt64 = 0
    private var firstFailure: String?
    private var engine: RifeInterpolator!
    private var stream: RifeStream!
    private var output: CVPixelBuffer!
    private let first: CVPixelBuffer, second: CVPixelBuffer
    private let cancelFile: String
    private let deviceID: UInt64
    private let device: MTLDevice, model: URL
    private var observedIdentity: ModelIdentitySnapshot!
    private var validatedIdentity: ModelIdentity!
    private var outputValidation: ExtraOutputValidation?
    private var frozenF: FrozenExtraBudget?
    private var jobs: [ExtraJob] = [], roots: [Root] = []
    private var offers: [ExtraAdmission] = [], decisions: [ExtraWorkerDecision] = []
    private var nextJobID: UInt64 = 3, nextOfferID: UInt64 = 1, observationSequence: UInt64 = 0
    private var pushSequence = 0, rootAttempted = 0, rootDropped = 0
    private var traceOverflow: UInt64 = 0
    private var overflow = false
    private var offerOverflow = false
    private var drainStart: UInt64 = 0, drainEnd: UInt64 = 0, activeAtDrain: UInt64 = 0

    init(device: MTLDevice, model: URL, first: CVPixelBuffer, second: CVPixelBuffer, cancelFile: String) {
        self.first = first; self.second = second; self.cancelFile = cancelFile; self.deviceID = device.registryID
        self.device = device; self.model = model
        jobs.reserveCapacity(6_000); roots.reserveCapacity(60_000); offers.reserveCapacity(5_000); decisions.reserveCapacity(5_000)
    }

    func primeContext() throws {
        try worker.sync {
            engine = try RifeInterpolator(configuration: .init(modelURL: model, qualityTier: .fast,
                         preferredDevice: device, experimentOptions: .init(gpuIO: true, replaceMask: false)))
            let raw = engine.airDiagnosticModelIdentity
            observedIdentity = ModelIdentitySnapshot(raw)
            validatedIdentity = try validateFillerModelIdentity(raw)
            output = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
            engine.airServiceTraceBegin(jobID: 1, stage: 1)
            do { stream = try engine.makeStream(width: width, height: height) }
            catch { _ = readTrace(after: 1, phase: "extra_setup"); throw error }
            _ = readTrace(after: 1, phase: "extra_setup")
            engine.airServiceTraceBegin(jobID: 2, stage: 2)
            do { _ = try stream.push(first, timesteps: []) }
            catch { _ = readTrace(after: 2, phase: "extra_setup"); throw error }
            _ = readTrace(after: 2, phase: "extra_setup")
        }
    }

    private func readTrace(after: UInt64, phase: String) -> (Int, UInt64) {
        let count = engine.airServiceTraceCount, overflow = engine.airServiceTraceOverflow
        rootAttempted += count; traceOverflow &+= overflow
        for index in 0..<count {
            observationSequence &+= 1
            if roots.count < maximumRoots {
                roots.append(Root(engine.airServiceTraceRecord(at: index), after: after, phase: phase,
                                  sequence: observationSequence, contextID: 2, role: "extra"))
            } else { rootDropped += 1; self.overflow = true }
        }
        return (count, overflow)
    }

    private func perform(request: UInt64, phase: String, decisionNs: UInt64, target: UInt64?, preparedID: UInt64? = nil) throws {
        guard jobs.count < maximumJobs else { overflow = true; throw SustainedError.capacity }
        let id = preparedID ?? nextJobID
        nextJobID = id &+ 1
        let input = pushSequence.isMultiple(of: 2) ? second : first
        let shift = pushSequence.isMultiple(of: 2) ? 7 : 0
        pushSequence += 1
        if preparedID == nil { engine.airServiceTraceBegin(jobID: id, stage: 3) }
        var generated = false
        var failure: Error?
        let start = DispatchTime.now().uptimeNanoseconds
        do { generated = try stream.push(input, into: output) } catch { failure = error }
        let end = DispatchTime.now().uptimeNanoseconds
        let (count, over) = readTrace(after: id, phase: phase)
        let warmValid = phase == "extra_warmup" ? validOutput() : nil
        jobs.append(.init(jobID: id, requestID: request, phase: phase, sequence: jobs.count,
                    inputShift: shift, workerDecisionNs: decisionNs, targetNs: target,
                    wallStartNs: start, wallEndNs: end, wallNs: end-start, generated: generated,
                    traceRecordCount: count, traceOverflow: over, warmOutputRepresentationValid: warmValid,
                    error: failure.map { String(describing: $0) }))
        if let failure { throw failure }
        guard generated, count > 0, over == 0, rootDropped == 0 else {
            throw SustainedError.trace("extra output/trace incomplete")
        }
        if warmValid == false { throw SustainedError.invalid("extra warm BGRA8 representation invalid") }
    }

    private func validOutput() -> Bool {
        CVPixelBufferGetWidth(output) == width && CVPixelBufferGetHeight(output) == height &&
        CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA &&
        CVPixelBufferGetIOSurface(output) != nil && CVPixelBufferGetBytesPerRow(output) >= width*4
    }

    private func sampleLuminance() -> (Int, Double, Double) {
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        var n = 0, mean = 0.0, m2 = 0.0
        for row in 0..<64 {
            let y = ((2*row+1)*height)/128
            for column in 0..<64 {
                let x = ((2*column+1)*width)/128
                let p = base + y*stride + x*4
                let value = 0.2126*Double(p[2]) + 0.7152*Double(p[1]) + 0.0722*Double(p[0])
                n += 1
                let delta = value-mean; mean += delta/Double(n); m2 += delta*(value-mean)
            }
        }
        return (n, mean, m2/Double(n))
    }

    /// Called only after real warm20. This setup wait is not on a real phase clock.
    func warmAndFreeze() throws {
        try worker.sync {
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath: cancelFile) { throw SustainedError.cancelled }
                try autoreleasepool { try perform(request: 0, phase: "extra_warmup", decisionNs: 0, target: nil) }
            }
            let sorted = jobs.filter { $0.phase == "extra_warmup" }.map(\.wallNs).sorted()
            guard sorted.count == 20 else { throw SustainedError.invalid("extra warm20 incomplete") }
            let numerator = 19 * sorted[18] + sorted[19]
            frozenF = .init(numerator: numerator, exactNs: Double(numerator)/20,
                            admissionNs: (numerator + 19)/20)
            let valid = validOutput()
            let (n, mean, variance) = sampleLuminance()
            outputValidation = .init(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output),
                pixelFormat: CVPixelBufferGetPixelFormatType(output), iosurfaceBacked: CVPixelBufferGetIOSurface(output) != nil,
                bytesPerRow: CVPixelBufferGetBytesPerRow(output), outputSHA256: pixelHash(output), representationValid: valid,
                sampleCount: n, sampleLuminanceMean: mean, sampleLuminanceVariance: variance, sampleVariancePositive: variance > 0)
            guard valid, variance > 0 else { throw SustainedError.invalid("extra BGRA8 representation/variance check failed") }
        }
    }

    func atRealStart() throws -> ExtraAtRealStart {
        stateLock.lock(); defer { stateLock.unlock() }
        if let failure = firstFailure { throw SustainedError.native("extra: \(failure)") }
        return .init(lastID: lastStartedID, inFlight: busy, observedNs: nowNs())
    }

    /// Exactly one offer per completed real tick. Timing, busy and phase-edge reasons stay separate.
    func offer(after realID: UInt64, phase: String, slot: Int, nextTick: UInt64, phaseEnd: UInt64) throws {
        guard let budget = frozenF else { throw SustainedError.invalid("extra F not frozen") }
        guard offers.count < maximumJobs else { offerOverflow = true; throw SustainedError.capacity }
        let offerID = nextOfferID; nextOfferID &+= 1
        stateLock.lock()
        let wasBusy = busy, stopped = stopping, failure = firstFailure
        let stamp = nowNs(), remaining = nextTick > stamp ? nextTick-stamp : 0
        let timeEligible = remaining >= budget.admissionNs + 3_000_000
        let phaseEligible = nextTick < phaseEnd
        let admit = timeEligible && !wasBusy && !stopped && failure == nil && phaseEligible
        if admit { busy = true; activeOfferID = offerID }
        stateLock.unlock()
        let reason = failure != nil ? "extra_error" : stopped ? "stopped" : !phaseEligible ? "phase_end" :
                     !timeEligible ? "insufficient_time" : wasBusy ? "busy" : "offered"
        offers.append(.init(offerID: offerID, sourceRealJobID: realID, phase: phase, realSlot: slot,
            nextTickNs: nextTick, nextTickSlot: slot+1, offerDecisionNs: stamp, remainingNs: remaining,
            frozenFAdmissionNs: budget.admissionNs, timeEligible: timeEligible,
            busy: wasBusy, offerAdmitted: admit, reason: reason))
        if let failure { throw SustainedError.native("extra: \(failure)") }
        guard admit else { return }
        worker.async { self.executeOffer(offerID, phase: phase, nextTick: nextTick, budget: budget) }
    }

    private func executeOffer(_ offerID: UInt64, phase: String, nextTick: UInt64, budget: FrozenExtraBudget) {
        defer { stateLock.lock(); busy = false; activeOfferID = 0; stateLock.unlock() }
        do {
            try autoreleasepool {
                let id = nextJobID
                engine.airServiceTraceBegin(jobID: id, stage: 3)
                let cancelled = FileManager.default.fileExists(atPath: cancelFile)
                stateLock.lock()
                let stamp = nowNs(), remaining = nextTick > stamp ? nextTick-stamp : 0
                let eligible = remaining >= budget.admissionNs + 3_000_000
                let run = !stopping && !cancelled && eligible
                if run { lastStartedID = id }
                let reason = stopping ? "stopped_before_start" : cancelled ? "cancelled_before_start" :
                             !eligible ? "budget_expired_before_start" : "executed"
                stateLock.unlock()
                if !run {
                    decisions.append(.init(offerID: offerID, workerDecisionNs: stamp, nextTickNs: nextTick,
                        remainingNs: remaining, timeEligible: eligible, disposition: reason, extraJobID: 0))
                    return
                }
                do {
                    try perform(request: offerID, phase: phase, decisionNs: stamp, target: nextTick, preparedID: id)
                    decisions.append(.init(offerID: offerID, workerDecisionNs: stamp, nextTickNs: nextTick,
                        remainingNs: remaining, timeEligible: eligible, disposition: "executed", extraJobID: id))
                } catch {
                    decisions.append(.init(offerID: offerID, workerDecisionNs: stamp, nextTickNs: nextTick,
                        remainingNs: remaining, timeEligible: eligible, disposition: "error", extraJobID: id))
                    throw error
                }
            }
        } catch {
            stateLock.lock(); if firstFailure == nil { firstFailure = String(describing: error) }; stateLock.unlock()
        }
    }

    /// The only worker join occurs after all real phase clocks have ended.
    func stopAndDrain() -> RealWorkFillReport {
        drainStart = nowNs()
        stateLock.lock(); stopping = true; activeAtDrain = activeOfferID; stateLock.unlock()
        worker.sync {}
        drainEnd = nowNs()
        return .init(deviceRegistryID: deviceID, interpolatorInstance: engine.map { String(describing: ObjectIdentifier($0)) },
            fillerModelIdentityObserved: observedIdentity, fillerModelIdentityValidated: validatedIdentity,
            outputValidation: outputValidation, frozenF: frozenF, extraJobs: jobs, extraRoots: roots,
            admissions: offers, workerDecisions: decisions, rootObservationsAttempted: rootAttempted,
            rootObservationsDropped: rootDropped, traceOverflowTotal: traceOverflow, overflow: overflow || offerOverflow,
            firstFailure: firstFailure, activeOfferIDAtDrain: activeAtDrain, drainStartNs: drainStart, drainEndNs: drainEnd)
    }
}
