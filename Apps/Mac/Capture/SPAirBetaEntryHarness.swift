#if ODF_AIR_BETA_DIAGNOSTIC
import AppKit
import CoreMedia
import CoreVideo

// The fixture is linked into the application. An explicit diagnostic mode and
// runtime switch select the self-owned-window controller.
@MainActor final class SPAirBetaEntryHarness {
    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        guard ProcessInfo.processInfo.environment["ODF_AIR_BETA_CAPTURE_DIAGNOSTIC"] == "1",
              let index = arguments.firstIndex(of: "--odf-air-beta-entry-test"),
              arguments.indices.contains(index + 1) else { return false }
        return ["app60", "resize", "release"].contains(arguments[index + 1])
    }

    private let driver: NSObject

    init?() {
        guard WindowCaptureSource.diagnosticOwnWindowHookEnabled,
              let driverClass = NSClassFromString("SPAirBetaEntryDriver") as? NSObject.Type else {
            fputs("Owned-window diagnostic requires its compiled, CLI and runtime gates.\n", stderr)
            return nil
        }
        driver = driverClass.init()
    }

    static func sourceFPS(arguments: [String], mode: String) -> Int? {
        let flag = "--odf-air-beta-source-fps"
        var fps = 24
        if let index = arguments.firstIndex(of: flag) {
            guard arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]), [24, 30].contains(value) else { return nil }
            fps = value
        }
        return mode == "app60" || mode == "release" || (mode == "resize" && fps == 24) ? fps : nil
    }

    func start() -> Bool {
        let args = CommandLine.arguments
        func value(_ option: String) -> String? {
            guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let mode = value("--odf-air-beta-entry-test"), ["app60", "resize", "release"].contains(mode),
              let sourceFPS = Self.sourceFPS(arguments: args, mode: mode),
              let output = value("--odf-air-beta-entry-output"), output.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: output) else {
            fputs("Owned-window diagnostic requires a supported mode, source FPS24/30 (resize24), and a new absolute output path.\n", stderr)
            return false
        }
        var options: [String: Any] = ["output": output, "entry-mode": mode, "arm": "rife",
            "control-only": true, "source-fps": sourceFPS, "capture-format": "nv12",
            "source-width-points": 1100, "source-height-points": 800,
            "seconds": mode == "resize" ? 20 : 60, "quality-seconds": 0, "minimum-idle-seconds": 60]
        if mode == "release" {
            guard Bundle.main.object(forInfoDictionaryKey: "ODFAirBeta") as? Bool != true,
                  let durationText = value("--odf-release-duration-seconds"), let duration = Int(durationText),
                  let trace = value("--odf-release-trace"),
                  let configuration = value("--odf-release-validation-config"),
                  ["fast-x2-stream", "quality-switch"].contains(configuration),
                  (trace == "full" && duration == 60 && configuration == "fast-x2-stream") ||
                    (trace == "summary" && ((duration == 180 && configuration == "fast-x2-stream") ||
                     (duration == 10 && configuration == "quality-switch"))) else {
                fputs("Release validation requires the ordinary bundle and full60, summary180 or quality-switch summary10.\n", stderr)
                return false
            }
            options["seconds"] = duration
            options["release-validation"] = true
            options["release-trace"] = trace
            options["release-config"] = configuration
        }
        driver.perform(NSSelectorFromString("runWithOptions:"), with: options as NSDictionary)
        return true
    }
}

// Objective-C fixture front end. The production source owns SCK, content gate,
// owned copy, resize policy and callbacks. This object only binds their sinks.
@objc(SPAirBetaWindowCaptureFacade)
final class SPAirBetaWindowCaptureFacade: NSObject, @unchecked Sendable {
    @objc var sampleHandler: (@Sendable (CMSampleBuffer, UInt64, UInt64, UInt64) -> Void)?
    @objc var gateHandler: (@Sendable (CMSampleBuffer, UInt64, UInt64, UInt64) -> Void)?
    @objc var constructionHandler: (@Sendable (UInt64, UInt64, UInt64) -> Void)?
    @objc var statusHandler: (@Sendable (String, Bool) -> Void)?
    @objc var resizeEventHandler: (@Sendable ([String: Any]) -> Void)?
    private let source = WindowCaptureSource()
    private let processor: SPLiveProcessor
    private let counterLock = NSLock()
    private var geometryCallbacks: UInt64 = 0
    private var geometryAvailableCallbacks: UInt64 = 0
    private var rawCallbacks: UInt64 = 0
    private var frameCallbacks: UInt64 = 0
    private var poolPressureCallbacks: UInt64 = 0
    private var generationCallbacks: UInt64 = 0
    private var diagnosticCallbacks: UInt64 = 0
    @objc var observationQueue: DispatchQueue { source.diagnosticObservationQueue }
    @objc func ownedCopyErrorCounters() -> [String: Any] { source.diagnosticOwnedCopyErrorCounters() }

    @objc(initWithProcessor:)
    init(processor: SPLiveProcessor) {
        self.processor = processor
        super.init()
        source.onNote = { [weak self] code in self?.processor.noteCaptureStatus(code) }
        source.onGeometry = { [weak self] geometry, generation in
            guard let self else { return }
            self.counterLock.lock()
            self.geometryCallbacks &+= 1
            if geometry != nil { self.geometryAvailableCallbacks &+= 1 }
            self.counterLock.unlock()
            self.processor.observeCaptureGeometry(geometry, generation: generation)
        }
        source.onRawFrame = { [weak self] ptsNum, ptsDen, host, width, height, generation in
            guard let self else { return }
            self.counterLock.lock(); self.rawCallbacks &+= 1; self.counterLock.unlock()
            self.processor.noteRawCapture(ptsNum: ptsNum, ptsDen: ptsDen, host: host,
                                         width: width, height: height, generation: generation)
        }
        source.onPoolPressure = { [weak self] generation in
            guard let self else { return }
            self.counterLock.lock(); self.poolPressureCallbacks &+= 1; self.counterLock.unlock()
            self.processor.noteCapturePoolPressure(forGeneration: generation)
        }
        source.onFrame = { [weak self] buffer, ptsNum, ptsDen, captureHost, readyHost, generation in
            guard let self else { return }
            self.counterLock.lock(); self.frameCallbacks &+= 1; self.counterLock.unlock()
            self.processor.push(buffer, ptsNum: ptsNum, ptsDen: ptsDen, host: captureHost,
                                readyHost: readyHost, generation: generation)
        }
        source.onGeneration = { [weak self] generation in
            guard let self else { return }
            self.counterLock.lock(); self.generationCallbacks &+= 1; self.counterLock.unlock()
            self.processor.adoptSourceGeneration(generation)
        }
        source.onStatus = { [weak self] text, failed in self?.statusHandler?(text, failed) }
        source.onDiagnostic = { [weak self] _ in
            guard let self else { return }
            self.counterLock.lock(); self.diagnosticCallbacks &+= 1; self.counterLock.unlock()
        }
        source.onDiagnosticSample = { [weak self] sample, productGeneration, streamGeneration, host in
            self?.sampleHandler?(sample, productGeneration, streamGeneration, host)
        }
        source.onDiagnosticGateAdmission = { [weak self] sample, productGeneration, streamGeneration, host in
            self?.gateHandler?(sample, productGeneration, streamGeneration, host)
        }
        source.onDiagnosticStreamConstruction = { [weak self] streamGeneration, productGeneration, host in
            self?.constructionHandler?(streamGeneration, productGeneration, host)
        }
        source.onDiagnosticResizeEvent = { [weak self] event in self?.resizeEventHandler?(event) }
    }

    @MainActor @objc(startOwnWindow:excludedWindowIDs:)
    func startOwnWindow(_ windowID: UInt32, excludedWindowIDs: [NSNumber]) {
        let outputIDs = excludedWindowIDs.map(\.uint32Value)
        source.excludedWindowIDs = { outputIDs.map(Int.init) }
        source.startDiagnosticOwnWindow(windowID: windowID, outputWindowIDs: outputIDs)
    }

    @MainActor @objc(makeSessionRecorderWithPreview:directory:)
    func makeSessionRecorder(preview: SPLivePreviewView, directory: String) -> NSObject {
        SPAirBetaSessionRecorder(processor: processor, source: source, preview: preview,
            directory: URL(fileURLWithPath: directory, isDirectory: true))
    }

    @objc(captureEntryFenceAtCutoffHostTicks:handler:)
    func captureEntryFence(cutoffHostTicks: UInt64, handler: @escaping @Sendable ([String: Any]) -> Void) {
        source.airBetaCaptureEntryFence(cutoffHostTicks: cutoffHostTicks, handler: handler)
    }

    @objc func captureDiagnostics() -> [String: Any] {
        var result = source.diagnostics()
        result["callbackCounts"] = callbackCounterSnapshot()
        return result
    }

    private func callbackCounterSnapshot() -> [String: UInt64] {
        counterLock.lock()
        let counts = ["geometry": geometryCallbacks, "geometryAvailable": geometryAvailableCallbacks,
            "rawFrame": rawCallbacks, "frame": frameCallbacks,
            "poolPressure": poolPressureCallbacks, "generation": generationCallbacks, "diagnostic": diagnosticCallbacks]
        counterLock.unlock()
        return counts
    }

    @objc func normalCaptureReport() -> [String: Any] {
        normalCaptureReport(for: captureDiagnostics())
    }

    // Formats an already observed source-queue snapshot without entering that
    // queue again. The embedded diagnostic requests the snapshot asynchronously.
    @objc(normalCaptureReportForSnapshot:)
    func normalCaptureReport(for snapshot: [String: Any]) -> [String: Any] {
        let proof = snapshot["diagnosticHook"] as? [String: Any] ?? [:]
        return ["schema": "odf-air-beta-normal-capture-v1", "entryPoint": "WindowCaptureSource",
            "activation": ["compiled": true, "runtimeEnabled": WindowCaptureSource.diagnosticOwnWindowHookEnabled,
                "explicitWindowID": proof["windowID"] ?? NSNull()],
            "filterProof": proof, "callbackCounts": snapshot["callbackCounts"] ?? callbackCounterSnapshot(),
            "seedSource": proof["seedSource"] ?? NSNull(), "seedPixelSize": proof["seedPixelSize"] ?? NSNull(),
            "productSourceGeneration": snapshot["productSourceGeneration"] ?? NSNull(),
            "sourceGeneration": snapshot["captureStreamGeneration"] ?? NSNull(), "diagnostics": snapshot]
    }

    @objc(snapshotAtHostNs:generation:)
    func snapshot(atHostNs host: Int64, generation: UInt64) -> [String: Any] {
        var snapshot = source.diagnosticSnapshotOnCaptureQueue()
        snapshot["callbackCounts"] = callbackCounterSnapshot()
        return ["ownedCopy": snapshot, "contentGate": snapshot, "normalCapture": snapshot]
    }

    @MainActor @objc(stopCaptureWithCompletion:)
    func stopCapture(completion: @escaping @Sendable (String?) -> Void) {
        source.onDiagnosticStopCompletion = { [weak self] message in
            self?.source.drainDiagnosticCaptureQueue { completion(message) }
        }
        if source.canRestart {
            source.stop()
        } else {
            source.drainDiagnosticCaptureQueue { completion("No diagnostic SCK stream was committed.") }
        }
    }
}
#endif
