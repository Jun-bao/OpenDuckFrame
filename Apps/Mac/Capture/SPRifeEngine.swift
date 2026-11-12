import CoreVideo
import CoreMedia
import CryptoKit
import Foundation
import RifeMetal
import VideoToolbox
import os
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC || ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
import Metal
#endif
#if ODF_AIR_SERVICE_TRACE
import Darwin
import RifeMetalCore
#endif

@objc(SPAirRetainedPayloadBudget)
final class SPAirRetainedPayloadBudget: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let limitBytes: UInt64
    private var retainedBytes: UInt64 = 0
    private var peakRetainedBytes: UInt64 = 0
    private var reservationFailures: UInt64 = 0
    private var releaseMismatches: UInt64 = 0

    @objc(initWithLimitBytes:)
    init(limitBytes: UInt64) { self.limitBytes = limitBytes; super.init() }

    @objc(reserveBytes:)
    func reserveBytes(_ bytes: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes <= limitBytes - retainedBytes else {
            reservationFailures &+= 1
            return false
        }
        retainedBytes += bytes
        peakRetainedBytes = max(peakRetainedBytes, retainedBytes)
        return true
    }

    @objc(releaseBytes:)
    func releaseBytes(_ bytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard bytes <= retainedBytes else { releaseMismatches &+= 1; return }
        retainedBytes -= bytes
    }

    @objc(snapshot)
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["limitBytes": limitBytes, "retainedBytes": retainedBytes,
                "peakRetainedBytes": peakRetainedBytes, "reservationFailures": reservationFailures,
                "releaseMismatches": releaseMismatches]
    }
}

@objc(SPRifeBridge)
final class SPRifeBridge: NSObject {
    static let packageVersion = "0.1.8"
    static let packageCommit = "ac6408022eb6bc1a53181f5b2716a9f5ded507c2"
    static let model426SHA256 = "01c6ce74e26a3b2eb3430eb2c0bdb490e2725cb2f2bf6136c2b0e98148bc0ee1"

    private let resourceBundle: Bundle
    override init() { self.resourceBundle = .main; super.init() }
    @objc(initWithResourceBundle:)
    init(resourceBundle: Bundle) { self.resourceBundle = resourceBundle; super.init() }

    private let exec = DispatchQueue(label: "app.openduckframe.rife", qos: .userInitiated)
    private let state = NSLock()
    private var interpolator: RifeInterpolator?
    private var transfer: VTPixelTransferSession?
    private var epoch: UInt64 = 0
    private var loadedModelID = ""
    private var loadedQuality = "fast"
    private var loadedExperiment: [String: Any] = [:]
    private var preparedCaptureWidth = 0, preparedCaptureHeight = 0
    private var preparedProcessingWidth = 0, preparedProcessingHeight = 0
    private var preparedGPUInputOutput: Bool?
    @objc var processingWidth: Int32 {
        state.lock(); defer { state.unlock() }; return Int32(preparedProcessingWidth)
    }
    @objc var processingHeight: Int32 {
        state.lock(); defer { state.unlock() }; return Int32(preparedProcessingHeight)
    }
    // Only touched on exec. Retaining the source prevents pixel-buffer pool reuse.
    private var stream: RifeStream?
    private var streamEpoch: UInt64 = 0
    @objc var liveStreamEnabled = false
    /// Set by the live-window eligibility gate before preparing this instance.
    @objc var airPerformanceEnabled = false
    /// Selection intent only. The loaded production identity is validated in prepare.
    @objc(airPerformanceSelectionStatus)
    static func airPerformanceSelectionStatus() -> [String: Any] {
        guard SPRifeExperiments.isAvailable(in: .main) else {
            let defaults = RifeExperimentOptions()
            return ["eligible": defaults.gpuIO && !defaults.replaceMask,
                    "reason": "ODF-VFI four-stage default", "originalEF29": false,
                    "productionFourStage": true, "expectedGraphID": SPRifeProductionModel.graphID,
                    "expectedWeightsSHA256": SPRifeProductionModel.sha256,
                    "gpuIO": defaults.gpuIO, "accumulate": !defaults.replaceMask,
                    "selectionActive": false]
        }
        let selection = SPRifeExperiments.selection
        let original = selection.model == "original"
        let eligible = original && selection.ioOptimized && !selection.replaceMask
        return ["eligible": eligible, "reason": eligible ? "baseline selection" : "private experiment selection",
                "originalEF29": original, "gpuIO": selection.ioOptimized,
                "accumulate": !selection.replaceMask, "selectionActive": true]
    }
    private var contractFailNext = false // exec queue only
    private var pressureResetQueued = false // protected by state
    private var streamPreviousFormat: OSType = 0
    private var streamPrevious: CVPixelBuffer?
    private var streamKey: SPRifeContinuityKey?
    private var outputPool: CVPixelBufferPool?
    private let diagnosticLock = NSLock()
    private var diagnosticCounts: [String: Int] = [:]
    private var convertSamplesMs: [Double] = [], pushSamplesMs: [Double] = []
    private var recentJobs: [[String: Any]] = []
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    private let airPrescaleRequested = ProcessInfo.processInfo.environment["ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC"] == "1"
    // Prepared scalers and configuration are protected by state. Scaling runs only on exec.
    private var airPrescaleDown: SPSpatialScaler?
    private var airPrescaleUp: SPSpatialScaler?
    private var airPrescaleConfigVersion: UInt64 = 0
    private var streamPrescaleConfigVersion: UInt64?
    private var airPrescaleCacheEpoch: UInt64 = 0 // exec queue only
    // The diagnostic lock also protects the existing bounded timing records.
    private var airPrescaleActualSource: [Int]?
    private var airPrescaleActualProcess: [Int]?
    private var airPrescaleActualSynthetic: [Int]?
    private var airPrescaleActualOriginal: [Int]?
    private var airPrescaleFirstFailure: String?
    private var airPrescaleRecentJobs: [[String: Any]] = []
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    private let airFusedRequested = ProcessInfo.processInfo.environment["ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC"] == "1"
    private var airFusedPreprocessor: SPAirFusedPreprocessor? // protected by state
#endif
    @objc var fusedRifePresentEnabled: Bool {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        return (airFusedRequested || airPerformanceEnabled) && rifePrescaleEnabled && residentKeepAliveEnabled
#else
        return false
#endif
    }
    @objc var rifePrescaleEnabled: Bool {
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        return airPrescaleRequested || airPerformanceEnabled
#else
        return false
#endif
    }
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    // Protected by state. Prepared instances are published only after calibration.
    private var keeperInstances: [SPResidentKeepAlive] = []
    private var preparedKeeper: SPResidentKeepAlive?
    private var keeperPreparationVersion: UInt64 = 0
    private var keeperFirstFailure: String?
    private var keeperRifeDeviceRegistryID: UInt64?
    private var keeperRifeModelIdentity: [String: Any] = [:]
    private var keeperSessionJournal: SPAirKeeperSessionJournal?
    private let keeperSessionBridgeID = UUID().uuidString
#endif
#if ODF_AIR_SERVICE_TRACE
    // All storage is allocated once. Reads/writes use the existing state lock;
    // runtime records are copied only after an existing synchronous push returns.
    private var airServiceTrace: SPAirServiceTraceStore? =
        ProcessInfo.processInfo.environment["ODF_AIR_SERVICE_TRACE"] == "1" ? SPAirServiceTraceStore() : nil
#endif
    @objc var serviceTraceEnabled: Bool {
#if ODF_AIR_SERVICE_TRACE
        return airServiceTrace != nil
#else
        return false
#endif
    }
    @objc(setServiceTraceToken:configVersion:measurementEpoch:probe:probeIndex:probeRound:)
    func setServiceTrace(token: UInt64, configVersion: UInt64, measurementEpoch: UInt64,
                         probe: Bool, probeIndex: Int, probeRound: UInt64) {
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        state.lock(); airPrescaleConfigVersion = configVersion; state.unlock()
#endif
#if ODF_AIR_SERVICE_TRACE
        guard let trace = airServiceTrace else { return }
        state.lock()
        trace.nextMetadata = SPAirServiceMetadata(token: token, configVersion: configVersion,
            measurementEpoch: measurementEpoch, probe: probe, probeIndex: Int64(probeIndex), probeRound: probeRound)
        state.unlock()
#endif
    }

    @objc(serviceTraceSnapshotAtCutoffHostTicks:)
    func serviceTraceSnapshot(cutoffHostTicks: UInt64) -> [String: Any] {
#if ODF_AIR_SERVICE_TRACE
        let snapshot = captureServiceTrace(cutoffHostTicks: cutoffHostTicks)
        var result = serviceTraceMetadata(snapshot: snapshot)
        result["streamingExportRequired"] = true
        return result
#else
        return ["enabled": false, "compiled": false]
#endif
    }

    @objc var residentKeepAliveEnabled: Bool {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        return airPerformanceEnabled || ProcessInfo.processInfo.environment["ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC"] == "1"
#else
        return false
#endif
    }

    @objc(startKeeperForPlanToken:generation:configVersion:)
    func startKeeper(planToken: UInt64, generation: UInt64, configVersion: UInt64) -> Bool {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        guard residentKeepAliveEnabled else { return false }
        state.lock(); let keeper = preparedKeeper; state.unlock()
        guard let keeper else { keeperFailure("keeper start has no calibrated plan instance"); return false }
        return keeper.start(planToken: planToken, generation: generation, configVersion: configVersion)
#else
        return false
#endif
    }

    @objc(requestStopKeeperForPlanToken:reason:)
    func requestStopKeeper(planToken: UInt64, reason: String) {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock()
        if planToken == 0 { keeperPreparationVersion &+= 1; preparedKeeper = nil }
        let instances = keeperInstances
        state.unlock()
        for keeper in instances { keeper.requestStop(planToken: planToken, reason: reason) }
#endif
    }

    @objc(markKeeperPhase:forPlanToken:)
    func markKeeper(phase: String, planToken: UInt64) {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock(); let instances = keeperInstances; state.unlock()
        for keeper in instances { keeper.markPhase(phase, planToken: planToken) }
#endif
    }

    @objc(snapshotKeeperAtCutoffHostTicks:includeRecords:)
    func snapshotKeeper(cutoffHostTicks: UInt64, includeRecords: Bool) -> [String: Any] {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock()
        let instances = keeperInstances, failure = keeperFirstFailure, bridgeEpoch = epoch
        let rifeDevice = keeperRifeDeviceRegistryID
        let modelIdentity = keeperRifeModelIdentity
        state.unlock()
        let snapshots = instances.map { $0.snapshot(includeRecords: includeRecords) }
        let invalid = failure != nil || snapshots.contains {
            $0["firstFailure"] is String || ($0["overflow"] as? Bool) == true || ($0["drainTimedOut"] as? Bool) == true
        }
        return ["enabled": residentKeepAliveEnabled, "compiled": true,
                "bridgeEpoch": bridgeEpoch, "cutoffHostTicks": cutoffHostTicks,
                "snapshotUptimeNs": DispatchTime.now().uptimeNanoseconds,
                "includeRecords": includeRecords, "recordsIncludeTailDrainAfterCutoff": true,
                "rifeDeviceRegistryID": rifeDevice.map { $0 as Any } ?? NSNull(),
                "rifeModelIdentity": modelIdentity,
                "deviceBindingSource": "Same explicit MTLDevice passed to RIFE preferredDevice and keeper; InferenceContext uses preferredDevice without fallback",
                "instances": snapshots, "diagnosticInvalid": invalid,
                "firstFailure": failure.map { $0 as Any } ?? NSNull()]
#else
        return ["enabled": false, "compiled": false]
#endif
    }

    @objc(setKeeperSessionJournal:)
    func setKeeperSessionJournal(_ journal: NSObject?) {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock()
        keeperSessionJournal = journal as? SPAirKeeperSessionJournal
        let retained = keeperInstances, current = keeperSessionJournal
        state.unlock()
        if let current {
            for keeper in retained { keeper.attachSessionJournal(current, bridgeID: keeperSessionBridgeID) }
        }
#endif
    }

    @objc(recordKeeperRetirementForDiagnostics:)
    func recordKeeperRetirementForDiagnostics(_ reason: String) {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock(); let retained = keeperInstances; state.unlock()
        for keeper in retained { keeper.recordRetirement(reason: reason) }
#endif
    }

#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
    private func keeperFailure(_ message: String) {
        state.lock()
        if keeperFirstFailure == nil { keeperFirstFailure = message }
        state.unlock()
    }

    deinit {
        for keeper in keeperInstances { keeper.requestStop(planToken: 0, reason: "bridge_deinit") }
    }
#endif

#if ODF_AIR_SERVICE_TRACE
    private func airServiceEvent(_ kind: SPAirServiceEventKind, token: UInt64,
                                 detail: UInt64 = 0, value: Double = 0, sourceFourCC: UInt32 = 0,
                                 cacheEpoch: UInt64 = 0) {
        guard let trace = airServiceTrace else { return }
        let host = mach_absolute_time()
        state.lock()
        trace.appendEvent(kind: kind, token: token, host: host, detail: detail, value: value,
                          sourceFourCC: sourceFourCC, cacheEpoch: cacheEpoch)
        state.unlock()
    }

    private func admitAirServiceJob(token: UInt64, previousID: UInt64, currentID: UInt64,
                                    previousPTS: CMTime, currentPTS: CMTime,
                                    generation: UInt64, clockEpoch: UInt64, bridgeEpoch: UInt64) {
        guard let trace = airServiceTrace else { return }
        state.lock()
        trace.admit(token: token, previousID: previousID, currentID: currentID,
                    previousPTS: previousPTS, currentPTS: currentPTS, generation: generation,
                    clockEpoch: clockEpoch, bridgeEpoch: bridgeEpoch)
        state.unlock()
    }

    private func copyAirGPURecords(_ engine: RifeInterpolator) {
        guard let trace = airServiceTrace else { return }
        let count = engine.airServiceTraceCount
        state.lock()
        for index in 0..<count { trace.appendGPU(engine.airServiceTraceRecord(at: index)) }
        if trace.sealed { trace.postSealRuntimeOverflow &+= engine.airServiceTraceOverflow }
        else { trace.runtimeOverflow &+= engine.airServiceTraceOverflow }
        state.unlock()
    }
#endif
    private func count(_ name: String) {
        diagnosticLock.lock(); diagnosticCounts[name, default: 0] += 1; diagnosticLock.unlock()
    }
    private let traceLog = OSLog(subsystem: "app.chuanflow.throughput", category: "RIFE")

    @objc(prepareModelID:quality:width:height:error:)
    func prepare(modelID: String, quality: String, width: Int32, height: Int32) throws {
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        guard !airFusedRequested || fusedRifePresentEnabled else {
            throw Self.error(23, "Fused RIFE presentation requires both prescale and keeper diagnostics")
        }
#endif
        let adaptiveSizing = SPAirBetaEnabled() || airPerformanceEnabled
        let processingSize = adaptiveSizing ? SPAirBetaProcessingSize(width, height) : .zero
        if adaptiveSizing, let reason = SPAirBetaSizingReason(width, height) { throw Self.error(24, reason) }
        let processingWidth = adaptiveSizing ? Int(processingSize.width) : (rifePrescaleEnabled ? 1814 : Int(width))
        let processingHeight = adaptiveSizing ? Int(processingSize.height) : (rifePrescaleEnabled ? 1142 : Int(height))
        if !adaptiveSizing && rifePrescaleEnabled && (width != 2648 || height != 1668) {
            throw Self.error(22, "RIFE prescale requires actual 2648x1668 capture buffers")
        }
        let tier = Self.tier(quality)
        let url = try Self.url(for: modelID, bundle: resourceBundle)
        let experiment = try SPRifeExperiments.resolve(modelID: modelID, originalURL: url, bundle: resourceBundle)
        let options = experiment.map {
            RifeExperimentOptions(gpuIO: $0.selection.ioOptimized, replaceMask: $0.selection.replaceMask)
        } ?? RifeExperimentOptions()
        var configuration = RifeConfiguration(
            modelURL: experiment?.url ?? url, qualityTier: tier, preferredDevice: nil,
            experimentOptions: options)
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        if rifePrescaleEnabled { configuration.preferredDevice = MTLCreateSystemDefaultDevice() }
#endif
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        requestStopKeeper(planToken: 0, reason: "prepare_replaced")
        state.lock(); let keeperPreparation = keeperPreparationVersion; state.unlock()
        let keeperRequested = residentKeepAliveEnabled
        if keeperRequested {
            if configuration.preferredDevice == nil { configuration.preferredDevice = MTLCreateSystemDefaultDevice() }
            if configuration.preferredDevice == nil { keeperFailure("keeper shared Metal device unavailable") }
        }
#endif
        let engine = try RifeInterpolator(configuration: configuration)
        if modelID == "rife-v4.25", experiment == nil,
           !SPRifeProductionModel.matchesLoadedIdentity(engine.airDiagnosticModelIdentity) {
            throw Self.error(25, "Bundled ODF-VFI model identity differs from the released four-stage weights")
        }
        let previousNV = try Self.nv12(width: processingWidth, height: processingHeight, luma: 32)
        let currentNV = try Self.nv12(width: processingWidth, height: processingHeight, luma: 180)
        let previous = try ownedBGRA(previousNV)
        let current = try ownedBGRA(currentNV)
        let warmed = try engine.interpolate(previous: previous, current: current, timesteps: [0.5])
        guard warmed.count == 1 else { throw Self.error(2, "RIFE 预热没有返回中间帧") }
        guard CVPixelBufferGetWidth(warmed[0]) == processingWidth, CVPixelBufferGetHeight(warmed[0]) == processingHeight else {
            throw Self.error(2, "RIFE 预热输出尺寸和来源不一致")
        }
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        var down: SPSpatialScaler?, up: SPSpatialScaler?
        if rifePrescaleEnabled {
            guard liveStreamEnabled, tier == .fast, modelID == "rife-v4.25", options.gpuIO,
                  !options.replaceMask, let device = configuration.preferredDevice else {
                throw Self.error(22, "RIFE prescale requires the frozen EF29/Fast/GPU-IO live stream configuration")
            }
            if !fusedRifePresentEnabled {
                down = try SPSpatialScaler(device: device, inputW: width, inputH: height,
                    outputW: Int32(processingWidth), outputH: Int32(processingHeight), engine: .lanczos)
                up = try SPSpatialScaler(device: device, inputW: Int32(processingWidth), inputH: Int32(processingHeight),
                    outputW: width, outputH: height, engine: .lanczos)
            }
        }
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        var fusedPreprocessor: SPAirFusedPreprocessor?
        if fusedRifePresentEnabled {
            guard let device = configuration.preferredDevice else { throw Self.error(23, "Fused RIFE Metal device is unavailable") }
            let library = try device.makeDefaultLibrary(bundle: resourceBundle)
            fusedPreprocessor = try SPAirFusedPreprocessor(device: device, library: library,
                sourceWidth: width, sourceHeight: height, outputWidth: Int32(processingWidth), outputHeight: Int32(processingHeight))
        }
#endif
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        var candidateKeeper: SPResidentKeepAlive?
        if keeperRequested, let device = configuration.preferredDevice {
            do {
                let identity = engine.airDiagnosticModelIdentity
                guard modelID == "rife-v4.25", tier == .fast,
                      adaptiveSizing || (processingWidth == 1814 && processingHeight == 1142),
                      SPRifeProductionModel.matchesLoadedIdentity(identity),
                      !options.replaceMask, options.gpuIO,
                      let library = resourceBundle.url(forResource: "gap-fill", withExtension: "metallib") else {
                    throw Self.error(21, "App keeper requires the production ODF-VFI/Fast/GPU-IO configuration and metallib")
                }
                let expectedMetallibSHA256 = try airPerformanceEnabled
                    ? SPResidentKeepAliveMetallib.productionSHA256(bundle: resourceBundle) : SPResidentKeepAliveMetallib.diagnosticSHA256
                let keeper = try SPResidentKeepAlive(device: device, libraryURL: library,
                                                     expectedMetallibSHA256: expectedMetallibSHA256)
                candidateKeeper = keeper
                keeper.setSessionIdentity(deviceRegistryID: device.registryID, modelIdentity: identity)
                state.lock(); let journal = keeperSessionJournal; state.unlock()
                if let journal { keeper.attachSessionJournal(journal, bridgeID: keeperSessionBridgeID) }
                try keeper.calibrate {
                    self.state.lock(); let valid = self.keeperPreparationVersion == keeperPreparation; self.state.unlock()
                    if !valid { throw Self.error(21, "keeper preparation was retired") }
                }
            } catch {
                keeperFailure(String(describing: error))
                candidateKeeper?.requestStop(planToken: 0, reason: "prepare_failed")
                if adaptiveSizing { throw Self.error(24, "Air保活初始化失败，现以原帧播放：\(error.localizedDescription)") }
            }
        }
        if adaptiveSizing && candidateKeeper == nil { throw Self.error(24, "Air保活未能准备，现以原帧播放") }
#endif
        state.lock()
        epoch &+= 1
        interpolator = engine
        loadedModelID = modelID
        loadedQuality = tier.rawValue
        preparedGPUInputOutput = configuration.experimentOptions.gpuIO
        loadedExperiment = experiment?.diagnostics ?? [:]
        preparedCaptureWidth = Int(width); preparedCaptureHeight = Int(height)
        preparedProcessingWidth = processingWidth; preparedProcessingHeight = processingHeight
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        airPrescaleDown = down
        airPrescaleUp = up
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        airFusedPreprocessor = fusedPreprocessor
#endif
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        keeperRifeDeviceRegistryID = configuration.preferredDevice?.registryID
        keeperRifeModelIdentity = keeperRequested ? engine.airDiagnosticModelIdentity : [:]
        let keeperIsCurrent = keeperPreparationVersion == keeperPreparation
        if let keeper = candidateKeeper {
            if keeperInstances.count < 8 {
                keeperInstances.append(keeper)
                if keeperIsCurrent { preparedKeeper = keeper }
            } else if keeperFirstFailure == nil { keeperFirstFailure = "keeper instance receipt capacity exceeded" }
        }
#endif
#if ODF_AIR_SERVICE_TRACE
        airServiceTrace?.modelIdentity = engine.airDiagnosticModelIdentity
#endif
        state.unlock()
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        if !keeperIsCurrent { candidateKeeper?.requestStop(planToken: 0, reason: "prepare_retired") }
#endif
    }

    @objc(submitPrevious:current:timesteps:token:completion:)
    func submit(previous: CVPixelBuffer, current: CVPixelBuffer, timesteps: [NSNumber], token: UInt64, completion: @escaping (UInt64, [SPOwnedPixelBuffer]?, Double, Error?) -> Void) -> Bool {
        let phases = timesteps.map(\.floatValue)
        guard !phases.isEmpty, phases.allSatisfy({ $0 > 0 && $0 < 1 }) else { return false }
        state.lock()
        let engine = interpolator
        let seen = epoch
        state.unlock()
        guard let engine else { return false }
#if ODF_AIR_SERVICE_TRACE
        // This older API has no immutable source identities/PTS. Do not invent them.
        airServiceEvent(.unsupportedStatelessSubmit, token: token)
#endif
        exec.async {
            self.state.lock()
            let currentEpoch = self.epoch
            self.state.unlock()
            if currentEpoch != seen {
                completion(token, nil, 0, Self.error(1, "RIFE 结果属于旧会话"))
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let trace = ProcessInfo.processInfo.environment["CHUANFLOW_THROUGHPUT_TRACE"] == "1"
            let log = self.traceLog
            let signpost = trace ? OSSignpostID(log: log) : .invalid
            if trace { os_signpost(.begin, log: log, name: "RIFE stateless", signpostID: signpost) }
            defer { if trace { os_signpost(.end, log: log, name: "RIFE stateless", signpostID: signpost) } }
            do {
                let left = try self.ownedBGRA(previous)
                let right = try self.ownedBGRA(current)
                let frames = try engine.interpolate(previous: left, current: right, timesteps: phases)
                guard frames.count == phases.count else {
                    completion(token, nil, 0, Self.error(2, "RIFE 输出数量和相位不一致"))
                    return
                }
                let owned: [SPOwnedPixelBuffer] = frames.map { buffer in
                    CVBufferPropagateAttachments(left, buffer)
                    Self.attach709IfMissing(buffer)
                    return SPOwnedPixelBuffer(retaining: buffer)
                }
                let elapsed = SPPerformanceSimulation.current.finish(started: started)
                completion(token, owned, elapsed, nil)
            } catch {
                completion(token, nil, max(0, ProcessInfo.processInfo.systemUptime - started), Self.explain(error))
            }
        }
        return true
    }

    @objc(submitLivePrevious:current:previousID:currentID:previousPTS:currentPTS:generation:clockEpoch:timesteps:token:completion:)
    func submitLive(previous: CVPixelBuffer, current: CVPixelBuffer, previousID: UInt64, currentID: UInt64,
                    previousPTS: CMTime, currentPTS: CMTime, generation: UInt64, clockEpoch: UInt64,
                    timesteps: [NSNumber], token: UInt64,
                    completion: @escaping (UInt64, [SPOwnedPixelBuffer]?, Double, Error?) -> Void) -> Bool {
        // Default remains the proven stateless bridge until equivalence is measured.
        guard liveStreamEnabled || ProcessInfo.processInfo.environment["CHUANFLOW_RIFE_STREAM"] == "1" else {
            return submit(previous: previous, current: current, timesteps: timesteps, token: token, completion: completion)
        }
        let phases = timesteps.map(\.floatValue)
        guard !phases.isEmpty, phases.allSatisfy({ $0 > 0 && $0 < 1 }),
              previousPTS.isNumeric, currentPTS.isNumeric, CMTimeCompare(previousPTS, currentPTS) < 0,
              previousID != currentID else { return false }
        state.lock(); let engine = interpolator; let seen = epoch
        let captureWidth = preparedCaptureWidth, captureHeight = preparedCaptureHeight
        let processWidth = preparedProcessingWidth, processHeight = preparedProcessingHeight
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        let prescaleDown = airPrescaleDown, prescaleUp = airPrescaleUp
        let prescaleConfigVersion = airPrescaleConfigVersion
#else
        let prescaleDown: SPSpatialScaler? = nil
#endif
        state.unlock()
        guard let engine else { return false }
#if ODF_AIR_SERVICE_TRACE
        admitAirServiceJob(token: token, previousID: previousID, currentID: currentID,
            previousPTS: previousPTS, currentPTS: currentPTS, generation: generation,
            clockEpoch: clockEpoch, bridgeEpoch: seen)
        airServiceEvent(.enqueueCallBegin, token: token)
#endif
        exec.async {
            autoreleasepool {
#if ODF_AIR_SERVICE_TRACE
                self.airServiceEvent(.execBegin, token: token)
#endif
                let started = ProcessInfo.processInfo.systemUptime
                let trace = ProcessInfo.processInfo.environment["CHUANFLOW_THROUGHPUT_TRACE"] == "1"
                let log = self.traceLog
                let signpost = trace ? OSSignpostID(log: log) : .invalid
                if trace { os_signpost(.begin, log: log, name: "RIFE stream", signpostID: signpost) }
                defer { if trace { os_signpost(.end, log: log, name: "RIFE stream", signpostID: signpost) } }
                self.state.lock(); let active = self.epoch == seen; self.state.unlock()
                guard active else {
#if ODF_AIR_SERVICE_TRACE
                    self.airServiceEvent(.retiredBeforeExecution, token: token)
#endif
                    completion(token, nil, 0, Self.error(1, "RIFE 结果属于旧会话")); return
                }
                var convertNs: UInt64 = 0, pushNs: UInt64 = 0
                var convertCalls = 0, pushCalls = 0
                var cacheHit: Bool?
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                var downscaleNs: UInt64 = 0, upscaleNs: UInt64 = 0
                var downscaleCalls = 0, upscaleCalls = 0
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
                var fusedPreprocessNs: UInt64 = 0
                var fusedPreprocessCalls = 0
                func measuredFusedInput(_ bridge: SPRifeBridge, _ source: CVPixelBuffer,
                                        role: UInt64, processor: SPAirFusedPreprocessor) throws -> CVPixelBuffer {
#if ODF_AIR_SERVICE_TRACE
                    var colorMask: UInt64 = CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
                    if let matrix = CVBufferGetAttachment(source, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue(),
                       CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { colorMask |= 2 }
                    if let primaries = CVBufferGetAttachment(source, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue(),
                       CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2) { colorMask |= 4 }
                    if let transfer = CVBufferGetAttachment(source, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue(),
                       CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2) { colorMask |= 8 }
                    bridge.airServiceEvent(.fusedPreprocessBegin, token: token, detail: role, value: Double(colorMask),
                        sourceFourCC: CVPixelBufferGetPixelFormatType(source), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    let began = DispatchTime.now().uptimeNanoseconds
                    defer {
                        fusedPreprocessNs += DispatchTime.now().uptimeNanoseconds - began
                        fusedPreprocessCalls += 1
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.fusedPreprocessEnd, token: token, detail: role, cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    }
                    let small = try processor.processNV12Buffer(source)
                    let width = CVPixelBufferGetWidth(small), height = CVPixelBufferGetHeight(small)
                    bridge.observePrescaleDimensions(source: source, process: small)
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.prescaleProcessDimensions, token: token,
                        detail: UInt64(width), value: Double(height), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    guard width == processWidth, height == processHeight else { throw Self.error(23, "Fused RIFE input dimensions changed") }
                    return small
                }
#endif
                func measuredBGRA(_ bridge: SPRifeBridge, _ source: CVPixelBuffer,
                                  role: UInt64, scaler: SPSpatialScaler?) throws -> CVPixelBuffer {
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.ownedBGRABegin, token: token, detail: role)
#endif
                    let began = DispatchTime.now().uptimeNanoseconds
                    defer {
                        convertNs += DispatchTime.now().uptimeNanoseconds - began; convertCalls += 1
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.ownedBGRAEnd, token: token, detail: role)
#endif
                    }
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
                    if bridge.fusedRifePresentEnabled {
                        bridge.state.lock(); let processor = bridge.airFusedPreprocessor; bridge.state.unlock()
                        guard let processor else { throw Self.error(23, "Fused RIFE preprocessor is unavailable") }
                        return try measuredFusedInput(bridge, source, role: role, processor: processor)
                    }
#endif
                    let bgra = try bridge.ownedBGRA(source, diagnosticToken: token, diagnosticRole: role)
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if bridge.rifePrescaleEnabled {
                        guard let scaler else { throw Self.error(22, "RIFE prescale downscaler is unavailable") }
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.prescaleDownBegin, token: token, detail: role, cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                        let downBegan = DispatchTime.now().uptimeNanoseconds
                        defer {
                            downscaleNs += DispatchTime.now().uptimeNanoseconds - downBegan
                            downscaleCalls += 1
#if ODF_AIR_SERVICE_TRACE
                            bridge.airServiceEvent(.prescaleDownEnd, token: token, detail: role, cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                        }
                        let small = try scaler.scale(bgra)
                        let smallWidth = CVPixelBufferGetWidth(small), smallHeight = CVPixelBufferGetHeight(small)
                        bridge.observePrescaleDimensions(source: source, process: small)
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.prescaleProcessDimensions, token: token,
                            detail: UInt64(smallWidth), value: Double(smallHeight), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                        guard smallWidth == 1814, smallHeight == 1142 else {
                            throw Self.error(22, "RIFE prescale process dimensions changed")
                        }
                        return small
                    }
#endif
                    return bgra
                }
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                func measuredUpscale(_ bridge: SPRifeBridge, _ buffer: CVPixelBuffer,
                                     index: Int, scaler: SPSpatialScaler) throws -> CVPixelBuffer {
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.prescaleUpBegin, token: token, detail: UInt64(index), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    let upBegan = DispatchTime.now().uptimeNanoseconds
                    defer {
                        upscaleNs += DispatchTime.now().uptimeNanoseconds - upBegan
                        upscaleCalls += 1
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.prescaleUpEnd, token: token, detail: UInt64(index), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    }
                    let full = try scaler.scale(buffer)
                    let fullWidth = CVPixelBufferGetWidth(full), fullHeight = CVPixelBufferGetHeight(full)
                    bridge.observePrescaleDimensions(synthetic: full)
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.prescaleSyntheticDimensions, token: token,
                        detail: UInt64(fullWidth), value: Double(fullHeight), cacheEpoch: bridge.airPrescaleCacheEpoch)
#endif
                    guard fullWidth == 2648, fullHeight == 1668 else {
                        throw Self.error(22, "RIFE prescale synthetic dimensions changed")
                    }
                    return full
                }
#endif
                func measuredPush<T>(_ bridge: SPRifeBridge, stage: UInt32, _ operation: () throws -> T) rethrows -> T {
#if ODF_AIR_SERVICE_TRACE
                    if bridge.airServiceTrace != nil {
                        bridge.airServiceEvent(.pushBegin, token: token, detail: UInt64(stage))
                        engine.airServiceTraceBegin(jobID: token, stage: stage)
                    }
#endif
                    let began = DispatchTime.now().uptimeNanoseconds
                    defer {
                        pushNs += DispatchTime.now().uptimeNanoseconds - began; pushCalls += 1
#if ODF_AIR_SERVICE_TRACE
                        bridge.airServiceEvent(.pushEnd, token: token, detail: UInt64(stage))
                        bridge.copyAirGPURecords(engine)
#endif
                    }
                    return try operation()
                }
                func recordTiming(_ bridge: SPRifeBridge) -> Double {
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.latencyFinishBegin, token: token)
#endif
                    let elapsed = SPPerformanceSimulation.current.finish(started: started)
#if ODF_AIR_SERVICE_TRACE
                    bridge.airServiceEvent(.latencyFinishEnd, token: token, value: elapsed)
#endif
                    bridge.recordStreamTiming(totalMs: elapsed * 1000,
                                              convertMs: convertCalls > 0 ? Double(convertNs) / 1e6 : nil,
                                              pushMs: pushCalls > 0 ? Double(pushNs) / 1e6 : nil,
                                              hit: cacheHit)
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if bridge.rifePrescaleEnabled {
                        bridge.recordPrescaleTiming(downCalls: downscaleCalls, upCalls: upscaleCalls,
                            downMs: Double(downscaleNs) / 1e6, upMs: Double(upscaleNs) / 1e6,
                            totalMs: elapsed * 1000, hit: cacheHit, token: token,
                            configVersion: prescaleConfigVersion, bridgeEpoch: seen)
                    }
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
                    if bridge.fusedRifePresentEnabled {
                        bridge.recordFusedTiming(calls: fusedPreprocessCalls, milliseconds: Double(fusedPreprocessNs) / 1e6)
                    }
#endif
                    return elapsed
                }
                func measuredFallback<T>(_ bridge: SPRifeBridge, _ operation: () throws -> T) rethrows -> T {
#if ODF_AIR_SERVICE_TRACE
                    if bridge.airServiceTrace != nil {
                        bridge.airServiceEvent(.fallbackBegin, token: token)
                        engine.airServiceTraceBegin(jobID: token, stage: 4)
                    }
                    defer {
                        bridge.airServiceEvent(.fallbackEnd, token: token)
                        bridge.copyAirGPURecords(engine)
                    }
#endif
                    return try operation()
                }
                func measuredStreamCreation(_ bridge: SPRifeBridge, width: Int, height: Int) throws -> RifeStream {
#if ODF_AIR_SERVICE_TRACE
                    if bridge.airServiceTrace != nil {
                        bridge.airServiceEvent(.streamCreateBegin, token: token)
                        engine.airServiceTraceBegin(jobID: token, stage: 1)
                    }
                    defer {
                        bridge.airServiceEvent(.streamCreateEnd, token: token)
                        bridge.copyAirGPURecords(engine)
                    }
#endif
                    return try engine.makeStream(width: width, height: height)
                }
                do {
                    let sourceWidth = CVPixelBufferGetWidth(previous), sourceHeight = CVPixelBufferGetHeight(previous)
                    guard sourceWidth == CVPixelBufferGetWidth(current), sourceHeight == CVPixelBufferGetHeight(current) else {
                        throw Self.error(2, "RIFE 输入尺寸不一致")
                    }
                    let width = self.rifePrescaleEnabled ? processWidth : sourceWidth
                    let height = self.rifePrescaleEnabled ? processHeight : sourceHeight
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if self.rifePrescaleEnabled {
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.prescaleSourceDimensions, token: token,
                            detail: UInt64(sourceWidth), value: Double(sourceHeight), cacheEpoch: self.airPrescaleCacheEpoch)
#endif
                        guard sourceWidth == captureWidth, sourceHeight == captureHeight,
                              self.fusedRifePresentEnabled || (prescaleDown != nil && prescaleUp != nil) else {
                            throw Self.error(22, "RIFE prescale requires prepared 2648x1668 capture and 1814x1142 processing")
                        }
                    }
#endif
                    if self.stream == nil || self.streamEpoch != seen || self.stream?.width != width || self.stream?.height != height {
                        self.stream = try measuredStreamCreation(self, width: width, height: height)
                        self.streamEpoch = seen; self.streamPrevious = nil; self.streamKey = nil; self.outputPool = nil
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                        self.advancePrescaleCache(token: token, reason: 7)
#endif
                    }
                    let stream = self.stream!
                    if self.contractFailNext {
                        self.contractFailNext = false
                        throw Self.error(99, "injected stream failure")
                    }
                    let previousKey = SPRifeContinuityKey(address: UInt(bitPattern: Unmanaged.passUnretained(previous).toOpaque()),
                        identity: previousID, pts: previousPTS, generation: generation, clockEpoch: clockEpoch)
                    let previousFormat = CVPixelBufferGetPixelFormatType(previous)
                    let currentFormat = CVPixelBufferGetPixelFormatType(current)
                    var hit = previousFormat == currentFormat && self.streamPreviousFormat == previousFormat &&
                        self.streamPrevious === previous && self.streamKey?.matches(previousKey) == true
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if self.rifePrescaleEnabled { hit = hit && self.streamPrescaleConfigVersion == prescaleConfigVersion }
#endif
                    cacheHit = hit
#if ODF_AIR_SERVICE_TRACE
                    if self.airServiceTrace != nil {
                        var keyMask: UInt64 = 0
                        if previousFormat == currentFormat { keyMask |= 1 }
                        if self.streamPreviousFormat == previousFormat { keyMask |= 2 }
                        if self.streamPrevious === previous { keyMask |= 4 }
                        if self.streamKey?.matches(previousKey) == true { keyMask |= 8 }
                        self.airServiceEvent(.cacheDecision, token: token, detail: keyMask, value: hit ? 1 : 0)
                    }
#endif
                    if hit { self.count("hits") } else {
                        self.count("misses")
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.streamResetBegin, token: token, detail: 1)
#endif
                        stream.reset(); self.streamPrevious = nil; self.streamKey = nil; self.count("resets")
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                        self.advancePrescaleCache(token: token, reason: 1)
#endif
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.streamResetEnd, token: token, detail: 1)
#endif
                        let left = try measuredBGRA(self, previous, role: 1, scaler: prescaleDown)
                        guard try measuredPush(self, stage: 2, { try stream.push(left, timesteps: []) }).isEmpty else { throw Self.error(2, "RIFE 缓存初始化失败") }
                    }
                    let right = try measuredBGRA(self, current, role: 2, scaler: prescaleDown)
                    let frames: [CVPixelBuffer]
                    if phases.count == 1 && phases[0] == 0.5 {
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.outputPoolBegin, token: token)
#endif
                        let output = try self.pooledOutput(width: width, height: height)
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.outputPoolEnd, token: token)
#endif
                        guard try measuredPush(self, stage: 3, { try stream.push(right, into: output) }) else { throw Self.error(2, "RIFE 中间帧缺失") }
                        frames = [output]
                    } else {
                        frames = try measuredPush(self, stage: 3) { try stream.push(right, timesteps: phases) }
                    }
                    guard frames.count == phases.count, frames.allSatisfy({ CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height }) else {
                        throw Self.error(2, "RIFE 输出数量或尺寸不一致")
                    }
                    self.streamPrevious = current
                    self.streamPreviousFormat = currentFormat
                    self.streamKey = SPRifeContinuityKey(address: UInt(bitPattern: Unmanaged.passUnretained(current).toOpaque()),
                        identity: currentID, pts: currentPTS, generation: generation, clockEpoch: clockEpoch)
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if self.rifePrescaleEnabled { self.streamPrescaleConfigVersion = prescaleConfigVersion }
#endif
                    self.state.lock(); let stillActive = self.epoch == seen; self.state.unlock()
                    guard stillActive else {
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.streamResetBegin, token: token, detail: 2)
#endif
                        stream.reset(); self.streamPrevious = nil; self.streamKey = nil
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                        self.advancePrescaleCache(token: token, reason: 2)
#endif
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.streamResetEnd, token: token, detail: 2)
#endif
                        throw Self.error(1, "RIFE 结果属于旧会话")
                    }
#if ODF_AIR_SERVICE_TRACE
                    self.airServiceEvent(.wrapBegin, token: token)
#endif
                    var finalFrames = frames
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if self.rifePrescaleEnabled && !self.fusedRifePresentEnabled {
                        guard let prescaleUp else { throw Self.error(22, "RIFE prescale upscaler is unavailable") }
                        var fullFrames: [CVPixelBuffer] = []
                        for (index, buffer) in frames.enumerated() {
                            fullFrames.append(try measuredUpscale(self, buffer, index: index, scaler: prescaleUp))
                        }
                        finalFrames = fullFrames
                        self.state.lock(); let currentEpoch = self.epoch == seen; self.state.unlock()
                        guard currentEpoch else { throw Self.error(1, "RIFE 结果属于旧会话") }
                    }
                    if self.fusedRifePresentEnabled {
                        for buffer in finalFrames {
                            self.observePrescaleDimensions(synthetic: buffer)
#if ODF_AIR_SERVICE_TRACE
                            self.airServiceEvent(.prescaleSyntheticDimensions, token: token,
                                detail: UInt64(CVPixelBufferGetWidth(buffer)), value: Double(CVPixelBufferGetHeight(buffer)),
                                cacheEpoch: self.airPrescaleCacheEpoch)
#endif
                        }
                    }
#endif
                    let owned = finalFrames.map { buffer in
                        CVBufferPropagateAttachments(previous, buffer); Self.attach709IfMissing(buffer)
                        return SPOwnedPixelBuffer(retaining: buffer)
                    }
#if ODF_AIR_SERVICE_TRACE
                    self.airServiceEvent(.wrapEnd, token: token)
                    self.airServiceEvent(.completionWillDeliver, token: token, detail: UInt64(owned.count))
#endif
                    completion(token, owned, recordTiming(self), nil)
                } catch {
#if ODF_AIR_SERVICE_TRACE
                    self.airServiceEvent(.streamResetBegin, token: token, detail: 3)
#endif
                    self.stream?.reset(); self.streamPrevious = nil; self.streamKey = nil; self.count("resets")
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    self.advancePrescaleCache(token: token, reason: 3)
#endif
#if ODF_AIR_SERVICE_TRACE
                    self.airServiceEvent(.streamResetEnd, token: token, detail: 3)
#endif
                    let failure = Self.explain(error) as NSError
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                    if self.rifePrescaleEnabled {
                        self.recordPrescaleFailure(failure.localizedDescription)
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.completionWillFail, token: token, detail: UInt64(bitPattern: Int64(failure.code)))
#endif
                        completion(token, nil, recordTiming(self), failure)
                        return
                    }
#endif
                    if failure.domain == "app.openduckframe.rife" && failure.code == 10 {
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.completionWillFail, token: token, detail: UInt64(bitPattern: Int64(failure.code)))
#endif
                        completion(token, nil, recordTiming(self), failure)
                        return
                    }
                    // Retry with the same model, quality, resolution and phases.
                    // A retired epoch is never allowed to publish fallback output.
                    do {
                        self.state.lock(); let active = self.epoch == seen; self.state.unlock()
                        guard active else { throw Self.error(1, "RIFE 结果属于旧会话") }
                        let left = try measuredBGRA(self, previous, role: 3, scaler: prescaleDown)
                        let right = try measuredBGRA(self, current, role: 4, scaler: prescaleDown)
                        let frames = try measuredFallback(self) { try engine.interpolate(previous: left, current: right, timesteps: phases) }
                        guard frames.count == phases.count, frames.allSatisfy({
                            CVPixelBufferGetWidth($0) == CVPixelBufferGetWidth(previous) &&
                            CVPixelBufferGetHeight($0) == CVPixelBufferGetHeight(previous)
                        }) else { throw Self.error(2, "RIFE 回退输出数量或尺寸不一致") }
                        self.state.lock(); let stillActive = self.epoch == seen; self.state.unlock()
                        guard stillActive else { throw Self.error(1, "RIFE 结果属于旧会话") }
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.wrapBegin, token: token, detail: 1)
#endif
                        let owned = frames.map { buffer in
                            CVBufferPropagateAttachments(left, buffer); Self.attach709IfMissing(buffer)
                            return SPOwnedPixelBuffer(retaining: buffer)
                        }
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.wrapEnd, token: token, detail: 1)
#endif
                        self.count("fallbackSucceeded")
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.completionWillDeliver, token: token, detail: UInt64(owned.count))
#endif
                        completion(token, owned, recordTiming(self), nil)
                    } catch {
                        self.count("fallbackFailed")
#if ODF_AIR_SERVICE_TRACE
                        self.airServiceEvent(.completionWillFail, token: token, detail: UInt64(bitPattern: Int64((error as NSError).code)))
#endif
                        completion(token, nil, recordTiming(self), Self.explain(error))
                    }
                }
            }
        }
        return true
    }

#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    private func advancePrescaleCache(token: UInt64, reason: UInt64) {
        guard rifePrescaleEnabled else { return }
        airPrescaleCacheEpoch &+= 1
        streamPrescaleConfigVersion = nil
        count("prescaleCacheResets")
#if ODF_AIR_SERVICE_TRACE
        airServiceEvent(.prescaleCacheEpoch, token: token, detail: reason, cacheEpoch: airPrescaleCacheEpoch)
#endif
    }

    private func observePrescaleDimensions(source: CVPixelBuffer? = nil, process: CVPixelBuffer? = nil,
                                           synthetic: CVPixelBuffer? = nil) {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        if let source {
            airPrescaleActualSource = [CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source)]
            if airPrescaleActualSource != [preparedCaptureWidth, preparedCaptureHeight] { diagnosticCounts["prescaleDimensionMismatches", default: 0] += 1 }
        }
        if let process {
            airPrescaleActualProcess = [CVPixelBufferGetWidth(process), CVPixelBufferGetHeight(process)]
            if airPrescaleActualProcess != [preparedProcessingWidth, preparedProcessingHeight] { diagnosticCounts["prescaleDimensionMismatches", default: 0] += 1 }
        }
        if let synthetic {
            airPrescaleActualSynthetic = [CVPixelBufferGetWidth(synthetic), CVPixelBufferGetHeight(synthetic)]
            let expected = fusedRifePresentEnabled ? [preparedProcessingWidth, preparedProcessingHeight] : [preparedCaptureWidth, preparedCaptureHeight]
            if airPrescaleActualSynthetic != expected { diagnosticCounts["prescaleDimensionMismatches", default: 0] += 1 }
        }
    }

    private func recordPrescaleTiming(downCalls: Int, upCalls: Int, downMs: Double, upMs: Double,
                                      totalMs: Double, hit: Bool?, token: UInt64,
                                      configVersion: UInt64, bridgeEpoch: UInt64) {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        diagnosticCounts["prescaleJobs", default: 0] += 1
        diagnosticCounts["prescaleDownscaleCalls", default: 0] += downCalls
        diagnosticCounts["prescaleUpscaleCalls", default: 0] += upCalls
        if let hit { diagnosticCounts[hit ? "prescaleCacheHits" : "prescaleCacheMisses", default: 0] += 1 }
        airPrescaleRecentJobs.append([
            "token": token, "configVersion": configVersion, "bridgeEpoch": bridgeEpoch,
            "cacheEpoch": airPrescaleCacheEpoch, "cacheHit": hit.map { $0 as Any } ?? NSNull(),
            "downscaleCalls": downCalls, "upscaleCalls": upCalls,
            "downscaleMs": downMs, "upscaleMs": upMs, "totalMs": totalMs,
            "MIncludesDownAndUp": !fusedRifePresentEnabled])
        if airPrescaleRecentJobs.count > 32 { airPrescaleRecentJobs.removeFirst(airPrescaleRecentJobs.count - 32) }
    }

    private func recordPrescaleFailure(_ message: String) {
        diagnosticLock.lock()
        diagnosticCounts["prescaleErrors", default: 0] += 1
        if airPrescaleFirstFailure == nil { airPrescaleFirstFailure = message }
        diagnosticLock.unlock()
    }
#endif

#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
    private func recordFusedTiming(calls: Int, milliseconds: Double) {
        diagnosticLock.lock()
        diagnosticCounts["fusedPreprocessCalls", default: 0] += calls
        if !airPrescaleRecentJobs.isEmpty {
            airPrescaleRecentJobs[airPrescaleRecentJobs.count - 1]["fusedPreprocessCalls"] = calls
            airPrescaleRecentJobs[airPrescaleRecentJobs.count - 1]["fusedPreprocessMs"] = milliseconds
        }
        diagnosticLock.unlock()
    }
#endif

    @objc(recordPrescaleOriginalWidth:height:)
    func recordPrescaleOriginal(width: Int32, height: Int32) {
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        guard rifePrescaleEnabled else { return }
        diagnosticLock.lock()
        airPrescaleActualOriginal = [Int(width), Int(height)]
        diagnosticCounts["prescaleOriginalObservations", default: 0] += 1
        if Int(width) != preparedCaptureWidth || Int(height) != preparedCaptureHeight {
            diagnosticCounts["prescaleDimensionMismatches", default: 0] += 1
        }
        diagnosticLock.unlock()
#endif
    }

    @objc(airBetaMeasurementReadiness)
    func airBetaMeasurementReadiness() -> [String: Any] {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock(); defer { state.unlock() }
        let keeper = preparedKeeper?.operationalReadiness() ?? ["available": false, "operational": false]
        return ["schema": "odf-air-beta-runtime-readiness-v1", "compiled": true,
                "hasInterpolator": interpolator != nil, "currentPreparedKeeper": preparedKeeper != nil,
                "loadedModelID": loadedModelID, "loadedQuality": loadedQuality,
                "preparedGPUInputOutput": preparedGPUInputOutput.map { $0 as Any } ?? NSNull(),
                "liveStreamEnabled": liveStreamEnabled, "bridgeEpoch": epoch,
                "preparedCapturePixels": [preparedCaptureWidth, preparedCaptureHeight],
                "preparedProcessingPixels": [preparedProcessingWidth, preparedProcessingHeight],
                "rifeDeviceRegistryID": keeperRifeDeviceRegistryID.map { $0 as Any } ?? NSNull(),
                "rifeModelIdentity": keeperRifeModelIdentity, "keeper": keeper,
                "firstFailure": keeperFirstFailure.map { $0 as Any } ?? NSNull()]
#else
        return ["schema": "odf-air-beta-runtime-readiness-v1", "compiled": false,
                "currentPreparedKeeper": false, "keeper": ["available": false, "operational": false]]
#endif
    }

    @objc func airBetaRuntimeState() -> [String: Any] {
        guard SPAirBetaEnabled() || airPerformanceEnabled else { return ["enabled": false] }
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        state.lock()
        let keeper = keeperInstances.last, failure = keeperFirstFailure
        let size = [preparedProcessingWidth, preparedProcessingHeight]
        state.unlock()
        if let failure { return ["enabled": true, "keeper": "failed", "reason": failure, "processingPixels": size] }
        guard let keeper else { return ["enabled": true, "keeper": "inactive", "reason": "保活未准备", "processingPixels": size] }
        let snapshot = keeper.snapshot(includeRecords: false)
        if let failure = snapshot["firstFailure"] as? String {
            return ["enabled": true, "keeper": "failed", "reason": failure, "processingPixels": size]
        }
        if snapshot["deviceClaimWaitTimedOut"] as? Bool == true ||
            snapshot["drainTimedOut"] as? Bool == true {
            return ["enabled": true, "keeper": "failed", "reason": "保活设备交接或停止失败", "processingPixels": size]
        }
        let stopped = snapshot["stopRequested"] as? Bool == true
        let ended = snapshot["workerEndedNs"] is NSNumber
        let claimed = snapshot["deviceClaimPassed"] as? Bool == true
        if ended && !stopped {
            return ["enabled": true, "keeper": "failed", "reason": "保活工作意外结束", "processingPixels": size]
        }
        let status = stopped ? (ended ? "inactive" : "stopping") : (claimed ? "active" : "preparing")
        return ["enabled": true, "keeper": status, "reason": "", "processingPixels": size,
                "diagnosticRecordsTruncated": snapshot["overflow"] as? Bool == true]
#else
        return ["enabled": true, "keeper": "failed", "reason": "此构建未包含保活功能", "processingPixels": [0, 0]]
#endif
    }

    private func pooledOutput(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPool == nil {
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
                throw Self.error(2, "RIFE 输出池创建失败")
            }
            outputPool = pool
        }
        count("poolRequests")
        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, outputPool!, aux, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold {
            count("poolFailures"); throw Self.error(10, "RIFE 输出池繁忙，等待已持有的画面释放。")
        }
        guard status == kCVReturnSuccess, let buffer, CVPixelBufferGetIOSurface(buffer) != nil else {
            count("poolFailures"); throw Self.error(2, "RIFE 输出池分配失败（\(status)）")
        }
        return buffer
    }

    @objc func resetLiveCacheForRateBudgetProbe() {
        // Enqueued before the first probe job on the same serial exec queue.
        exec.async {
#if ODF_AIR_SERVICE_TRACE
            self.airServiceEvent(.streamResetBegin, token: 0, detail: 4)
#endif
            self.stream?.reset()
            self.streamPrevious = nil
            self.streamKey = nil
            self.streamPreviousFormat = 0
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
            self.advancePrescaleCache(token: 0, reason: 4)
#endif
#if ODF_AIR_SERVICE_TRACE
            self.airServiceEvent(.streamResetEnd, token: 0, detail: 4)
#endif
        }
    }

    @objc func relieveCapturePressure() {
        state.lock()
        if pressureResetQueued { state.unlock(); return }
        pressureResetQueued = true
        state.unlock()
        // Serialized after previously submitted work; never releases an input
        // while the stream is still using it on the GPU.
        exec.async {
            if self.streamPrevious != nil {
#if ODF_AIR_SERVICE_TRACE
                self.airServiceEvent(.streamResetBegin, token: 0, detail: 5)
#endif
                self.stream?.reset(); self.streamPrevious = nil; self.streamKey = nil
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                self.advancePrescaleCache(token: 0, reason: 5)
#endif
                self.count("pressureResets")
#if ODF_AIR_SERVICE_TRACE
                self.airServiceEvent(.streamResetEnd, token: 0, detail: 5)
#endif
            }
            self.state.lock(); self.pressureResetQueued = false; self.state.unlock()
        }
    }

    @objc func injectStreamFailureForContract() {
        exec.sync { contractFailNext = true }
    }

    // One accumulated sample per live task, including both inputs on a miss.
    // Error fallback conversion is included; stateless interpolate is not push.
    private func recordStreamTiming(totalMs: Double, convertMs: Double?, pushMs: Double?, hit: Bool?) {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        if let convertMs {
            convertSamplesMs.append(convertMs)
            if convertSamplesMs.count > 256 { convertSamplesMs.removeFirst(convertSamplesMs.count - 256) }
        }
        if let pushMs {
            pushSamplesMs.append(pushMs)
            if pushSamplesMs.count > 256 { pushSamplesMs.removeFirst(pushSamplesMs.count - 256) }
        }
        recentJobs.append([
            "totalMs": totalMs,
            "convertMs": convertMs.map { $0 as Any } ?? NSNull(),
            "pushMs": pushMs.map { $0 as Any } ?? NSNull(),
            "hit": hit.map { $0 as Any } ?? NSNull()
        ])
        if recentJobs.count > 32 { recentJobs.removeFirst(recentJobs.count - 32) }
    }

    @objc func streamDiagnostics() -> [String: Any] {
        diagnosticLock.lock()
        let counts = diagnosticCounts, convert = convertSamplesMs, push = pushSamplesMs, jobs = recentJobs
        diagnosticLock.unlock()
        func summary(_ values: [Double]) -> (median: Double, p95: Double) {
            guard !values.isEmpty else { return (-1, -1) }
            let sorted = values.sorted(), count = values.count
            return ((sorted[(count - 1) / 2] + sorted[count / 2]) / 2, sorted[(count - 1) * 95 / 100])
        }
        let convertTiming = summary(convert), pushTiming = summary(push)
        let environment = ProcessInfo.processInfo.environment["CHUANFLOW_RIFE_STREAM"] == "1"
        state.lock(); let experiment = loadedExperiment; state.unlock()
        var result: [String: Any] = ["requested": liveStreamEnabled, "effective": liveStreamEnabled || environment,
                "enableSource": liveStreamEnabled ? "request" : (environment ? "environment" : "disabled"),
                "hits": counts["hits", default: 0], "misses": counts["misses", default: 0],
                "resets": counts["resets", default: 0], "pressureResets": counts["pressureResets", default: 0], "fallbackSucceeded": counts["fallbackSucceeded", default: 0],
                "fallbackFailed": counts["fallbackFailed", default: 0], "poolRequests": counts["poolRequests", default: 0],
                "poolFailures": counts["poolFailures", default: 0],
                "convertMedianMs": convertTiming.median, "convertP95Ms": convertTiming.p95,
                "pushMedianMs": pushTiming.median, "pushP95Ms": pushTiming.p95,
                "rifeRecentJobs": jobs]
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        diagnosticLock.lock()
        result["airRifePrescale"] = [
            "schema": "odf-air-rife-prescale-v1", "compiled": true, "enabled": rifePrescaleEnabled,
            "expectedCapturePixels": [preparedCaptureWidth, preparedCaptureHeight], "processPixels": [preparedProcessingWidth, preparedProcessingHeight],
            "originalPixels": [preparedCaptureWidth, preparedCaptureHeight],
            "syntheticPixels": fusedRifePresentEnabled ? [preparedProcessingWidth, preparedProcessingHeight] : [preparedCaptureWidth, preparedCaptureHeight],
            "actualSourcePixels": airPrescaleActualSource.map { $0 as Any } ?? NSNull(),
            "actualProcessPixels": airPrescaleActualProcess.map { $0 as Any } ?? NSNull(),
            "actualSyntheticPixels": airPrescaleActualSynthetic.map { $0 as Any } ?? NSNull(),
            "actualOriginalPixels": airPrescaleActualOriginal.map { $0 as Any } ?? NSNull(),
            "downscaleCalls": diagnosticCounts["prescaleDownscaleCalls", default: 0],
            "upscaleCalls": diagnosticCounts["prescaleUpscaleCalls", default: 0],
            "cacheHits": diagnosticCounts["prescaleCacheHits", default: 0],
            "cacheMisses": diagnosticCounts["prescaleCacheMisses", default: 0],
            "cacheResets": diagnosticCounts["prescaleCacheResets", default: 0],
            "jobs": diagnosticCounts["prescaleJobs", default: 0],
            "originalObservations": diagnosticCounts["prescaleOriginalObservations", default: 0],
            "dimensionMismatches": diagnosticCounts["prescaleDimensionMismatches", default: 0],
            "errors": diagnosticCounts["prescaleErrors", default: 0],
            "firstFailure": airPrescaleFirstFailure.map { $0 as Any } ?? NSNull(),
            "recentJobs": airPrescaleRecentJobs, "MIncludesDownAndUp": !fusedRifePresentEnabled,
            "cacheReuseScope": "The RifeStream retains the Lanczos-reduced B image/encoder cache for the next matching full-source identity, PTS, generation, configVersion, clockEpoch and bridge epoch. Each explicit reset starts a new recorded cacheEpoch.",
            "timingScope": "Existing exec-start to returned model service time includes format conversion, completed Lanczos downscales, RIFE push and completed full-size Lanczos upscales. Scalar service events provide complete job detail; recentJobs is only the latest 32.",
            "originalScope": "Actual original-frame enqueue buffer sizes after the existing source format conversion. Original buffers bypass the RIFE prescale path. These are buffer observations, not physical screen pixels."]
        diagnosticLock.unlock()
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        diagnosticLock.lock()
        result["airFusedRifePresent"] = [
            "schema": "odf-air-fused-rife-present-v1", "compiled": true, "enabled": fusedRifePresentEnabled,
            "sourcePixels": [preparedCaptureWidth, preparedCaptureHeight], "processPixels": [preparedProcessingWidth, preparedProcessingHeight],
            "syntheticEnqueuePixels": [preparedProcessingWidth, preparedProcessingHeight],
            "originalEnqueuePixels": [preparedCaptureWidth, preparedCaptureHeight],
            "expectedDrawablePixels": [preparedCaptureWidth, preparedCaptureHeight],
            "actualSourcePixels": airPrescaleActualSource.map { $0 as Any } ?? NSNull(),
            "actualProcessPixels": airPrescaleActualProcess.map { $0 as Any } ?? NSNull(),
            "actualSyntheticEnqueuePixels": airPrescaleActualSynthetic.map { $0 as Any } ?? NSNull(),
            "actualOriginalEnqueuePixels": airPrescaleActualOriginal.map { $0 as Any } ?? NSNull(),
            "preprocessCalls": diagnosticCounts["fusedPreprocessCalls", default: 0],
            "errors": diagnosticCounts["prescaleErrors", default: 0],
            "firstFailure": airPrescaleFirstFailure.map { $0 as Any } ?? NSNull(),
            "dimensionMismatches": diagnosticCounts["prescaleDimensionMismatches", default: 0],
            "fullSizeVTTransfers": diagnosticCounts["fusedFullSizeVTTransfers", default: 0],
            "fullSizeVTTransfersScope": "RIFE input bridge only. Full-size original presentation keeps its existing independent format-conversion path.",
            "standaloneDownscaleCalls": diagnosticCounts["prescaleDownscaleCalls", default: 0],
            "standaloneUpscaleCalls": diagnosticCounts["prescaleUpscaleCalls", default: 0],
            "kernel": "spAirNV12Lanczos", "syntheticFragment": "spAirPresentLanczos",
            "colorContract": "BT.709 video-range 8-bit NV12; exact source attachments are validated by the preprocessor",
            "upscaleLocation": "presenter-render-pass", "MIncludesPreprocess": true,
            "MIncludesPresenterUpscale": false, "recentJobs": airPrescaleRecentJobs]
        diagnosticLock.unlock()
#endif
        return result.merging(experiment) { _, current in current }
    }

    @objc func invalidate() {
#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
        requestStopKeeper(planToken: 0, reason: "bridge_invalidate")
#endif
        state.lock()
        epoch &+= 1
        let invalidatedEpoch = epoch
        let engine = interpolator
        interpolator = nil
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
        airPrescaleDown = nil
        airPrescaleUp = nil
#endif
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        airFusedPreprocessor = nil
#endif
        state.unlock()
        exec.async {
            if self.streamEpoch < invalidatedEpoch {
#if ODF_AIR_SERVICE_TRACE
                self.airServiceEvent(.streamResetBegin, token: 0, detail: 6)
#endif
                self.stream?.reset(); self.stream = nil; self.streamPrevious = nil; self.streamKey = nil; self.outputPool = nil
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                self.advancePrescaleCache(token: 0, reason: 6)
#endif
#if ODF_AIR_SERVICE_TRACE
                self.airServiceEvent(.streamResetEnd, token: 0, detail: 6)
#endif
            }
            _ = engine
        }
    }

    @objc class func probe() -> [String: Any] {
        let bundled = RifeConfiguration.bundledModelURL
        let bundledOutsideExperiment = !bundled.path.contains("interpolation-experiment") && FileManager.default.fileExists(atPath: bundled.path)
        var report: [String: Any] = [
            "package": "cinemore/rife-metal",
            "version": packageVersion,
            "commit": packageCommit,
            "bundledModel": bundled.path,
            "bundledModelSHA256": sha256(of: bundled),
            "bundledOutsideExperiment": bundledOutsideExperiment,
            "sdrOnly": true,
            "pixelFormats": ["BGRA8", "RGBA8"],
        ]
        let fast = Self.runPixels(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 24)
        report["fast"] = fast
        report["fastNV12"] = Self.runNV12(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 24)
        report["fastPressure"] = Self.runPixels(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 80)
        report["balanced"] = Self.runPixels(modelID: "rife-v4.25", quality: "balanced", width: 640, height: 360, motion: 24)
        report["balancedPressure"] = Self.runPixels(modelID: "rife-v4.25", quality: "balanced", width: 640, height: 360, motion: 160)
        report["hq"] = Self.runPixels(modelID: "rife-v4.25", quality: "hq", width: 320, height: 192, motion: 24)
        report["model426"] = Self.runPixels(modelID: "rife-v4.26", quality: "balanced", width: 320, height: 192, motion: 24)
        if let url = try? url(for: "rife-v4.26") {
            report["model426Path"] = url.path
            report["model426SHA256"] = sha256(of: url)
            report["model426OutsideExperiment"] = !url.path.contains("interpolation-experiment")
        }
        let seamOK = (report["fastNV12"] as? [String: Any])?["ok"] as? Bool == true
        let fastOK = (fast["ok"] as? Bool) == true
        report["ok"] = bundledOutsideExperiment && fastOK && seamOK
        let digest = report["model426SHA256"] as? String
        report["model426DeclaredAvailable"] = digest == model426SHA256 && (report["model426"] as? [String: Any])?["ok"] as? Bool == true
        return report
    }

    private static func runPixels(modelID: String, quality: String, width: Int, height: Int, motion: Int) -> [String: Any] {
        let bridge = SPRifeBridge()
        do {
            try bridge.prepare(modelID: modelID, quality: quality, width: Int32(width), height: Int32(height))
        } catch {
            return ["ok": false, "modelID": modelID, "quality": quality, "error": error.localizedDescription]
        }
        guard let previous = try? buffer(width: width, height: height, value: 0),
              let current = try? buffer(width: width, height: height, value: 0) else {
            return ["ok": false, "modelID": modelID, "error": "buffer"]
        }
        let centerA = width / 2 - motion / 2
        let centerB = width / 2 + motion / 2
        paint(previous, center: centerA)
        paint(current, center: centerB)
        let phases: [Float] = [0.25, 0.5, 0.75, 1.0 / 3.0, 2.0 / 3.0]
        let done = DispatchSemaphore(value: 0)
        var frames: [SPOwnedPixelBuffer]?
        var callError: Error?
        let submitted = bridge.submit(previous: previous, current: current, timesteps: phases.map { NSNumber(value: $0) }, token: 1) { _, outputs, _, error in
            frames = outputs
            callError = error
            done.signal()
        }
        guard submitted else { return ["ok": false, "modelID": modelID, "error": "submit"] }
        done.wait()
        bridge.invalidate()
        var centers: [Double] = []
        var positions = frames?.count == phases.count && callError == nil
        for (index, box) in (frames ?? []).enumerated() {
            let center = centerOfMass(box.buffer)
            centers.append(center)
            let phase = Double(phases[index])
            let expected = Double(centerA) * (1 - phase) + Double(centerB) * phase
            let outW = CVPixelBufferGetWidth(box.buffer)
            let outH = CVPixelBufferGetHeight(box.buffer)
            if outW != width || outH != height || abs(center - expected) > 12 { positions = false }
        }
        return [
            "ok": positions,
            "modelID": modelID,
            "quality": quality,
            "error": callError?.localizedDescription ?? "",
            "centers": centers,
            "outputCount": frames?.count ?? 0,
            "motionPx": motion,
            "inputFormat": "BGRA",
        ]
    }

    private static func runNV12(modelID: String, quality: String, width: Int, height: Int, motion: Int) -> [String: Any] {
        let bridge = SPRifeBridge()
        do {
            try bridge.prepare(modelID: modelID, quality: quality, width: Int32(width), height: Int32(height))
        } catch {
            return ["ok": false, "modelID": modelID, "quality": quality, "inputFormat": "NV12", "error": error.localizedDescription]
        }
        guard let previous = try? nv12(width: width, height: height, luma: 16),
              let current = try? nv12(width: width, height: height, luma: 16) else {
            return ["ok": false, "error": "nv12", "inputFormat": "NV12"]
        }
        let centerA = width / 2 - motion / 2
        let centerB = width / 2 + motion / 2
        paintLuma(previous, center: centerA)
        paintLuma(current, center: centerB)
        let done = DispatchSemaphore(value: 0)
        var frames: [SPOwnedPixelBuffer]?
        var callError: Error?
        let submitted = bridge.submit(previous: previous, current: current, timesteps: [NSNumber(value: 0.5)], token: 2) { _, outputs, _, error in
            frames = outputs
            callError = error
            done.signal()
        }
        guard submitted else { return ["ok": false, "inputFormat": "NV12", "error": "submit"] }
        done.wait()
        bridge.invalidate()
        let center = frames?.first.map { centerOfMass($0.buffer) } ?? -1
        let expected = Double(centerA + centerB) / 2
        let box = frames?.first
        let sizeOK = box != nil && CVPixelBufferGetWidth(box!.buffer) == width && CVPixelBufferGetHeight(box!.buffer) == height
        return [
            "ok": callError == nil && sizeOK && center > 0 && abs(center - expected) <= 16,
            "modelID": modelID,
            "quality": quality,
            "inputFormat": "NV12",
            "center": center,
            "expected": expected,
            "outputCount": frames?.count ?? 0,
            "error": callError?.localizedDescription ?? "",
        ]
    }

    private static func paintLuma(_ buffer: CVPixelBuffer, center: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let size = 48
        let x0 = center - size / 2
        let y0 = height / 2 - size / 2
        for y in 0..<size {
            let py = y0 + y
            if py < 0 || py >= height { continue }
            let row = plane.advanced(by: py * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let px = x0 + x
                if px < 0 || px >= width { continue }
                row[px] = ((x / 4) ^ (y / 4)) & 1 == 1 ? 235 : 40
            }
        }
    }

    private static func tier(_ quality: String) -> RifeQualityTier {
        switch quality {
        case "fast": return .fast
        case "hq": return .hq
        default: return .balanced
        }
    }

    private static func url(for modelID: String, bundle: Bundle = .main) throws -> URL {
        if modelID == "rife-v4.26" {
            guard let bundled = bundle.url(forResource: "rife-v4.26", withExtension: "rmw")
                    ?? bundle.url(forResource: "rife-v4.26", withExtension: "rmw", subdirectory: "Models") else {
                throw error(3, "应用里没有 rife-v4.26.rmw。4.26 是另一套权重，不能把 4.25 换名使用。")
            }
            let digest = sha256(of: bundled)
            guard digest == model426SHA256 else {
                throw error(3, "rife-v4.26.rmw 校验不符，拒绝加载。")
            }
            return bundled
        }
        guard modelID == "rife-v4.25" else { throw error(3, "所选 RIFE 模型不可用。") }
        let modelBundle = bundle.url(forResource: "RifeMetal_RifeMetal", withExtension: "bundle").flatMap(Bundle.init(url:))
        let bundled = modelBundle?.url(forResource: "rife-v4.25", withExtension: "rmw") ?? RifeConfiguration.bundledModelURL
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw error(4, "应用里没有 rife-v4.25.rmw")
        }
        if bundled.path.contains("interpolation-experiment") {
            throw error(5, "RIFE 4.25 仍从实验目录加载")
        }
        return bundled
    }

    private func ownedBGRA(_ source: CVPixelBuffer, diagnosticToken: UInt64 = 0,
                           diagnosticRole: UInt64 = 0) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32RGBA {
            return source
        }
        if transfer == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                  let session else {
                throw Self.error(8, "无法建立画面格式转换。")
            }
            transfer = session
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
#if ODF_AIR_FUSED_RIFE_PRESENT_DIAGNOSTIC
        if fusedRifePresentEnabled && diagnosticToken != 0 { count("fusedFullSizeVTTransfers") }
#endif
        guard width >= 2, height >= 2 else { throw Self.error(6, "画面尺寸太小，不能交给 RIFE。") }
        let bgra = try Self.buffer(width: width, height: height, value: 0)
#if ODF_AIR_SERVICE_TRACE
        airServiceEvent(.vtTransferCall, token: diagnosticToken, detail: diagnosticRole, sourceFourCC: format)
#endif
        let status = VTPixelTransferSessionTransferImage(transfer!, from: source, to: bgra)
        guard status == noErr else {
            throw Self.error(1, "当前画面是 \(Self.formatName(format))。RIFE 只接受 8 位 BGRA 或 RGBA，转换失败（\(status)）。HDR 不能用这套模型。")
        }
        CVBufferPropagateAttachments(source, bgra)
        Self.attach709IfMissing(bgra)
        return bgra
    }

    private static func explain(_ error: Error) -> Error {
        if let rife = error as? RifeError {
            switch rife {
            case .unsupportedPixelFormat(let format):
                return self.error(1, "RIFE 拒绝了格式 \(formatName(format))。需要先把捕获画面转成 8 位 BGRA。HDR 不能用这套模型。")
            case .dimensionMismatch:
                return self.error(2, "RIFE 的两帧尺寸不一致。")
            case .modelLoadFailed(let detail):
                return self.error(3, "RIFE 模型没有加载：\(detail)")
            case .invalidTimesteps(let detail):
                return self.error(7, "RIFE 不接受这个相位：\(detail)")
            case .inferenceFailed(let detail):
                return self.error(9, "RIFE 推理失败：\(detail)")
            case .metalUnavailable:
                return self.error(8, "这台 Mac 没有可用的 Metal，RIFE 不能运行。")
            case .shaderCompilationFailed(let detail):
                return self.error(9, "RIFE 着色器编译失败：\(detail)")
            }
        }
        return error
    }

    private static func formatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "NV12"
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32RGBA: return "RGBA"
        default: return String(format: "0x%08x", format)
        }
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nv12(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw error(6, "无法分配 NV12 预热画面") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(plane, Int32(luma), row * rows)
        }
        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(plane, 128, row * rows)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private static func buffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw error(6, "无法分配 RIFE 画面") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                memset(base.advanced(by: y * stride), Int32(value), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        attach709(buffer)
        return buffer
    }

    private static func paint(_ buffer: CVPixelBuffer, center: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let size = 72
        let x0 = center - size / 2
        let y0 = height / 2 - size / 2
        for y in 0..<size {
            let py = y0 + y
            if py < 0 || py >= height { continue }
            let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let px = x0 + x
                if px < 0 || px >= width { continue }
                let on = ((x / 6) ^ (y / 6)) & 1 == 1
                let value: UInt8 = on ? 255 : 20
                row[px * 4] = value
                row[px * 4 + 1] = value
                row[px * 4 + 2] = value
                row[px * 4 + 3] = 255
            }
        }
    }

    private static func centerOfMass(_ buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0
        var weight = 0.0
        let y0 = height * 30 / 100
        let y1 = height * 70 / 100
        for y in Swift.stride(from: y0, to: y1, by: 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 2) where row[x * 4 + 1] > 12 {
                let luma = Double(row[x * 4 + 1])
                sum += Double(x) * luma
                weight += luma
            }
        }
        return weight > 0 ? sum / weight : -1
    }

    private static func attach709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func attach709IfMissing(_ buffer: CVPixelBuffer) {
        let defaults: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in defaults where CVBufferGetAttachment(buffer, key, nil) == nil {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    private static func error(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "app.openduckframe.rife", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

#if ODF_AIR_SERVICE_TRACE
private enum SPAirServiceEventKind: UInt32 {
    case enqueueCallBegin = 1, execBegin, ownedBGRABegin, ownedBGRAEnd
    case streamCreateBegin, streamCreateEnd, streamResetBegin, streamResetEnd, cacheDecision
    case pushBegin, pushEnd, outputPoolBegin, outputPoolEnd, wrapBegin, wrapEnd
    case fallbackBegin, fallbackEnd, latencyFinishBegin, latencyFinishEnd
    case completionWillDeliver, completionWillFail, retiredBeforeExecution, unsupportedStatelessSubmit
    case vtTransferCall
    case prescaleSourceDimensions, prescaleProcessDimensions, prescaleSyntheticDimensions
    case prescaleDownBegin, prescaleDownEnd, prescaleUpBegin, prescaleUpEnd, prescaleCacheEpoch
    case fusedPreprocessBegin, fusedPreprocessEnd
    var label: String {
        switch self {
        case .enqueueCallBegin: return "enqueue-call-begin"
        case .execBegin: return "exec-begin"
        case .ownedBGRABegin: return "ownedBGRA-begin"
        case .ownedBGRAEnd: return "ownedBGRA-end"
        case .streamCreateBegin: return "stream-create-begin"
        case .streamCreateEnd: return "stream-create-end"
        case .streamResetBegin: return "stream-reset-begin"
        case .streamResetEnd: return "stream-reset-end"
        case .cacheDecision: return "cache-decision"
        case .pushBegin: return "push-begin"
        case .pushEnd: return "push-end"
        case .outputPoolBegin: return "output-pool-begin"
        case .outputPoolEnd: return "output-pool-end"
        case .wrapBegin: return "wrap-begin"
        case .wrapEnd: return "wrap-end"
        case .fallbackBegin: return "fallback-begin"
        case .fallbackEnd: return "fallback-end"
        case .latencyFinishBegin: return "latency-finish-begin"
        case .latencyFinishEnd: return "latency-finish-end"
        case .completionWillDeliver: return "completion-will-deliver"
        case .completionWillFail: return "completion-will-fail"
        case .retiredBeforeExecution: return "retired-before-execution"
        case .unsupportedStatelessSubmit: return "unsupported-stateless-submit"
        case .vtTransferCall: return "vt-transfer-call"
        case .prescaleSourceDimensions: return "prescale-source-dimensions"
        case .prescaleProcessDimensions: return "prescale-process-dimensions"
        case .prescaleSyntheticDimensions: return "prescale-synthetic-dimensions"
        case .prescaleDownBegin: return "prescale-down-begin"
        case .prescaleDownEnd: return "prescale-down-end"
        case .prescaleUpBegin: return "prescale-up-begin"
        case .prescaleUpEnd: return "prescale-up-end"
        case .prescaleCacheEpoch: return "prescale-cache-epoch"
        case .fusedPreprocessBegin: return "fused-preprocess-begin"
        case .fusedPreprocessEnd: return "fused-preprocess-end"
        }
    }
}

private struct SPAirServiceMetadata {
    var token: UInt64 = 0, configVersion: UInt64 = 0, measurementEpoch: UInt64 = 0
    var probe = false
    var probeIndex: Int64 = -1
    var probeRound: UInt64 = 0
}
private struct SPAirServiceJob {
    var sequence: UInt64 = 0, jobID: UInt64 = 0, admissionHostTicks: UInt64 = 0
    var metadata = SPAirServiceMetadata(), metadataMatched = false
    var previousID: UInt64 = 0, currentID: UInt64 = 0, generation: UInt64 = 0, clockEpoch: UInt64 = 0, bridgeEpoch: UInt64 = 0
    var previousPTSValue: Int64 = 0, currentPTSValue: Int64 = 0
    var previousPTSTimescale: Int32 = 0, currentPTSTimescale: Int32 = 0
    var previousPTSEpoch: Int64 = 0, currentPTSEpoch: Int64 = 0
}
private struct SPAirServiceEvent {
    var sequence: UInt64 = 0, jobID: UInt64 = 0, hostTicks: UInt64 = 0, detail: UInt64 = 0
    var cacheEpoch: UInt64 = 0
    var kind = SPAirServiceEventKind.enqueueCallBegin
    var value: Double = 0
    var sourceFourCC: UInt32 = 0
}
private struct SPAirServiceGPU {
    var sequence: UInt64 = 0, sampleHostTicks: UInt64 = 0
    var record = AirServiceTraceRecord()
}

// Storage only: caller holds the existing bridge state lock. All elements are
// scalar structs; no dictionaries, growing arrays, callbacks or I/O on writers.
private final class SPAirServiceRing<T> {
    let capacity: Int
    let storage: UnsafeMutablePointer<T>
    private(set) var total: UInt64 = 0
    var sealed = false
    var postSealAttempts: UInt64 = 0
    init(capacity: Int, initial: T) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: initial, count: capacity)
    }
    deinit { storage.deinitialize(count: capacity); storage.deallocate() }
    func append(_ value: T) {
        if sealed { postSealAttempts &+= 1; return }
        storage[Int(total % UInt64(capacity))] = value
        total &+= 1
    }
    func copy() -> [T] {
        let count = Int(min(total, UInt64(capacity)))
        var result: [T] = []; result.reserveCapacity(count)
        let first = total - UInt64(count)
        for index in 0..<count { result.append(storage[Int((first + UInt64(index)) % UInt64(capacity))]) }
        return result
    }
}

// Sixteen-byte gate evidence. The sequence is its actual producer append
// position. Raw command-buffer fields are separate bounded diagnostic detail.
private struct SPAirGPUGateEntry {
    var sampleHostTicks: UInt64 = 0
    var flags: UInt8 = 0
}
private func spAirGPUGateFlags(_ r: AirServiceTraceRecord) -> UInt8 {
    var flags: UInt8 = 0
    if (r.validityMask & 16) == 0 || !r.gpuStartSeconds.isFinite || r.gpuStartSeconds <= 0 || !r.gpuEndSeconds.isFinite || r.gpuEndSeconds <= 0 { flags |= 1 }
    if (r.coverageFlags & 6) != 0 { flags |= 2 }
    if (r.validityMask & 32) == 0 || !r.kernelStartSeconds.isFinite || r.kernelStartSeconds <= 0 || !r.kernelEndSeconds.isFinite || r.kernelEndSeconds <= 0 { flags |= 4 }
    return flags
}
private func spAirGPUGateRow(sequence: UInt64, entry: SPAirGPUGateEntry) -> [String: Any] {
    ["sequence": sequence, "sampleHostTicks": entry.sampleHostTicks, "flags": entry.flags]
}
private final class SPAirGPUDetails {
    let prefixCapacity = 65_536
    var prefix: [SPAirServiceGPU] = []
    let suffix = SPAirServiceRing(capacity: 65_536, initial: SPAirServiceGPU())
    var total: UInt64 = 0
    init() { prefix.reserveCapacity(prefixCapacity) }
    func append(_ row: SPAirServiceGPU) {
        if prefix.count < prefixCapacity { prefix.append(row) }
        suffix.append(row)
        total &+= 1
    }
    func retainedRows() -> [SPAirServiceGPU] {
        let lastPrefix = prefix.last?.sequence ?? 0
        return prefix + suffix.copy().filter { $0.sequence > lastPrefix }
    }
    func metadata() -> [String: Any] {
        let suffixCount = min(total, UInt64(suffix.capacity))
        let prefixCount = UInt64(prefix.count)
        let retained = min(total, prefixCount + suffixCount)
        return ["coverageScope": "b_diagnostic_detail", "prefixCapacity": prefixCapacity,
                "suffixCapacity": suffix.capacity, "total": total,
                "retainedDistinctCount": retained, "omittedCount": total - retained,
                "boundedDetails": true, "recordingSchema": "odf-service-gpu-body-bounded-v1"]
    }
}

private final class SPAirServiceTraceStore {
    let storeID = UUID().uuidString
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
    let jobs = SPAirServiceRing(capacity: 65536, initial: SPAirServiceJob())
    let events = SPAirServiceRing(capacity: 4194304, initial: SPAirServiceEvent())
    let gpu = SPAirServiceRing(capacity: 16_777_216, initial: SPAirGPUGateEntry())
#else
    let jobs = SPAirServiceRing(capacity: 4096, initial: SPAirServiceJob())
    let events = SPAirServiceRing(capacity: 65536, initial: SPAirServiceEvent())
    let gpu = SPAirServiceRing(capacity: 32_768, initial: SPAirGPUGateEntry())
#endif
    let gpuDetails = SPAirGPUDetails()
    var sealed = false
    var sealedHostTicks: UInt64 = 0
    var postSealRuntimeOverflow: UInt64 = 0
    var nextMetadata = SPAirServiceMetadata()
    var runtimeOverflow: UInt64 = 0, metadataMismatches: UInt64 = 0, exportCount: UInt64 = 0
    var modelIdentity: [String: Any] = [:] // Prepared once, never built on a job path.
    func admit(token: UInt64, previousID: UInt64, currentID: UInt64,
               previousPTS: CMTime, currentPTS: CMTime, generation: UInt64, clockEpoch: UInt64, bridgeEpoch: UInt64) {
        if sealed { jobs.postSealAttempts &+= 1; return }
        var job = SPAirServiceJob()
        job.sequence = jobs.total + 1; job.jobID = token; job.admissionHostTicks = mach_absolute_time()
        job.metadataMatched = nextMetadata.token == token
        if job.metadataMatched { job.metadata = nextMetadata } else { metadataMismatches &+= 1 }
        nextMetadata = SPAirServiceMetadata()
        job.previousID = previousID; job.currentID = currentID; job.generation = generation
        job.clockEpoch = clockEpoch; job.bridgeEpoch = bridgeEpoch
        job.previousPTSValue = previousPTS.value; job.previousPTSTimescale = previousPTS.timescale; job.previousPTSEpoch = previousPTS.epoch
        job.currentPTSValue = currentPTS.value; job.currentPTSTimescale = currentPTS.timescale; job.currentPTSEpoch = currentPTS.epoch
        jobs.append(job)
    }
    func appendEvent(kind: SPAirServiceEventKind, token: UInt64, host: UInt64, detail: UInt64,
                     value: Double, sourceFourCC: UInt32, cacheEpoch: UInt64) {
        events.append(SPAirServiceEvent(sequence: events.total + 1, jobID: token, hostTicks: host,
            detail: detail, cacheEpoch: cacheEpoch, kind: kind, value: value, sourceFourCC: sourceFourCC))
    }
    func appendGPU(_ record: AirServiceTraceRecord) {
        if sealed { gpu.postSealAttempts &+= 1; return }
        let sequence = gpu.total + 1
        let sampled = mach_absolute_time()
        gpu.append(SPAirGPUGateEntry(sampleHostTicks: sampled, flags: spAirGPUGateFlags(record)))
        gpuDetails.append(SPAirServiceGPU(sequence: sequence, sampleHostTicks: sampled, record: record))
    }

}

private func spAirRetainedServicePODBytes(_ trace: SPAirServiceTraceStore) -> UInt64 {
    let body = trace.gpuDetails
    let bodyCount = min(body.total, UInt64(body.prefix.count) + min(body.total, UInt64(body.suffix.capacity)))
    return min(trace.jobs.total, UInt64(trace.jobs.capacity)) * UInt64(MemoryLayout<SPAirServiceJob>.stride)
        + min(trace.events.total, UInt64(trace.events.capacity)) * UInt64(MemoryLayout<SPAirServiceEvent>.stride)
        + min(trace.gpu.total, UInt64(trace.gpu.capacity)) * UInt64(MemoryLayout<SPAirGPUGateEntry>.stride)
        + bodyCount * UInt64(MemoryLayout<SPAirServiceGPU>.stride)
}

private func spAirServiceJobRow(_ j: SPAirServiceJob) -> [String: Any] {
        return ["sequence": j.sequence, "jobID": j.jobID, "admissionHostTicks": j.admissionHostTicks,
             "metadataMatched": j.metadataMatched, "kind": j.metadataMatched ? (j.metadata.probe ? "probe" : "ordinary") : "unknown",
             "configVersion": j.metadataMatched ? j.metadata.configVersion as Any : NSNull(),
             "measurementEpoch": j.metadataMatched ? j.metadata.measurementEpoch as Any : NSNull(),
             "probeIndex": j.metadataMatched && j.metadata.probe ? j.metadata.probeIndex as Any : NSNull(),
             "probeRound": j.metadataMatched && j.metadata.probe ? j.metadata.probeRound as Any : NSNull(),
             "previousID": j.previousID, "currentID": j.currentID, "generation": j.generation, "clockEpoch": j.clockEpoch, "bridgeEpoch": j.bridgeEpoch,
             "previousPTS": ["value": j.previousPTSValue, "timescale": Int64(j.previousPTSTimescale), "epoch": j.previousPTSEpoch],
             "currentPTS": ["value": j.currentPTSValue, "timescale": Int64(j.currentPTSTimescale), "epoch": j.currentPTSEpoch]]

}

private func spAirServiceEventRow(_ e: SPAirServiceEvent) -> [String: Any] {
        return ["sequence": e.sequence, "jobID": e.jobID == 0 ? NSNull() : e.jobID as Any,
             "hostTicks": e.hostTicks, "kind": e.kind.label, "detail": e.detail,
             "cacheEpoch": e.cacheEpoch == 0 ? NSNull() : e.cacheEpoch as Any,
             "latencySeconds": e.kind == .latencyFinishEnd ? e.value as Any : NSNull(),
             "cacheHit": e.kind == .cacheDecision ? (e.value == 1) as Any : NSNull(),
             "role": [.vtTransferCall, .prescaleDownBegin, .prescaleDownEnd, .fusedPreprocessBegin, .fusedPreprocessEnd].contains(e.kind) ? e.detail as Any : NSNull(),
             "width": [.prescaleSourceDimensions, .prescaleProcessDimensions, .prescaleSyntheticDimensions].contains(e.kind) ? e.detail as Any : NSNull(),
             "height": [.prescaleSourceDimensions, .prescaleProcessDimensions, .prescaleSyntheticDimensions].contains(e.kind) ? e.value as Any : NSNull(),
             "sourceFourCC": [.vtTransferCall, .fusedPreprocessBegin].contains(e.kind) ? e.sourceFourCC as Any : NSNull(),
             "colorMask": e.kind == .fusedPreprocessBegin ? e.value as Any : NSNull(),
             "errorCode": e.kind == .completionWillFail ? Int64(bitPattern: e.detail) as Any : NSNull()]

}

private func spAirServiceGPURow(_ row: SPAirServiceGPU) -> [String: Any] {
            let r = row.record
            func ticks(_ value: UInt64, _ bit: UInt32) -> Any { (r.validityMask & bit) != 0 ? value as Any : NSNull() }
            func seconds(_ value: Double, _ bit: UInt32) -> Any { (r.validityMask & bit) != 0 && value.isFinite && value > 0 ? value as Any : NSNull() }
            return ["sequence": row.sequence, "sampleHostTicks": row.sampleHostTicks, "jobID": r.jobID, "stage": r.stage, "rootIndex": r.rootIndex,
                "createHostTicks": ticks(r.createHostTicks, 1), "commitBeginHostTicks": ticks(r.commitBeginHostTicks, 2), "commitEndHostTicks": ticks(r.commitEndHostTicks, 2),
                "waitBeginHostTicks": ticks(r.waitBeginHostTicks, 4), "waitEndHostTicks": ticks(r.waitEndHostTicks, 4),
                "commitKind": r.commitKind, "status": (r.validityMask & 8) != 0 ? r.status as Any : NSNull(),
                "validityMask": r.validityMask, "coverageFlags": r.coverageFlags,
                "gpuStartSeconds": seconds(r.gpuStartSeconds, 16), "gpuEndSeconds": seconds(r.gpuEndSeconds, 16),
                "kernelStartSeconds": seconds(r.kernelStartSeconds, 32), "kernelEndSeconds": seconds(r.kernelEndSeconds, 32)]

}

private struct SPAirServiceSnapshot {
    let sampleHostTicks: UInt64
    let jobs: [SPAirServiceJob], events: [SPAirServiceEvent], gpu: [SPAirServiceGPU]
    let jobTotal: UInt64, eventTotal: UInt64, gpuTotal: UInt64, runtimeOverflow: UInt64, metadataMismatches: UInt64, exportOrdinal: UInt64
    let modelIdentity: [String: Any]
    let jobCapacity: UInt64, eventCapacity: UInt64, gpuCapacity: UInt64
    func export(cutoffHostTicks: UInt64, bridgeEpoch: UInt64) -> [String: Any] {
        func ring(_ capacity: UInt64, _ total: UInt64, _ rows: [[String: Any]]) -> [String: Any] {
            return ["capacity": capacity, "total": total, "dropped": total > capacity ? total - capacity : 0,
                "firstseq": rows.first?["sequence"] ?? NSNull(), "lastseq": rows.last?["sequence"] ?? NSNull(),
                "exportedCount": rows.count, "records": rows]
        }
        let jobRows: [[String: Any]] = jobs.filter { $0.admissionHostTicks <= cutoffHostTicks }.map(spAirServiceJobRow)
        let eventRows: [[String: Any]] = events.filter { $0.hostTicks <= cutoffHostTicks }.map(spAirServiceEventRow)
        let gpuRows: [[String: Any]] = gpu.filter { $0.sampleHostTicks <= cutoffHostTicks }.map(spAirServiceGPURow)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let overflow = (jobTotal > jobCapacity ? jobTotal - jobCapacity : 0) +
            (eventTotal > eventCapacity ? eventTotal - eventCapacity : 0) +
            (gpuTotal > gpuCapacity ? gpuTotal - gpuCapacity : 0) + runtimeOverflow
        let invalidGPU = gpuRows.filter { ($0["gpuStartSeconds"] is NSNull) || ($0["gpuEndSeconds"] is NSNull) }.count
        let invalidKernel = gpuRows.filter { ($0["kernelStartSeconds"] is NSNull) || ($0["kernelEndSeconds"] is NSNull) }.count
        let incompleteGPU = gpuRows.filter { (($0["coverageFlags"] as? UInt32 ?? 0) & 6) != 0 }.count
        let stateless = eventRows.filter { ($0["kind"] as? String) == "unsupported-stateless-submit" }.count
        return ["enabled": true, "compiled": true, "schema": "odf.air-service-trace.v1", "exportOrdinal": exportOrdinal,
            "exportCutoffHostTicks": cutoffHostTicks, "sampleHostTicks": sampleHostTicks, "bridgeEpochAtSnapshot": bridgeEpoch,
            "modelIdentity": modelIdentity, "overflowCount": overflow, "runtimeOverflowCount": runtimeOverflow,
            "metadataMismatches": metadataMismatches, "invalidGPUTimingRows": invalidGPU, "invalidKernelTimingRows": invalidKernel, "incompleteGPUCoverageRows": incompleteGPU,
            "unsupportedStatelessSubmits": stateless, "ringsComplete": overflow == 0,
            "machTimebase": ["numer": timebase.numer, "denom": timebase.denom],
            "jobs": ring(jobCapacity, jobTotal, jobRows), "events": ring(eventCapacity, eventTotal, eventRows), "gpu": ring(gpuCapacity, gpuTotal, gpuRows),
            "stageLabels": ["1": "stream-create", "2": "cache-prime", "3": "main-push", "4": "stateless-fallback"],
            "ownedBGRARoles": ["1": "previous", "2": "current", "3": "fallback-previous", "4": "fallback-current"],
            "resetReasons": ["1": "cache-miss", "2": "retired-after-push", "3": "stream-catch", "4": "rate-budget-probe", "5": "capture-pressure", "6": "invalidate"],
            "prescaleEvents": ["dimensions": "width and height are actual buffer observations",
                "downRoles": ["1": "previousID", "2": "currentID"],
                "upDetail": "zero-based synthetic phase index",
                "cacheEpoch": "exec-queue epoch incremented by every explicit stream reset or creation; reason7 is stream-create, other reasons share resetReasons",
                "timing": "Completed synchronous Lanczos calls are bracketed on exec inside its existing returned M service interval. No scalar event is GPU active time."],
            "fusedPreprocessEvents": ["roles": ["1": "previousID", "2": "currentID"],
                "colorMask": ["1": "NV12 video-range 420v", "2": "observed BT709 matrix", "4": "observed BT709 primaries", "8": "observed BT709 transfer"],
                "timing": "One completed NV12-to-reduced-BGRA kernel inside returned M. Source attachments are observed, not filled from defaults. Presenter filtering is outside M and has its own raw render records."],
            "cacheDecisionMask": ["1": "source-formats-equal", "2": "cached-format-equal", "4": "retained-previous-object-equal", "8": "continuity-key-equal"],
            "sourceStoppedScope": "Controlled SelfProbe export after SCK stop and before processor.stop; copies existing-state-lock POD storage without exec.sync, GPU wait or flush. Only the current bridge instance is covered. In-flight jobs/root timing updates after cutoff remain unknown; counters are at sampleHostTicks, records are cutoff-filtered.",
            "scope": "Trace-only; original jobID is the unconditional processor diagnosticID shared by ordinary and probe jobs. No ring reset on config/epoch. HostTicks are mach_absolute_time; GPU seconds are Metal documented host time in seconds. kernel seconds are raw Metal CFTimeInterval; their clock coordinate is not established by the local SDK, so no cross-domain subtraction is claimed. enqueue-call-begin brackets the dispatch submission request, not private queue admission. CPU event clocks are call-boundary wall times including normal waits; no claim of active CPU cycles. GPU command-buffer residency intervals are not active shader cycles. Implicit MPS commit brackets surround super.commitAndContinue, not its private exact commit instant; root create is first observation. Repeated (jobID,stage,rootIndex) rows are later observations of the same root, not extra GPU work. Invalid/unsupported timing is null. No completion callback was installed; GPU data is sampled after existing waits, never a CPU handler-arrival substitute. prepare/warmup before job admission is excluded; stateless submit is explicitly unsupported. No display/quality acceptance."]
    }
}
#endif

#if ODF_AIR_SERVICE_TRACE
// Immutable service rows stay in their producer ring. A checkpoint retains the
// actual sequence boundary and only scalar metadata, so no later row is added
// to an earlier checkpoint and no three full trace copies are kept in memory.
private final class SPAirServiceCapacityMark: NSObject {
    let trace: SPAirServiceTraceStore
    let cutoff: UInt64
    let totals: [String: UInt64]
    let metadata: [String: Any]

    init(trace: SPAirServiceTraceStore, cutoff: UInt64, bridgeEpoch: UInt64) {
        self.trace = trace
        self.cutoff = cutoff
        trace.exportCount &+= 1
        let sampled = mach_absolute_time()
        let jobTotal = trace.jobs.total, eventTotal = trace.events.total, gpuTotal = trace.gpu.total
        totals = ["jobs": jobTotal, "events": eventTotal, "gpu": gpuTotal]
        var result = SPAirServiceSnapshot(sampleHostTicks: sampled, jobs: [], events: [], gpu: [],
            jobTotal: jobTotal, eventTotal: eventTotal, gpuTotal: gpuTotal, runtimeOverflow: trace.runtimeOverflow,
            metadataMismatches: trace.metadataMismatches, exportOrdinal: trace.exportCount,
            modelIdentity: trace.modelIdentity, jobCapacity: UInt64(trace.jobs.capacity),
            eventCapacity: UInt64(trace.events.capacity), gpuCapacity: UInt64(trace.gpu.capacity))
            .export(cutoffHostTicks: cutoff, bridgeEpoch: bridgeEpoch)
        result["jobs"] = spAirServiceCapacityMetadata(trace.jobs, cutoff: cutoff, sequence: { $0.sequence }, host: { $0.admissionHostTicks })
        result["events"] = spAirServiceCapacityMetadata(trace.events, cutoff: cutoff, sequence: { $0.sequence }, host: { $0.hostTicks })
        result["gpu"] = spAirGPUGateMetadata(trace.gpu, cutoff: cutoff)
        result["gpuBodyDiagnostics"] = trace.gpuDetails.metadata()
        result["storeID"] = trace.storeID
        result["sealed"] = trace.sealed
        result["sealedHostTicks"] = trace.sealedHostTicks
        var invalidGPU = 0, invalidKernel = 0, incompleteGPU = 0, stateless = 0
        spAirVisitServiceRing(trace.gpu) { row in
            guard row.sampleHostTicks <= cutoff else { return }
            if (row.flags & 1) != 0 { invalidGPU += 1 }
            if (row.flags & 2) != 0 { incompleteGPU += 1 }
            if (row.flags & 4) != 0 { invalidKernel += 1 }
        }
        spAirVisitServiceRing(trace.events) { row in
            if row.hostTicks <= cutoff && row.kind == .unsupportedStatelessSubmit { stateless += 1 }
        }
        result["invalidGPUTimingRows"] = invalidGPU
        result["invalidKernelTimingRows"] = invalidKernel
        result["incompleteGPUCoverageRows"] = incompleteGPU
        result["unsupportedStatelessSubmits"] = stateless
        metadata = result
    }
}

// The exec-tail fence transfers CPU logging ownership only. Compacting and
// formatting happen on the export utility queue after the bridge is released.
private final class SPAirDetachedServiceSnapshot: NSObject {
    private let lock = NSLock()
    private var trace: SPAirServiceTraceStore?
    let bridgeEpoch: UInt64
    let submittedHostTicks: UInt64
    let reachedHostTicks: UInt64
    let cutoffHostTicks: UInt64
    private var prefixNeedsMetadata = false
    private(set) var retentionRejected = false
    private var retainedBudget: SPAirRetainedPayloadBudget?
    private var reservedBytes: UInt64 = 0
    private(set) var metadata: [String: Any] = [:]
    private(set) var jobs: [SPAirServiceJob] = []
    private(set) var events: [SPAirServiceEvent] = []
    private(set) var gpu: [SPAirGPUGateEntry] = []
    private(set) var gpuFirstSequence: UInt64 = 1
    private(set) var body: [SPAirServiceGPU] = []

    init(trace: SPAirServiceTraceStore, bridgeEpoch: UInt64, submitted: UInt64, reached: UInt64) {
        self.trace = trace; self.bridgeEpoch = bridgeEpoch
        submittedHostTicks = submitted; reachedHostTicks = reached
        cutoffHostTicks = reached
    }

    init(prefix trace: SPAirServiceTraceStore, bridgeEpoch: UInt64, cutoff: UInt64,
         budget: SPAirRetainedPayloadBudget? = nil) {
        self.trace = nil; self.bridgeEpoch = bridgeEpoch
        let sampled = mach_absolute_time()
        submittedHostTicks = sampled; reachedHostTicks = sampled
        cutoffHostTicks = cutoff == 0 ? sampled : cutoff
        super.init()
        trace.exportCount &+= 1
        let context: [String: Any] = ["storeID": trace.storeID, "bridgeEpochAtSnapshot": bridgeEpoch,
            "exportCutoffHostTicks": cutoffHostTicks, "sourceActualCaptureHostTicks": sampled,
            "jobsTotalAtCapture": trace.jobs.total, "eventsTotalAtCapture": trace.events.total,
            "gpuTotalAtCapture": trace.gpu.total]
        guard reservePayload(bytes: spAirRetainedServicePODBytes(trace), budget: budget, context: context) else { return }
        jobs = trace.jobs.copy(); events = trace.events.copy(); gpu = trace.gpu.copy()
        gpuFirstSequence = trace.gpu.total - UInt64(gpu.count) + 1
        body = trace.gpuDetails.retainedRows()
        metadata = SPAirServiceSnapshot(sampleHostTicks: sampled, jobs: [], events: [], gpu: [],
            jobTotal: trace.jobs.total, eventTotal: trace.events.total, gpuTotal: trace.gpu.total,
            runtimeOverflow: trace.runtimeOverflow, metadataMismatches: trace.metadataMismatches,
            exportOrdinal: trace.exportCount, modelIdentity: trace.modelIdentity,
            jobCapacity: UInt64(trace.jobs.capacity), eventCapacity: UInt64(trace.events.capacity),
            gpuCapacity: UInt64(trace.gpu.capacity)).export(cutoffHostTicks: cutoffHostTicks, bridgeEpoch: bridgeEpoch)
        metadata["jobs"] = ["capacity": trace.jobs.capacity, "total": trace.jobs.total] as [String: Any]
        metadata["events"] = ["capacity": trace.events.capacity, "total": trace.events.total] as [String: Any]
        metadata["gpu"] = ["capacity": trace.gpu.capacity, "total": trace.gpu.total] as [String: Any]
        metadata["gpuBodyDiagnostics"] = trace.gpuDetails.metadata()
        metadata["storeID"] = trace.storeID
        metadata["sealed"] = trace.sealed
        metadata["sealedHostTicks"] = trace.sealedHostTicks
        metadata["sourceActualCaptureHostTicks"] = sampled
        metadata["sourceStoppedScope"] = "Live actual CPU checkpoint. Only retained POD and scalar metadata are copied under the existing state lock. No bridge or producer capacity storage is retained. No exec sync or GPU wait."
        prefixNeedsMetadata = true
    }

    deinit {
        jobs.removeAll(keepingCapacity: false)
        events.removeAll(keepingCapacity: false)
        gpu.removeAll(keepingCapacity: false)
        body.removeAll(keepingCapacity: false)
        trace = nil
        retainedBudget?.releaseBytes(reservedBytes)
    }

    private func reservePayload(bytes: UInt64, budget: SPAirRetainedPayloadBudget?,
                                context: [String: Any]) -> Bool {
        guard retainedBudget == nil, let budget else { return true }
        guard budget.reserveBytes(bytes) else {
            retentionRejected = true
            prefixNeedsMetadata = false
            jobs = []; events = []; gpu = []; body = []; trace = nil
            metadata = context
            metadata["enabled"] = false
            metadata["compiled"] = true
            metadata["incomplete"] = true
            metadata["dropped"] = true
            metadata["retentionRejected"] = true
            metadata["recordingError"] = "retained_payload_budget_exceeded"
            metadata["requiredRetainedPODBytes"] = bytes
            metadata["retainedPODBytes"] = UInt64(0)
            metadata["retainedPayloadBudget"] = budget.snapshot()
            return false
        }
        retainedBudget = budget
        reservedBytes = bytes
        return true
    }

    private var ownedPODBytes: UInt64 {
        UInt64(jobs.count * MemoryLayout<SPAirServiceJob>.stride
            + events.count * MemoryLayout<SPAirServiceEvent>.stride
            + gpu.count * MemoryLayout<SPAirGPUGateEntry>.stride
            + body.count * MemoryLayout<SPAirServiceGPU>.stride)
    }

    func compact(budget: SPAirRetainedPayloadBudget? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !retentionRejected else { return }
        if prefixNeedsMetadata {
            guard reservePayload(bytes: ownedPODBytes, budget: budget, context: metadata) else { return }
            let jobHeader = metadata["jobs"] as! [String: Any]
            let eventHeader = metadata["events"] as! [String: Any]
            let gpuHeader = metadata["gpu"] as! [String: Any]
            metadata["jobs"] = spAirCopiedServiceMetadata(jobs, capacity: jobHeader["capacity"] as! Int,
                total: jobHeader["total"] as! UInt64, cutoff: cutoffHostTicks,
                sequence: { _, row in row.sequence }, host: { $0.admissionHostTicks })
            metadata["events"] = spAirCopiedServiceMetadata(events, capacity: eventHeader["capacity"] as! Int,
                total: eventHeader["total"] as! UInt64, cutoff: cutoffHostTicks,
                sequence: { _, row in row.sequence }, host: { $0.hostTicks })
            var gpuMetadata = spAirCopiedServiceMetadata(gpu, capacity: gpuHeader["capacity"] as! Int,
                total: gpuHeader["total"] as! UInt64, cutoff: cutoffHostTicks,
                sequence: { index, _ in self.gpuFirstSequence + UInt64(index) }, host: { $0.sampleHostTicks })
            gpuMetadata["recordingSchema"] = "odf-service-gpu-gate-v1"
            gpuMetadata["flags"] = ["1": "invalidGPU", "2": "incompleteCoverage", "4": "invalidKernel"]
            gpuMetadata["sealed"] = metadata["sealed"]
            metadata["gpu"] = gpuMetadata
            var invalidGPU = 0, incompleteGPU = 0, invalidKernel = 0, stateless = 0
            for row in gpu where row.sampleHostTicks <= cutoffHostTicks {
                if (row.flags & 1) != 0 { invalidGPU += 1 }
                if (row.flags & 2) != 0 { incompleteGPU += 1 }
                if (row.flags & 4) != 0 { invalidKernel += 1 }
            }
            for row in events where row.hostTicks <= cutoffHostTicks && row.kind == .unsupportedStatelessSubmit { stateless += 1 }
            metadata["invalidGPUTimingRows"] = invalidGPU
            metadata["incompleteGPUCoverageRows"] = incompleteGPU
            metadata["invalidKernelTimingRows"] = invalidKernel
            metadata["unsupportedStatelessSubmits"] = stateless
            var bodyExported = 0
            for row in body where row.sampleHostTicks <= cutoffHostTicks { bodyExported += 1 }
            metadata["gpuBodyExportedCount"] = bodyExported
            metadata["gpuBodyCutoffExcludedCount"] = body.count - bodyExported
            metadata["detachedCPUOnly"] = true
            metadata["compactedRetainedPOD"] = true
            metadata["livePrefixCaptured"] = true
            metadata["execTailReached"] = false
            metadata["processorCompletionDrainReady"] = NSNull()
            metadata["retainedPODBytes"] = jobs.count * MemoryLayout<SPAirServiceJob>.stride
                + events.count * MemoryLayout<SPAirServiceEvent>.stride
                + gpu.count * MemoryLayout<SPAirGPUGateEntry>.stride
                + body.count * MemoryLayout<SPAirServiceGPU>.stride
            prefixNeedsMetadata = false
            metadata["reservedRetainedPODBytes"] = reservedBytes
            return
        }
        guard let trace else {
            if reservePayload(bytes: ownedPODBytes, budget: budget, context: metadata) {
                metadata["reservedRetainedPODBytes"] = reservedBytes
            }
            return
        }
        let context: [String: Any] = ["storeID": trace.storeID, "bridgeEpochAtSnapshot": bridgeEpoch,
            "exportCutoffHostTicks": cutoffHostTicks, "execTailReachedHostTicks": reachedHostTicks,
            "jobsTotalAtCapture": trace.jobs.total, "eventsTotalAtCapture": trace.events.total,
            "gpuTotalAtCapture": trace.gpu.total]
        guard reservePayload(bytes: spAirRetainedServicePODBytes(trace), budget: budget, context: context) else { return }
        let mark = SPAirServiceCapacityMark(trace: trace, cutoff: reachedHostTicks, bridgeEpoch: bridgeEpoch)
        jobs = trace.jobs.copy()
        events = trace.events.copy()
        gpu = trace.gpu.copy()
        gpuFirstSequence = trace.gpu.total - UInt64(gpu.count) + 1
        body = trace.gpuDetails.retainedRows()
        metadata = mark.metadata
        metadata["sourceStoppedScope"] = "Retired bridge CPU trace at its actual RIFE exec-tail fence. Source capture may continue on another bridge. This checkpoint is independent from any earlier formal prefix."
        metadata["detachedCPUOnly"] = true
        metadata["compactedRetainedPOD"] = true
        metadata["fenceSubmittedHostTicks"] = submittedHostTicks
        metadata["execTailReachedHostTicks"] = reachedHostTicks
        metadata["execTailReached"] = true
        metadata["processorCompletionDrainReady"] = NSNull()
        metadata["processorCompletionDrainObserved"] = false
        metadata["recordingSealedHostTicks"] = trace.sealedHostTicks
        metadata["postSealAttempts"] = ["jobs": trace.jobs.postSealAttempts,
                                         "events": trace.events.postSealAttempts,
                                         "gpu": trace.gpu.postSealAttempts]
        metadata["postSealRuntimeOverflow"] = trace.postSealRuntimeOverflow
        metadata["retainedPODBytes"] = jobs.count * MemoryLayout<SPAirServiceJob>.stride
            + events.count * MemoryLayout<SPAirServiceEvent>.stride
            + gpu.count * MemoryLayout<SPAirGPUGateEntry>.stride
            + body.count * MemoryLayout<SPAirServiceGPU>.stride
        metadata["originalRingCapacityPODBytes"] = trace.jobs.capacity * MemoryLayout<SPAirServiceJob>.stride
            + trace.events.capacity * MemoryLayout<SPAirServiceEvent>.stride
            + trace.gpu.capacity * MemoryLayout<SPAirGPUGateEntry>.stride
        metadata["detachedScope"] = "Actual retained rows at the RIFE exec-tail fence. Processor completion delivery on its separate queue needs an independent native witness. No bridge, engine, command buffer or texture is retained."
        metadata["reservedRetainedPODBytes"] = reservedBytes
        self.trace = nil
    }
}

private func spAirCopiedServiceMetadata<T>(_ rows: [T], capacity: Int, total: UInt64, cutoff: UInt64,
    sequence: (Int, T) -> UInt64, host: (T) -> UInt64) -> [String: Any] {
    var count = 0
    var first: UInt64?, last: UInt64?
    var excluded: [[String: UInt64]] = []
    for (index, row) in rows.enumerated() {
        let seq = sequence(index, row), stamp = host(row)
        if stamp <= cutoff { count += 1; if first == nil { first = seq }; last = seq }
        else { excluded.append(["sequence": seq, "hostTicks": stamp]) }
    }
    return ["capacity": capacity, "total": total, "dropped": total - UInt64(rows.count),
            "firstseq": first as Any? ?? NSNull(), "lastseq": last as Any? ?? NSNull(), "exportedCount": count,
            "producerTotalAtCopy": total, "retainedCountBeforeCutoffFilter": rows.count,
            "cutoffExcludedCount": excluded.count, "cutoffExcludedRecords": excluded,
            "cutoffHostTicks": cutoff, "overflow": total > UInt64(capacity)]
}

private func spAirVisitServiceRing<T>(_ ring: SPAirServiceRing<T>, _ visit: (T) -> Void) {
    let count = min(ring.total, UInt64(ring.capacity))
    for index in (ring.total - count)..<ring.total { visit(ring.storage[Int(index % UInt64(ring.capacity))]) }
}

private func spAirGPUGateMetadata(_ ring: SPAirServiceRing<SPAirGPUGateEntry>, cutoff: UInt64) -> [String: Any] {
    let retained = min(ring.total, UInt64(ring.capacity))
    var count = 0
    var first: UInt64?, last: UInt64?
    var excluded: [[String: UInt64]] = []
    for index in (ring.total - retained)..<ring.total {
        let row = ring.storage[Int(index % UInt64(ring.capacity))]
        let sequence = index + 1
        if row.sampleHostTicks <= cutoff { count += 1; if first == nil { first = sequence }; last = sequence }
        else { excluded.append(["sequence": sequence, "hostTicks": row.sampleHostTicks]) }
    }
    return ["capacity": ring.capacity, "total": ring.total, "dropped": ring.total - retained,
            "firstseq": first as Any? ?? NSNull(), "lastseq": last as Any? ?? NSNull(), "exportedCount": count,
            "producerTotalAtCopy": ring.total, "retainedCountBeforeCutoffFilter": retained,
            "cutoffExcludedCount": excluded.count, "cutoffExcludedRecords": excluded, "cutoffHostTicks": cutoff,
            "overflow": ring.total > UInt64(ring.capacity), "recordingSchema": "odf-service-gpu-gate-v1",
            "flags": ["1": "invalidGPU", "2": "incompleteCoverage", "4": "invalidKernel"],
            "sealed": ring.sealed]
}

private func spAirServiceCapacityMetadata<T>(_ ring: SPAirServiceRing<T>, cutoff: UInt64,
    sequence: (T) -> UInt64, host: (T) -> UInt64) -> [String: Any] {
    var count = 0
    var first: UInt64?, last: UInt64?
    var excluded: [[String: UInt64]] = []
    spAirVisitServiceRing(ring) { row in
        let seq = sequence(row), stamp = host(row)
        if stamp <= cutoff { count += 1; if first == nil { first = seq }; last = seq }
        else { excluded.append(["sequence": seq, "hostTicks": stamp]) }
    }
    let retained = min(ring.total, UInt64(ring.capacity))
    return ["capacity": ring.capacity, "total": ring.total, "dropped": ring.total - retained,
            "firstseq": first as Any? ?? NSNull(), "lastseq": last as Any? ?? NSNull(), "exportedCount": count,
            "producerTotalAtCopy": ring.total, "retainedCountBeforeCutoffFilter": retained,
            "cutoffExcludedCount": excluded.count, "cutoffExcludedRecords": excluded,
            "cutoffHostTicks": cutoff, "overflow": ring.total > UInt64(ring.capacity)]
}
#endif

extension SPRifeBridge {
    @objc(captureServicePrefixForSessionAtCutoffHostTicks:)
    func captureServicePrefixForSession(cutoffHostTicks: UInt64) -> NSObject {
#if ODF_AIR_SERVICE_TRACE
        state.lock(); defer { state.unlock() }
        guard let trace = airServiceTrace else { return ["enabled": false] as NSDictionary }
        return SPAirDetachedServiceSnapshot(prefix: trace, bridgeEpoch: epoch, cutoff: cutoffHostTicks)
#else
        return ["enabled": false, "compiled": false] as NSDictionary
#endif
    }

    @objc(captureServicePrefixForSessionAtCutoffHostTicks:budget:)
    func captureServicePrefixForSession(cutoffHostTicks: UInt64, budget: SPAirRetainedPayloadBudget) -> NSObject {
#if ODF_AIR_SERVICE_TRACE
        state.lock(); defer { state.unlock() }
        guard let trace = airServiceTrace else { return ["enabled": false] as NSDictionary }
        return SPAirDetachedServiceSnapshot(prefix: trace, bridgeEpoch: epoch,
                                            cutoff: cutoffHostTicks, budget: budget)
#else
        return ["enabled": false, "compiled": false] as NSDictionary
#endif
    }

    @objc(finishServiceTraceForSessionWithCompletion:)
    func finishServiceTraceForSession(completion: @escaping (NSObject?) -> Void) {
#if ODF_AIR_SERVICE_TRACE
        let submitted = mach_absolute_time()
        exec.async {
            self.state.lock()
            guard let trace = self.airServiceTrace else {
                self.state.unlock(); completion(nil); return
            }
            let reached = mach_absolute_time()
            if !trace.sealed {
                trace.sealed = true; trace.sealedHostTicks = reached
                trace.jobs.sealed = true; trace.events.sealed = true; trace.gpu.sealed = true
                trace.gpuDetails.suffix.sealed = true
            }
            let detached = SPAirDetachedServiceSnapshot(trace: trace, bridgeEpoch: self.epoch,
                                                         submitted: submitted, reached: reached)
            self.airServiceTrace = nil
            self.state.unlock()
            completion(detached)
        }
#else
        completion(nil)
#endif
    }

    @objc(compactDetachedServiceTraceSnapshot:)
    static func compactDetachedServiceTraceSnapshot(_ snapshot: NSObject) -> [String: Any] {
#if ODF_AIR_SERVICE_TRACE
        guard let detached = snapshot as? SPAirDetachedServiceSnapshot else { return ["enabled": false] }
        detached.compact()
        return detached.metadata
#else
        return ["enabled": false, "compiled": false]
#endif
    }

    @objc(compactDetachedServiceTraceSnapshot:budget:)
    static func compactDetachedServiceTraceSnapshot(_ snapshot: NSObject,
                                                    budget: SPAirRetainedPayloadBudget) -> [String: Any] {
#if ODF_AIR_SERVICE_TRACE
        guard let detached = snapshot as? SPAirDetachedServiceSnapshot else { return ["enabled": false] }
        detached.compact(budget: budget)
        return detached.metadata
#else
        return ["enabled": false, "compiled": false]
#endif
    }

    @objc(serviceTraceMetadataForDetachedSnapshot:)
    static func serviceTraceMetadataForDetachedSnapshot(_ snapshot: NSObject) -> [String: Any] {
        compactDetachedServiceTraceSnapshot(snapshot)
    }

    @objc(enumerateDetachedServiceTraceSnapshot:ring:usingBlock:)
    static func enumerateDetachedServiceTrace(snapshot: NSObject, ring: String,
                                               usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
#if ODF_AIR_SERVICE_TRACE
        guard let detached = snapshot as? SPAirDetachedServiceSnapshot else { return false }
        detached.compact()
        guard !detached.retentionRejected else { return false }
        switch ring {
        case "jobs":
            for row in detached.jobs where row.admissionHostTicks <= detached.cutoffHostTicks {
                if !autoreleasepool(invoking: { usingBlock(row.sequence, spAirServiceJobRow(row) as NSDictionary) }) { return false }
            }
        case "events":
            for row in detached.events where row.hostTicks <= detached.cutoffHostTicks {
                if !autoreleasepool(invoking: { usingBlock(row.sequence, spAirServiceEventRow(row) as NSDictionary) }) { return false }
            }
        case "gpu":
            for (index, row) in detached.gpu.enumerated() where row.sampleHostTicks <= detached.cutoffHostTicks {
                let sequence = detached.gpuFirstSequence + UInt64(index)
                if !autoreleasepool(invoking: { usingBlock(sequence, spAirGPUGateRow(sequence: sequence, entry: row) as NSDictionary) }) { return false }
            }
        default: return false
        }
        return true
#else
        return false
#endif
    }

    @objc(enumerateDetachedServiceGPUBodyForSnapshot:usingBlock:)
    static func enumerateDetachedServiceGPUBody(snapshot: NSObject,
                                                usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
#if ODF_AIR_SERVICE_TRACE
        guard let detached = snapshot as? SPAirDetachedServiceSnapshot else { return false }
        detached.compact()
        guard !detached.retentionRejected else { return false }
        for row in detached.body where row.sampleHostTicks <= detached.cutoffHostTicks {
            if !autoreleasepool(invoking: { usingBlock(row.sequence, spAirServiceGPURow(row) as NSDictionary) }) { return false }
        }
        return true
#else
        return false
#endif
    }

    @objc(captureServiceTraceAtCutoffHostTicks:)
    func captureServiceTrace(cutoffHostTicks: UInt64) -> NSObject {
#if ODF_AIR_SERVICE_TRACE
        state.lock()
        defer { state.unlock() }
        guard let trace = airServiceTrace else { return ["enabled": false] as NSDictionary }
        return SPAirServiceCapacityMark(trace: trace, cutoff: cutoffHostTicks, bridgeEpoch: epoch)
#else
        return ["enabled": false, "compiled": false] as NSDictionary
#endif
    }

    @objc(sealServiceTraceForDiagnostics)
    func sealServiceTraceForDiagnostics() -> [String: Any] {
#if ODF_AIR_SERVICE_TRACE
        state.lock()
        defer { state.unlock() }
        guard let trace = airServiceTrace else { return ["enabled": false] }
        if !trace.sealed {
            trace.sealed = true
            trace.sealedHostTicks = mach_absolute_time()
            trace.jobs.sealed = true; trace.events.sealed = true; trace.gpu.sealed = true
            trace.gpuDetails.suffix.sealed = true
        }
        return ["sealed": true, "sealedHostTicks": trace.sealedHostTicks,
                "jobsTotal": trace.jobs.total, "eventsTotal": trace.events.total, "gpuTotal": trace.gpu.total]
#else
        return ["enabled": false]
#endif
    }

    @objc(enumerateServiceGPUBodyForSnapshot:usingBlock:)
    func enumerateServiceGPUBody(snapshot: NSObject, usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
#if ODF_AIR_SERVICE_TRACE
        guard let mark = snapshot as? SPAirServiceCapacityMark else { return false }
        state.lock(); let rows = mark.trace.gpuDetails.retainedRows(); let sealed = mark.trace.sealed; state.unlock()
        guard sealed else { return false }
        for row in rows {
            let keepGoing = autoreleasepool { usingBlock(row.sequence, spAirServiceGPURow(row) as NSDictionary) }
            if !keepGoing { return false }
        }
        return true
#else
        return false
#endif
    }

    @objc(serviceTraceMetadataForSnapshot:)
    func serviceTraceMetadata(snapshot: NSObject) -> [String: Any] {
#if ODF_AIR_SERVICE_TRACE
        if let mark = snapshot as? SPAirServiceCapacityMark { return mark.metadata }
#endif
        return ["enabled": false]
    }

    @objc(enumerateServiceTraceSnapshot:ring:usingBlock:)
    func enumerateServiceTrace(snapshot: NSObject, ring: String, usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
#if ODF_AIR_SERVICE_TRACE
        guard let mark = snapshot as? SPAirServiceCapacityMark, let maximum = mark.totals[ring] else { return false }
        switch ring {
        case "jobs":
            state.lock(); let rows = mark.trace.jobs.copy(); state.unlock()
            for row in rows where row.sequence <= maximum && row.admissionHostTicks <= mark.cutoff {
                let keepGoing = autoreleasepool { usingBlock(row.sequence, spAirServiceJobRow(row) as NSDictionary) }
                if !keepGoing { return false }
            }
        case "events":
            state.lock(); let rows = mark.trace.events.copy(); state.unlock()
            for row in rows where row.sequence <= maximum && row.hostTicks <= mark.cutoff {
                let keepGoing = autoreleasepool { usingBlock(row.sequence, spAirServiceEventRow(row) as NSDictionary) }
                if !keepGoing { return false }
            }
        case "gpu":
            state.lock()
            let ring = mark.trace.gpu
            let sealed = ring.sealed
            let end = min(ring.total, maximum)
            let first = ring.total - min(ring.total, UInt64(ring.capacity))
            state.unlock()
            guard sealed else { return false }
            for index in first..<end {
                let entry = ring.storage[Int(index % UInt64(ring.capacity))]
                if entry.sampleHostTicks > mark.cutoff { continue }
                let keepGoing = autoreleasepool { usingBlock(index + 1, spAirGPUGateRow(sequence: index + 1, entry: entry) as NSDictionary) }
                if !keepGoing { return false }
            }
        default: return false
        }
        return true
#else
        return false
#endif
    }
}
