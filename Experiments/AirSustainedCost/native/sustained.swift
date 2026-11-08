import Foundation
import CryptoKit
import CoreVideo
import Metal
import Darwin
import RifeMetal
import RifeMetalCore

enum SustainedError: Error {
    case invalid(String), cancelled, native(String), trace(String), capacity
}

let originalModelSHA256 = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
let referenceWallP50Ms = 18.1323335
let width = 1814, height = 1142
let billion: UInt64 = 1_000_000_000
let maximumJobs = 20_000, maximumRoots = 300_000

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

// Identical BGRA/IOSurface fixture and row hash to Air24Training/native/cost.swift.
func image(_ width: Int, _ height: Int, _ shift: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                   kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                             attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let result = buffer else { throw SustainedError.native("source pixel buffer") }
    CVPixelBufferLockBaseAddress(result, [])
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let stride = CVPixelBufferGetBytesPerRow(result)
    let base = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let p = base + y * stride + 4 * x
            p[0] = UInt8(((x + shift) ^ y) & 255)
            p[1] = UInt8((3 * x + y + shift) & 255)
            p[2] = UInt8((x + 2 * y + shift) & 255)
            p[3] = 255
        }
    }
    return result
}

func pixelHash(_ buffer: CVPixelBuffer) -> String {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var digest = SHA256()
    for y in 0..<height { digest.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * stride, count: width * 4)) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

struct Options {
    let mode: String
    let seconds: Int
    let baselineSeconds: Int
    let model: URL
    let expectedSHA256: String
    let output: URL
    let cancelFile: String

    static let help = """
    Usage: air-sustained-cost --mode paced24|continuous --seconds 180|120
      --baseline-seconds 5 --model-path ABS.rmw --model-sha256 HEX64
      --output ABS.json --cancel-file ABS
    CPU-only: air-sustained-cost --identity-check-only --model-path ABS.rmw
      --model-sha256 HEX64 --output ABS.json

    Original five-stage model only; 1814x1142 BGRA, FP16, Fast stream, GPU IO,
    accumulated mask. Prime, 20 warmups, separate 5s prefix, then the formal phase
    only if prefix push-wall p50 is strictly below 36.264667ms. No automatic retry.
    paced24 skips missed slots without catch-up; continuous has no pacing sleep.
    ODF_AIR_SERVICE_TRACE=1 must be set before launch. No window or capture.
    Exit: 0 complete; 3 baseline_not_ready; 4 cancelled; 1 failed; 2 invalid CLI.
    --help exits before model, Metal, or output initialization.
    """

    static func parse() throws -> Options? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] { print(help); return nil }
        let allowed: Set<String> = ["--mode", "--seconds", "--baseline-seconds", "--model-path",
                                    "--model-sha256", "--output", "--cancel-file"]
        guard arguments.count == allowed.count * 2 else { throw SustainedError.invalid(help) }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), values[key] == nil else { throw SustainedError.invalid("unknown/duplicate option: \(key)") }
            values[key] = arguments[index + 1]
        }
        guard let mode = values["--mode"], let seconds = Int(values["--seconds"] ?? ""),
              let prefix = Int(values["--baseline-seconds"] ?? ""), prefix == 5,
              (mode == "paced24" && seconds == 180) || (mode == "continuous" && seconds == 120),
              values["--model-sha256"] == originalModelSHA256 else {
            throw SustainedError.invalid("fixed original-model protocol: paced24/180 or continuous/120; prefix5; original SHA")
        }
        for key in ["--model-path", "--output", "--cancel-file"] {
            guard let value = values[key], value.hasPrefix("/"), !value.isEmpty else {
                throw SustainedError.invalid("\(key) must be an absolute local path")
            }
        }
        let destination = URL(fileURLWithPath: values["--output"]!)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SustainedError.invalid("existing result retained")
        }
        return Options(mode: mode, seconds: seconds, baselineSeconds: prefix,
                       model: URL(fileURLWithPath: values["--model-path"]!), expectedSHA256: values["--model-sha256"]!,
                       output: destination, cancelFile: values["--cancel-file"]!)
    }
}

struct HostClock: Encodable {
    let coordinate = "All phase/wall/target/thermal nanoseconds use DispatchTime.uptimeNanoseconds; raw trace HostTicks use mach_absolute_time and the recorded timebase. GPU/kernel fields retain Apple's seconds. No cross-domain absolute alignment asserted."
    let machTimebaseNumer: UInt32
    let machTimebaseDenom: UInt32
}

struct Configuration: Encodable {
    let mode: String
    let seconds: Int
    let baselineSeconds: Int
    let targetHz: Int
    let width = 1814, height = 1142, warmup = 20
    let qualityTier = "fast", internalScale = 0.25, weightsDtype = "FP16"
    let maskUpdate = "accumulate", gpuIO = true, replaceMask = false
    let fusedWarp = false, trimFinalFeatures = false
    let callerAutoreleasePool = "Each push plus trace read is enclosed by a caller pool; drain is outside push wall. App already has this boundary, old short cost did not. No actual memory growth in the old caller is established."
    let expectedModelSHA256: String
    let modelPath: String
    let prefixCadence = "Same mode as formal phase; separate 5-second duration after warmup."
    let wallScope = "Only the synchronous stream.push(input, into: preallocatedOutput) call; original internal waits and IO included. Pacing, trace begin/read, thermal, cancellation, hashes and JSON outside."
    let gpuScope = "Command-buffer residency timestamps, not GPU active cycles; full roots exported without a fixed root-count assumption."
    let maximumJobs = 20_000, maximumRoots = 300_000
    var actualLoadedModelIdentity: ModelIdentitySnapshot?
}

struct IdentityKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Copy the actual getter before validating it, retaining scalar values and Swift types.
struct ModelIdentitySnapshot: Encodable {
    let values: [String: Any]
    let swiftTypes: [String: String]
    enum CodingKeys: String, CodingKey { case values, swiftTypes }

    init(_ values: [String: Any]) {
        self.values = values
        self.swiftTypes = values.mapValues { String(reflecting: type(of: $0)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var fields = container.nestedContainer(keyedBy: IdentityKey.self, forKey: .values)
        for (key, value) in values {
            let key = IdentityKey(stringValue: key)
            switch value {
            case let value as String: try fields.encode(value, forKey: key)
            case let value as Bool: try fields.encode(value, forKey: key)
            case let value as Int: try fields.encode(value, forKey: key)
            case let value as UInt32: try fields.encode(value, forKey: key)
            case is NSNull: try fields.encodeNil(forKey: key)
            default: try fields.encode(String(reflecting: value), forKey: key)
            }
        }
        try container.encode(swiftTypes, forKey: .swiftTypes)
    }
}

struct ModelIdentity: Encodable {
    let stageCount: Int
    let graphID: String?
    let tensorCount: Int
    let containerVersion: Int
    let actualModelPath: String
    let sha256: String
    let overrideApplied: Bool
}

// Both the CPU parser gate and the actual runtime getter use this exact validator.
func validateOriginalModelIdentity(_ identity: [String: Any]) throws -> ModelIdentity {
    guard let actualSHA = identity["sha256"] as? String, actualSHA == originalModelSHA256,
          let stages = identity["stageCount"] as? Int, stages == 5,
          let tensors = identity["tensorCount"] as? Int, tensors == 158,
          let version = identity["containerVersion"] as? UInt32, version == 1,
          let actualPath = identity["actualModelPath"] as? String,
          let overridden = identity["overrideApplied"] as? Bool, !overridden else {
        throw SustainedError.invalid("actual loaded original-model identity mismatch")
    }
    return .init(stageCount: stages, graphID: identity["graphID"] as? String,
                 tensorCount: tensors, containerVersion: Int(version), actualModelPath: actualPath,
                 sha256: actualSHA, overrideApplied: overridden)
}

struct CPUIdentityReport: Encodable {
    let format = "odf-air-sustained-cpu-identity-v1"
    let origin = "CPU parsed model header, not GPU runtime identity"
    let parser = "RifeMetalCore.WeightStore(url:); its initializer only reads/decodes/hashes data; tensorData(on:) is not called."
    let modelPath: String
    let expectedSHA256: String
    let metalContextCreated = false
    let gpuRuntimeIdentityObserved = false
    var status = "failed"
    var observedIdentity: ModelIdentitySnapshot?
    var validatedIdentity: ModelIdentity?
    var firstFailure: String?
}

/// Dispatched before Options/Harness, RifeInterpolator, fixtures or any Metal context.
func cpuIdentityCheck() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--identity-check-only" }
    let allowed: Set<String> = ["--model-path", "--model-sha256", "--output"]
    guard arguments.count == 6,
          CommandLine.arguments.filter({ $0 == "--identity-check-only" }).count == 1 else {
        throw SustainedError.invalid("CPU-only identity check requires model-path, model-sha256, output")
    }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        guard allowed.contains(key), values[key] == nil else { throw SustainedError.invalid("unknown/duplicate CPU option") }
        values[key] = arguments[index + 1]
    }
    guard values["--model-path"]?.hasPrefix("/") == true,
          values["--output"]?.hasPrefix("/") == true,
          values["--model-sha256"] == originalModelSHA256 else {
        throw SustainedError.invalid("CPU check requires absolute paths and the original SHA")
    }
    let model = URL(fileURLWithPath: values["--model-path"]!)
    let destination = URL(fileURLWithPath: values["--output"]!)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw SustainedError.invalid("existing result retained")
    }
    var report = CPUIdentityReport(modelPath: model.path, expectedSHA256: values["--model-sha256"]!)
    do {
        // WeightStore's initializer is CPU-only. Do not call tensorData(on:),
        // RifeInterpolator, InferenceContext, or MTLCreateSystemDefaultDevice here.
        let weights = try WeightStore(url: model)
        let identity: [String: Any] = [
            "stageCount": weights.header.scaleList.count,
            "graphID": weights.header.graphID.map { $0 as Any } ?? NSNull(),
            "model": weights.header.model,
            "tensorCount": weights.header.tensors.count,
            "containerVersion": weights.containerVersion,
            "actualModelPath": model.path,
            "sha256": weights.airDiagnosticSourceSHA256,
            "overrideApplied": false,
        ]
        report.observedIdentity = ModelIdentitySnapshot(identity)
        report.validatedIdentity = try validateOriginalModelIdentity(identity)
        report.status = "identity_check_passed"
    } catch { report.firstFailure = String(describing: error) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: destination, options: .atomic)
    print("status=\(report.status) output=\(destination.path)")
    return report.status == "identity_check_passed" ? 0 : 1
}

struct Job: Encodable {
    let jobID: UInt64
    let phase: String
    let stage: UInt32 = 3
    let sequence: Int
    let inputShift: Int
    let wallStartNs: UInt64
    let wallEndNs: UInt64
    let wallNs: UInt64
    let generated: Bool
    let scheduledSlot: Int?
    let targetNs: UInt64?
    let launchLagNs: UInt64?
    let missedSlotsBefore: Int
    let traceRecordCount: Int
    let traceOverflow: UInt64
    let error: String?
}

struct Root: Encodable {
    let contextID: UInt64 = 1
    let observedAfterJobID: UInt64
    let observedPhase: String
    let observedSampleHostTicks: UInt64
    let observationSequence: UInt64
    let jobID: UInt64
    let stage: UInt32
    let rootIndex: UInt32
    let createHostTicks: UInt64
    let commitBeginHostTicks: UInt64
    let commitEndHostTicks: UInt64
    let waitBeginHostTicks: UInt64
    let waitEndHostTicks: UInt64
    let commitKind: UInt32
    let status: UInt32
    let validityMask: UInt32
    let coverageFlags: UInt32
    let gpuStartSeconds: Double
    let gpuEndSeconds: Double
    let kernelStartSeconds: Double
    let kernelEndSeconds: Double

    init(_ row: AirServiceTraceRecord, after: UInt64, phase: String, sequence: UInt64) {
        observedAfterJobID = after; observedPhase = phase
        observedSampleHostTicks = mach_absolute_time(); observationSequence = sequence
        jobID = row.jobID; stage = row.stage; rootIndex = row.rootIndex
        createHostTicks = row.createHostTicks
        commitBeginHostTicks = row.commitBeginHostTicks; commitEndHostTicks = row.commitEndHostTicks
        waitBeginHostTicks = row.waitBeginHostTicks; waitEndHostTicks = row.waitEndHostTicks
        commitKind = row.commitKind; status = row.status
        validityMask = row.validityMask; coverageFlags = row.coverageFlags
        gpuStartSeconds = row.gpuStartSeconds; gpuEndSeconds = row.gpuEndSeconds
        kernelStartSeconds = row.kernelStartSeconds; kernelEndSeconds = row.kernelEndSeconds
    }
}

struct Phase: Encodable {
    let startNs: UInt64
    let requestedEndNs: UInt64
    var endNs: UInt64
    let requestedSeconds: Int
    var jobCount = 0
    var missedSlots = 0
    var skippedSlotsBeforeJobs = 0
    var trailingMissedSlots = 0
    var actualHz: Double = 0
    var complete = false
}

struct ThermalSample: Encodable {
    let phase: String
    let sampleNs: UInt64
    let elapsedSeconds: Double
    let scheduledSampleIndex: Int
    let missedSampleSlots: Int
    let thermalState: Int
}

struct BaselineGate: Encodable {
    let contractVersion = "opus-sustained-predata-v2-20261109"
    let referenceP50Ms = 18.1323335
    let thresholdExclusiveMs = 18.1323335 * 2
    let comparison = "lt"
    var observedP50Ms: Double?
    var deviationFromHistoricalWallPercent: Double?
    var sampleCount = 0
    var passed = false
    let gpuNote = "18.1323335ms is historical push wall p50, not GPU baseline. Analyze current-arm prefix GPU roots separately."
}

struct Report: Encodable {
    let format = "odf-air-sustained-cost-v1"
    let runID = UUID().uuidString
    let contextID: UInt64 = 1
    var status = "failed"
    var failureKind: String?
    var firstFailure: String?
    var functionalComplete = false
    var formalStarted = false
    var configuration: Configuration
    let hostClock: HostClock
    var runStartNs: UInt64 = 0
    var runEndNs: UInt64 = 0
    var modelIdentity: ModelIdentity?
    var device: String?
    var lowPowerMode: Bool?
    var firstInputSHA256: String?
    var secondInputSHA256: String?
    var lastOutputSHA256: String?
    var phases: [String: Phase] = [:]
    var baselineGate = BaselineGate()
    var jobs: [Job] = []
    var roots: [Root] = []
    var thermalSamples: [ThermalSample] = []
    var rootObservationsAttempted = 0
    var rootObservationsDropped = 0
    var traceOverflowTotal: UInt64 = 0
    var jobLimitReached = false
    let scope = "No window, SCK, presenter, source capture, FPS acceptance or quality acceptance. Thermal state is a coarse observation, not a temperature/frequency attribution."
    let prefixAndMeasurementAreSeparate = true
}

final class Harness {
    let options: Options
    var report: Report
    var nextJobID: UInt64 = 3
    var pushSequence = 0
    var observationSequence: UInt64 = 0
    var engine: RifeInterpolator?
    var output: CVPixelBuffer?

    init(_ options: Options) {
        self.options = options
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        report = Report(configuration: .init(mode: options.mode, seconds: options.seconds,
                        baselineSeconds: options.baselineSeconds, targetHz: options.mode == "paced24" ? 24 : 0,
                        expectedModelSHA256: options.expectedSHA256, modelPath: options.model.path),
                        hostClock: .init(machTimebaseNumer: timebase.numer, machTimebaseDenom: timebase.denom))
        report.jobs.reserveCapacity(12_000)
        report.roots.reserveCapacity(100_000)
        report.thermalSamples.reserveCapacity(220)
    }

    func checkCancel() throws {
        if FileManager.default.fileExists(atPath: options.cancelFile) { throw SustainedError.cancelled }
    }

    func readTrace(_ engine: RifeInterpolator, after: UInt64, phase: String) -> (Int, UInt64) {
        let count = engine.airServiceTraceCount, overflow = engine.airServiceTraceOverflow
        report.rootObservationsAttempted += count
        report.traceOverflowTotal &+= overflow
        for index in 0..<count {
            let row = engine.airServiceTraceRecord(at: index)
            observationSequence &+= 1
            if report.roots.count < maximumRoots {
                report.roots.append(Root(row, after: after, phase: phase, sequence: observationSequence))
            } else { report.rootObservationsDropped += 1 }
        }
        return (count, overflow)
    }

    func push(_ stream: RifeStream, engine: RifeInterpolator, first: CVPixelBuffer, second: CVPixelBuffer,
              output: CVPixelBuffer, phase: String, sequence: Int, slot: Int? = nil,
              targetNs: UInt64? = nil, missed: Int = 0) throws {
        try checkCancel()
        guard report.jobs.count < maximumJobs else { report.jobLimitReached = true; throw SustainedError.capacity }
        let id = nextJobID; nextJobID &+= 1
        let input = pushSequence.isMultiple(of: 2) ? second : first
        let inputShift = pushSequence.isMultiple(of: 2) ? 7 : 0
        pushSequence += 1
        engine.airServiceTraceBegin(jobID: id, stage: 3)
        var generated = false
        var failure: Error?
        // Keep this scope identical to the original complete-push cost probe.
        let start = DispatchTime.now().uptimeNanoseconds
        do { generated = try stream.push(input, into: output) } catch { failure = error }
        let end = DispatchTime.now().uptimeNanoseconds
        let (count, overflow) = readTrace(engine, after: id, phase: phase)
        report.jobs.append(Job(jobID: id, phase: phase, sequence: sequence, inputShift: inputShift,
                    wallStartNs: start, wallEndNs: end, wallNs: end - start, generated: generated,
                    scheduledSlot: slot, targetNs: targetNs, launchLagNs: targetNs.map { start >= $0 ? start - $0 : 0 },
                    missedSlotsBefore: missed, traceRecordCount: count, traceOverflow: overflow,
                    error: failure.map { String(describing: $0) }))
        if let failure { throw failure }
        guard generated else { throw SustainedError.native("missing midpoint in \(phase)") }
        guard count > 0, overflow == 0 else { throw SustainedError.trace("missing roots or trace scratch overflow") }
        guard report.rootObservationsDropped == 0 else { throw SustainedError.capacity }
    }

    func sampleThermal(phase: String, start: UInt64, due: Int, missed: Int) {
        let stamp = nowNs()
        report.thermalSamples.append(.init(phase: phase, sampleNs: stamp,
                    elapsedSeconds: Double(stamp - start) / 1e9, scheduledSampleIndex: due,
                    missedSampleSlots: missed, thermalState: ProcessInfo.processInfo.thermalState.rawValue))
    }

    func phase(_ name: String, seconds: Int, stream: RifeStream, engine: RifeInterpolator,
               first: CVPixelBuffer, second: CVPixelBuffer, output: CVPixelBuffer) throws {
        let start = nowNs(), nominalEnd = start + UInt64(seconds) * billion
        var state = Phase(startNs: start, requestedEndNs: nominalEnd, endNs: start, requestedSeconds: seconds)
        var slot = 0, skipped = 0, nextThermalIndex = 1
        sampleThermal(phase: name, start: start, due: 0, missed: 0)
        report.phases[name] = state
        defer {
            state.endNs = nowNs()
            let span = Double(state.endNs - start) / 1e9
            state.actualHz = span > 0 ? Double(state.jobCount) / span : 0
            if options.mode == "paced24" {
                let elapsedSlots = state.complete ? seconds * 24 : min(seconds * 24, Int((state.endNs - start) * 24 / billion) + 1)
                state.missedSlots = max(0, elapsedSlots - state.jobCount)
                state.trailingMissedSlots = max(0, state.missedSlots - state.skippedSlotsBeforeJobs)
            }
            report.phases[name] = state
        }
        while nowNs() < nominalEnd {
            try checkCancel()
            var target: UInt64?
            var missedBefore = 0
            if options.mode == "paced24" {
                if state.jobCount > 0 {
                    // Select a future tick. A late completed push never creates a backlog.
                    let ready = nowNs()
                    while start + UInt64(slot) * billion / 24 <= ready && slot < seconds * 24 {
                        slot += 1; skipped += 1
                    }
                }
                guard slot < seconds * 24 else { break }
                var tick = start + UInt64(slot) * billion / 24
                while true {
                    let stamp = nowNs()
                    if stamp < tick { Thread.sleep(forTimeInterval: Double(tick - stamp) / 1e9) }
                    try checkCancel()
                    let awake = nowNs()
                    if awake >= nominalEnd { break }
                    if awake < tick { continue }
                    if awake - tick < billion / 24 { break }
                    // A whole tick lost while asleep is skipped, never caught up.
                    repeat { slot += 1; skipped += 1; tick = start + UInt64(slot) * billion / 24 }
                    while tick <= awake && slot < seconds * 24
                    if slot >= seconds * 24 { break }
                }
                if nowNs() >= nominalEnd || slot >= seconds * 24 { break }
                target = tick; missedBefore = skipped; skipped = 0
            }
            try autoreleasepool {
                try push(stream, engine: engine, first: first, second: second, output: output,
                         phase: name, sequence: state.jobCount, slot: options.mode == "paced24" ? slot : nil,
                         targetNs: target, missed: missedBefore)
            }
            state.jobCount += 1
            state.skippedSlotsBeforeJobs += missedBefore
            slot += 1
            let stamp = nowNs()
            let elapsed = Int((stamp - start) / billion)
            if elapsed >= nextThermalIndex {
                sampleThermal(phase: name, start: start, due: elapsed, missed: elapsed - nextThermalIndex)
                print("phase=\(name) seconds=\(elapsed) jobs=\(state.jobCount)")
                fflush(stdout)
                nextThermalIndex = elapsed + 1
            }
        }
        state.complete = true
    }

    func execute() throws {
        report.runStartNs = nowNs()
        let env = ProcessInfo.processInfo.environment
        guard env["ODF_AIR_SERVICE_TRACE"] == "1", env["ODF_AIR_FOURSTAGE_MODEL_PATH"] == nil,
              (env["ODF_PERF_PROFILE"] ?? "off") == "off", env["ODF_K1_PROFILE"] != "1",
              env["RIFE_VERBOSE"] != "1", env["RIFE_DUMP_DIR"] == nil else {
            throw SustainedError.invalid("trace must be1; App override/profile/verbose/dump disabled")
        }
        try checkCancel()
        guard try sha(options.model) == options.expectedSHA256 else { throw SustainedError.invalid("source model SHA mismatch") }
        let engine = try RifeInterpolator(configuration: .init(modelURL: options.model, qualityTier: .fast,
                          experimentOptions: .init(gpuIO: true, replaceMask: false)))
        self.engine = engine
        let identity = engine.airDiagnosticModelIdentity
        report.configuration.actualLoadedModelIdentity = ModelIdentitySnapshot(identity)
        report.modelIdentity = try validateOriginalModelIdentity(identity)
        report.device = MTLCreateSystemDefaultDevice()?.name
        report.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let first = try image(width, height, 0), second = try image(width, height, 7)
        let output = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
        self.output = output
        report.firstInputSHA256 = pixelHash(first); report.secondInputSHA256 = pixelHash(second)
        try checkCancel()
        engine.airServiceTraceBegin(jobID: 1, stage: 1)
        let stream: RifeStream
        do { stream = try engine.makeStream(width: width, height: height) }
        catch { _ = readTrace(engine, after: 1, phase: "setup"); throw error }
        _ = readTrace(engine, after: 1, phase: "setup")
        try checkCancel()
        engine.airServiceTraceBegin(jobID: 2, stage: 2)
        do { _ = try stream.push(first, timesteps: []) }
        catch { _ = readTrace(engine, after: 2, phase: "setup"); throw error }
        _ = readTrace(engine, after: 2, phase: "setup")
        for index in 0..<20 {
            try autoreleasepool {
                try push(stream, engine: engine, first: first, second: second, output: output,
                         phase: "warmup", sequence: index)
            }
        }
        try phase("baseline", seconds: options.baselineSeconds, stream: stream, engine: engine,
                  first: first, second: second, output: output)
        try checkCancel()
        let times = report.jobs.filter { $0.phase == "baseline" && $0.generated }.map { Double($0.wallNs) / 1e6 }.sorted()
        report.baselineGate.sampleCount = times.count
        guard !times.isEmpty else { throw SustainedError.native("empty baseline") }
        let p50 = times.count.isMultiple(of: 2) ? (times[times.count / 2 - 1] + times[times.count / 2]) / 2 : times[times.count / 2]
        report.baselineGate.observedP50Ms = p50
        report.baselineGate.deviationFromHistoricalWallPercent = (p50 / referenceWallP50Ms - 1) * 100
        report.baselineGate.passed = p50 < referenceWallP50Ms * 2
        guard report.baselineGate.passed else { report.status = "baseline_not_ready"; return }
        try checkCancel()
        report.formalStarted = true
        try phase("measurement", seconds: options.seconds, stream: stream, engine: engine,
                  first: first, second: second, output: output)
        try checkCancel()
        report.status = "complete"; report.functionalComplete = true
    }

    func finish() throws {
        report.runEndNs = nowNs()
        if let output, report.jobs.contains(where: { $0.generated }) { report.lastOutputSHA256 = pixelHash(output) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Exceptional unsupported numeric values stay explicit; they are never zeros.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = try encoder.encode(report)
        guard !FileManager.default.fileExists(atPath: options.output.path) else { throw SustainedError.invalid("existing result retained") }
        try data.write(to: options.output, options: .atomic)
    }
}

do {
    if CommandLine.arguments.contains("--identity-check-only") { exit(try cpuIdentityCheck()) }
    guard let options = try Options.parse() else { exit(0) }
    let harness = Harness(options)
    do { try harness.execute() }
    catch {
        harness.report.functionalComplete = false
        harness.report.firstFailure = String(describing: error)
        switch error {
        case SustainedError.cancelled: harness.report.status = "cancelled"; harness.report.failureKind = "cancelled"
        case SustainedError.trace: harness.report.failureKind = "trace"
        case SustainedError.capacity: harness.report.failureKind = "capacity"
        default: harness.report.failureKind = "native_error"
        }
    }
    try harness.finish()
    print("status=\(harness.report.status) output=\(options.output.path)")
    switch harness.report.status {
    case "complete": exit(0)
    case "baseline_not_ready": exit(3)
    case "cancelled": exit(4)
    default: exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("air-sustained-cost: \(error)\n".utf8))
    exit(2)
}
