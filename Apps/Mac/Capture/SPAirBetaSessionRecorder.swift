#if ODF_AIR_BETA_DIAGNOSTIC
import AppKit
import CryptoKit
import QuartzCore

// One measurement-only predicate is shared by the ordinary recorder and the
// linked fixture. Each native flag is backed by its current runtime witness.
@objc(SPAirBetaMeasurementGate)
final class SPAirBetaMeasurementGate: NSObject {
    @objc(evaluateReadiness:positive:)
    static func evaluate(readiness: [String: Any], positive: [String: Any]) -> [String: Any] {
        var reason: String?
        if readiness["enabled"] as? Bool != true { reason = "measurement-readiness-unavailable" }
        else if readiness["nativeActualFinalX2"] as? Bool != true { reason = "final-x2-not-installed" }
        else if readiness["keeperPlanMatchesContext"] as? Bool != true { reason = "keeper-context-mismatch" }
        else if readiness["keeperOperational"] as? Bool != true { reason = "keeper-not-operational" }
        else if readiness["ready"] as? Bool != true { reason = "native-readiness-unconfirmed" }
        else if let token = readiness["planToken"] as? NSNumber,
                token.uint64Value > 0, token == readiness["prepareToken"] as? NSNumber {
            let contextKeys = ["sourceGeneration", "configVersion", "measurementEpoch", "clockEpoch"]
            let matches = contextKeys.allSatisfy { key in
                guard let actual = readiness[key] as? NSNumber, let frame = positive[key] as? NSNumber else { return false }
                return actual == frame
            }
            let time = (positive["presentedTime"] as? NSNumber)?.doubleValue ?? 0
            if !matches { reason = "positive-frame-context-mismatch" }
            else if !time.isFinite || time <= 0 { reason = "current-epoch-positive-not-observed" }
        } else { reason = "installed-plan-token-unconfirmed" }
        return ["schema": "odf-air-beta-measurement-gate-v1", "ready": reason == nil,
            "reason": reason as Any? ?? NSNull(), "runtimeWitness": readiness, "positiveWitness": positive,
            "observedHostTicks": mach_absolute_time()]
    }
}

// Each callback retains numeric values and a few existing scalar strings. It
// never retains a drawable, pixel buffer, command buffer, or frame request.
private struct SPAirBetaPresentedRecord: Sendable {
    enum NumberKind: Sendable { case signed, unsigned, real, boolean }
    struct Field: Sendable {
        let key: String
        let kind: NumberKind
        let timing: Bool
    }
    static let fields: [Field] = {
        let signed = ["captureHost", "presentedHost", "presentationEnqueueHost", "presentationQueueStartHost",
            "displaySelectionHost", "metalCommitHost", "metalScheduledHost", "displayLinkCallbackHost", "logicalTargetHost",
            "scheduledMinusLogicalTargetNs", "actualMinusScheduledDisplayNs", "actualMinusLogicalTargetNs", "gpuHost",
            "ptsNum", "ptsDen", "viewMode", "width", "height", "drawableWidth", "drawableHeight", "enhancedCenter", "originalCenter"]
        let unsigned = ["drawableWaitNs", "displaySlotToken", "generation", "configVersion", "measurementEpoch", "clockEpoch",
            "frameID", "outputDisplayID", "geometryVersion"]
        let real = ["presentedTime", "handlerMediaTime", "metalScheduledMediaTime", "displayLinkTargetTimestamp",
            "displayLinkTargetPresentationTimestamp", "presentRequestMediaTime"]
        let boolean = ["occluded", "windowVisible", "exposed", "synthetic", "counts"]
        let timingSigned = ["selectionHostTicks", "selectionScanEndedHostTicks", "discardReportsStartedHostTicks",
            "discardReportsEndedHostTicks", "renderEntryHostTicks", "primaryCVTextureAPIStartedHostTicks",
            "primaryCVTextureAPIEndedHostTicks", "secondaryCVTextureAPIStartedHostTicks", "secondaryCVTextureAPIEndedHostTicks",
            "preparedMapStartedHostTicks", "preparedMapEndedHostTicks", "texturePreparationEndedHostTicks", "encodingEndedHostTicks",
            "generationLockRequestedHostTicks", "generationLockAcquiredHostTicks", "presentationLockRequestedHostTicks",
            "presentationLockAcquiredHostTicks", "deadlineCheckHostTicks"]
        let timingUnsigned = ["displaySlotToken", "staleDiscardReportCount", "supersededDiscardReportCount", "discardReportCount",
            "timerHandlerRequestedQoSClass", "preparedMapFrameID"]
        let timingReal = ["deadlineCheckMediaTimeSeconds", "presentDeadlineMediaTimeSeconds", "deadlineSlackSeconds"]
        let timingBoolean = ["timerHandlerQoSRecorded", "preparedTextureEnabled", "preparedTextureHit"]
        return signed.map { Field(key: $0, kind: .signed, timing: false) }
            + unsigned.map { Field(key: $0, kind: .unsigned, timing: false) }
            + real.map { Field(key: $0, kind: .real, timing: false) }
            + boolean.map { Field(key: $0, kind: .boolean, timing: false) }
            + timingSigned.map { Field(key: $0, kind: .signed, timing: true) }
            + timingUnsigned.map { Field(key: $0, kind: .unsigned, timing: true) }
            + timingReal.map { Field(key: $0, kind: .real, timing: true) }
            + timingBoolean.map { Field(key: $0, kind: .boolean, timing: true) }
    }()
    static let textKeys = ["presentRequestMethod", "surfaceGeometryAssessment", "timerHandlerRequestedQoSName",
                           "preparedTextureFallbackReason", "scope"]
    static let rootKnown = Set(fields.filter { !$0.timing }.map(\.key))
        .union(textKeys.prefix(2)).union(["airPresentationTiming", "outputImageRectPixels"])
    static let timingKnown = Set(fields.filter(\.timing).map(\.key)).union(textKeys.dropFirst(2))
    let sequence: UInt64
    let words: [UInt64]
    let states: [UInt64]
    let text: [String?]
    let rectangle: [Double]?
    let hasRectangle: Bool
    let hasTiming: Bool
    let unsupported: Bool

    init(sequence: UInt64, info: [String: Any]) {
        self.sequence = sequence
        let timing = info["airPresentationTiming"] as? [String: Any]
        hasTiming = timing != nil
        var values = [UInt64](repeating: 0, count: Self.fields.count)
        var state = [UInt64](repeating: 0, count: (Self.fields.count + 31) / 32)
        var unsupported = false
        for (index, field) in Self.fields.enumerated() {
            guard let item = (field.timing ? timing : info)?[field.key] else { continue }
            let shift = (index % 32) * 2
            if item is NSNull { state[index / 32] |= UInt64(1) << shift; continue }
            guard let number = item as? NSNumber else { unsupported = true; continue }
            state[index / 32] |= UInt64(2) << shift
            switch field.kind {
            case .signed: values[index] = UInt64(bitPattern: number.int64Value)
            case .unsigned: values[index] = number.uint64Value
            case .real:
                if !number.doubleValue.isFinite { unsupported = true }
                values[index] = number.doubleValue.bitPattern
            case .boolean: values[index] = number.boolValue ? 1 : 0
            }
        }
        words = values
        states = state
        text = Self.textKeys.enumerated().map { index, key in
            let value = index < 2 ? info[key] : timing?[key]
            if let value = value as? String, value.utf8.count <= 4096 { return value }
            if value != nil { unsupported = true }
            return nil
        }
        hasRectangle = info["outputImageRectPixels"] != nil
        if let value = info["outputImageRectPixels"] as? [NSNumber], value.count == 4,
           value.allSatisfy({ $0.doubleValue.isFinite }) {
            rectangle = value.map(\.doubleValue)
        } else {
            rectangle = nil
            if let value = info["outputImageRectPixels"], !(value is NSNull) { unsupported = true }
        }
        if info["airPresentationTiming"] != nil && timing == nil { unsupported = true }
        if !info.keys.allSatisfy(Self.rootKnown.contains) || !(timing?.keys.allSatisfy(Self.timingKnown.contains) ?? true) {
            unsupported = true
        }
        self.unsupported = unsupported
    }

    var payloadBytes: UInt64 {
        UInt64(words.count * MemoryLayout<UInt64>.stride + states.count * MemoryLayout<UInt64>.stride +
            (rectangle?.count ?? 0) * MemoryLayout<Double>.stride + text.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count })
    }

    static func payloadBytes(for info: [String: Any]) -> UInt64 {
        let rectangle = info["outputImageRectPixels"] as? [NSNumber]
        let rectangleBytes = rectangle?.count == 4 && rectangle?.allSatisfy({ $0.doubleValue.isFinite }) == true ? 4 * MemoryLayout<Double>.stride : 0
        let timing = info["airPresentationTiming"] as? [String: Any]
        let textBytes = textKeys.enumerated().reduce(0) { count, field in
            let value = (field.offset < 2 ? info[field.element] : timing?[field.element]) as? String
            guard let value, value.utf8.count <= 4096 else { return count }
            return count + value.utf8.count
        }
        return UInt64(fields.count * MemoryLayout<UInt64>.stride + ((fields.count + 31) / 32) * MemoryLayout<UInt64>.stride + rectangleBytes + textBytes)
    }

    func json() -> [String: Any] {
        var result: [String: Any] = [:]
        var timing: [String: Any] = [:]
        for (index, field) in Self.fields.enumerated() {
            let state = (states[index / 32] >> ((index % 32) * 2)) & 3
            guard state != 0 else { continue }
            let value: Any
            if state == 1 { value = NSNull() }
            else {
                switch field.kind {
                case .signed: value = Int64(bitPattern: words[index])
                case .unsigned: value = words[index]
                case .real: value = Double(bitPattern: words[index])
                case .boolean: value = words[index] != 0
                }
            }
            if field.timing { timing[field.key] = value } else { result[field.key] = value }
        }
        for (index, key) in Self.textKeys.enumerated() {
            guard let value = text[index] else { continue }
            if index < 2 { result[key] = value } else { timing[key] = value }
        }
        if hasRectangle { result["outputImageRectPixels"] = rectangle as Any? ?? NSNull() }
        if hasTiming { result["airPresentationTiming"] = timing }
        return result
    }
}

private final class SPAirBetaCallbackLedger: @unchecked Sendable {
    static let capacity = 131_072
    private let lock = NSLock()
    private var rows = [SPAirBetaPresentedRecord?](repeating: nil, count: capacity)
    private var total: UInt64 = 0
    private var unsupported: UInt64 = 0
    private var positive: UInt64 = 0
    private var lastPositiveGeneration: UInt64 = 0
    private var lastPositiveConfig: UInt64 = 0
    private var lastPositiveEpoch: UInt64 = 0
    private var lastPositiveClock: UInt64 = 0
    private var lastPositiveFrameID: UInt64 = 0
    private var lastPositiveHost: UInt64 = 0
    private var lastPositiveTime: Double = 0
    private var recording = true
    private let payloadBudget: SPAirRetainedPayloadBudget?
    private var retainedPayloadBytes: UInt64 = 0
    private var payloadRejections: UInt64 = 0
    private var lastStoredSequence: UInt64 = 0
    private var postSealCallbackAttempts: UInt64 = 0

    init(payloadBudget: SPAirRetainedPayloadBudget? = nil) { self.payloadBudget = payloadBudget }

    deinit {
        rows.removeAll(keepingCapacity: false)
        payloadBudget?.releaseBytes(retainedPayloadBytes)
    }

    func append(_ info: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { postSealCallbackAttempts &+= 1; return false }
        total &+= 1
        let bytes = SPAirBetaPresentedRecord.payloadBytes(for: info)
        if let payloadBudget, !payloadBudget.reserveBytes(bytes) {
            payloadRejections &+= 1; recording = false
            return false
        }
        let row = SPAirBetaPresentedRecord(sequence: total, info: info)
        let index = Int((total - 1) % UInt64(Self.capacity))
        let released = rows[index]?.payloadBytes ?? 0
        rows[index] = row
        payloadBudget?.releaseBytes(released)
        retainedPayloadBytes = retainedPayloadBytes + bytes - released
        lastStoredSequence = total
        if row.unsupported { unsupported &+= 1 }
        let positiveNow = ((info["presentedTime"] as? NSNumber)?.doubleValue ?? 0) > 0
        if positiveNow {
            positive &+= 1
            lastPositiveGeneration = (info["generation"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveConfig = (info["configVersion"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveEpoch = (info["measurementEpoch"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveClock = (info["clockEpoch"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveFrameID = (info["frameID"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveHost = (info["presentedHost"] as? NSNumber)?.uint64Value ?? 0
            lastPositiveTime = (info["presentedTime"] as? NSNumber)?.doubleValue ?? 0
        }
        return positiveNow && positive == 1
    }

    func checkpoint() -> (sequence: UInt64, positive: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (total, positive)
    }

    func positiveWitness() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["sourceGeneration": lastPositiveGeneration, "configVersion": lastPositiveConfig,
            "measurementEpoch": lastPositiveEpoch, "clockEpoch": lastPositiveClock,
            "frameID": lastPositiveFrameID, "presentedHost": lastPositiveHost, "presentedTime": lastPositiveTime]
    }

    func seal() {
        lock.lock(); recording = false; lock.unlock()
    }

    func records(after begin: UInt64, through end: UInt64) -> [[String: Any]] {
        lock.lock()
        let retainedStart = lastStoredSequence > UInt64(Self.capacity) ? lastStoredSequence - UInt64(Self.capacity) + 1 : 1
        let first = max(begin + 1, retainedStart)
        let last = min(end, lastStoredSequence)
        var selected: [SPAirBetaPresentedRecord] = []
        if first <= last {
            selected.reserveCapacity(Int(last - first + 1))
            for sequence in first...last {
                if let row = rows[Int((sequence - 1) % UInt64(Self.capacity))], row.sequence == sequence { selected.append(row) }
            }
        }
        lock.unlock()
        return selected.map {
            var value = $0.json(); value["callbackSequence"] = $0.sequence
            return value
        }
    }

    func metadata() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let retained = min(lastStoredSequence, UInt64(Self.capacity))
        return ["schema": "odf-air-beta-output-callback-v1", "endpoint": "output", "capacity": Self.capacity,
                "total": total, "exportedCount": retained, "dropped": total - retained,
                "firstseq": retained > 0 ? lastStoredSequence - retained + 1 as Any : NSNull(),
                "lastseq": retained > 0 ? lastStoredSequence as Any : NSNull(), "unsupportedRows": unsupported, "sealed": !recording,
                "storage": "typed numeric words, presence/null bits, bounded existing scalar strings; no media objects",
                "numericFieldsPerRecord": SPAirBetaPresentedRecord.fields.count,
                "numericBytesPerRetainedRecord": SPAirBetaPresentedRecord.fields.count * MemoryLayout<UInt64>.stride,
                "presenceBytesPerRetainedRecord": ((SPAirBetaPresentedRecord.fields.count + 31) / 32) * MemoryLayout<UInt64>.stride,
                "recordStrideBytes": MemoryLayout<SPAirBetaPresentedRecord>.stride,
                "producerSlotStrideBytes": MemoryLayout<SPAirBetaPresentedRecord?>.stride,
                "producerSlotCapacityBytes": Self.capacity * MemoryLayout<SPAirBetaPresentedRecord?>.stride,
                "retainedPODPayloadBytes": retainedPayloadBytes, "payloadBudgetAttached": payloadBudget != nil,
                "payloadReservationFailures": payloadRejections, "postSealCallbackAttempts": postSealCallbackAttempts,
                "payloadScope": "Numeric words, presence bits, rectangle doubles and conservative per-record scalar-text UTF8 value bytes. Producer-slot capacity and object/allocator/RSS storage are separate.",
                "scalarTextFieldsPerRecord": SPAirBetaPresentedRecord.textKeys.count, "scalarTextMaxUTF8BytesPerValue": 4096,
                "recordsInTimeline": true]
    }
}

private final class SPAirBetaSessionBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

@objc(SPAirBetaSessionRecorder)
@MainActor final class SPAirBetaSessionRecorder: NSObject {
    nonisolated static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "ODFAirBeta") as? Bool == true ||
            WindowCaptureSource.diagnosticOwnWindowHookEnabled) &&
            ProcessInfo.processInfo.environment["ODF_AIR_BETA_SESSION_RECORDER"] == "1"
    }
    static let finishTimeoutSeconds = 38.0
    private enum State { case idle, armed, recording, finishing, complete, incomplete }
    private let processor: SPLiveProcessor
    private let source: WindowCaptureSource
    private weak var preview: SPLivePreviewView?
    private let baseDirectory: URL
    private let utility = DispatchQueue(label: "app.openduckframe.air-beta-session-export", qos: .utility)
    private let markerQueue = DispatchQueue(label: "app.openduckframe.air-beta-session-markers", qos: .utility)
    private var state = State.idle
    private var markerIO = SPAirBetaMarkerIOState()
    private var sessionID = ""
    private var directory: URL
    private var payloadBudget = SPAirRetainedPayloadBudget(limitBytes: 128 * 1024 * 1024)
    private var ledger = SPAirBetaCallbackLedger()
    private var previousPresented: (([String: Any]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var formalTimer: DispatchSourceTimer?
    private var saturationTimer: DispatchSourceTimer?
    private var finishTimer: DispatchSourceTimer?
    private var callbacks: [([String: Any]) -> Void] = []
    private var markers: [[String: Any]] = []
    private var markerTotal: UInt64 = 0
    private var markerDropped: UInt64 = 0
    private var postCutoffMarkerAttempts: UInt64 = 0
    private var controlMarkerCount = 0
    private var finalLiveLogPersisting = false
    private var finalLiveLogPersisted = false
    private var finalLiveLogAborted = false
    private var finalLiveLogWaiters: [() -> Void] = []
    private var events: [[String: Any]] = []
    private var eventTotal: UInt64 = 0
    private var nextEventIndex = 0
    private var timeline: [[String: Any]] = []
    private var pendingSnapshots = 0
    private var snapshotSequence: UInt64 = 0
    private var lastCallbackSequence: UInt64 = 0
    private var root: [String: Any] = [:]
    private var userSession: [String: Any] = [:]
    private var formalWindow: [String: Any] = [:]
    private var formalSnapshot: AnyObject?
    private var finalSnapshot: AnyObject?
    private var formalEndStats: [String: Any]?
    private var beginHost: UInt64 = 0
    private var formalBeginHost: UInt64 = 0
    private var formalEndHost: UInt64 = 0
    private var formalConfig: UInt64 = 0
    private var formalGeneration: UInt64 = 0
    private var finishHost: UInt64 = 0
    private var finishDeadline: UInt64 = 0
    private var finishReason = ""
    private var measurementReadiness: [String: Any] = [:]
    private var recordingSaturated = false
    private var result: [String: Any]?
    private var nativeSessionReady = false
    private var sourceStopped = false
    private var finalizationRequested = false
    private var eventRecording = true
    private var nativeBeginPending = false
    private var nativeStopRequested = false
    private var nativeStopReceipt: [String: Any] = [:]
    private var keeperJournal: SPAirKeeperSessionJournal?
    private var retiredServices: [[String: Any]] = []
    private var retiredServiceAttempts: UInt64 = 0
    private var writeBudget: SPAirDiagnosticWriteBudget?
    private var keeperWaitTimer: DispatchSourceTimer?
    private var executableIdentity: [String: Any] = [:]
    private var identityPending = false
    private var externallyDriven = false
    private var diagnosticOutputPath: String?
    private var diagnosticOptionsProvider: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    private var diagnosticOptions: [String: Any]?
    private var diagnosticOptionsPending = false

    var isActive: Bool { state == .armed || state == .recording }
    var isFinishing: Bool { state == .finishing }
    var canArm: Bool { state == .idle || state == .complete }

    init(processor: SPLiveProcessor, source: WindowCaptureSource, preview: SPLivePreviewView, directory: URL) {
        self.processor = processor
        self.source = source
        self.preview = preview
        self.baseDirectory = directory
        self.directory = directory
        super.init()
    }

    @objc(armWithWindowID:ownerPID:generation:)
    func arm(windowID: UInt32, ownerPID: Int32, generation: UInt64) {
        guard Self.isEnabled else { return }
        if isActive {
            let priorWindow = ((userSession["latestSelectedWindowID"] ?? userSession["selectedWindowID"]) as? NSNumber)?.uint32Value
            let priorGeneration = ((userSession["latestProductSourceGeneration"] ?? userSession["productSourceGeneration"]) as? NSNumber)?.uint64Value
            if priorWindow != windowID || priorGeneration != generation {
                closeFormal(complete: false, reason: "source-target-or-generation-changed")
                persistStage("source-target-changed", details: ["fromWindowID": priorWindow as Any? ?? NSNull(),
                    "toWindowID": windowID, "fromProductGeneration": priorGeneration as Any? ?? NSNull(),
                    "toProductGeneration": generation, "ownerPID": ownerPID])
                userSession["latestSelectedWindowID"] = windowID; userSession["latestOwnerPID"] = ownerPID
                userSession["latestProductSourceGeneration"] = generation
            } else { persistStage("plan-update-submitted") }
            return
        }
        guard canArm else { return }
        sessionID = UUID().uuidString.lowercased()
        directory = externallyDriven ? baseDirectory : baseDirectory.appendingPathComponent(sessionID, isDirectory: true)
        state = .armed
        payloadBudget = SPAirRetainedPayloadBudget(limitBytes: 128 * 1024 * 1024)
        ledger = SPAirBetaCallbackLedger(payloadBudget: payloadBudget)
        markers = []; events = []; timeline = []; eventTotal = 0; snapshotSequence = 0; lastCallbackSequence = 0
        markerIO = SPAirBetaMarkerIOState()
        markerTotal = 0; markerDropped = 0; postCutoffMarkerAttempts = 0; controlMarkerCount = 0; nextEventIndex = 0
        finalLiveLogPersisting = false; finalLiveLogPersisted = false; finalLiveLogAborted = false; finalLiveLogWaiters = []
        formalBeginHost = 0; formalEndHost = 0; formalSnapshot = nil; finalSnapshot = nil; formalEndStats = nil
        finishHost = 0; finishReason = ""; result = nil; finalizationRequested = false; sourceStopped = false
        nativeSessionReady = false; measurementReadiness = [:]; recordingSaturated = false; eventRecording = true
        nativeStopRequested = false; nativeStopReceipt = [:]; retiredServices = []; retiredServiceAttempts = 0
        executableIdentity = [:]; identityPending = true; writeBudget = nil
        beginHost = mach_absolute_time()
        userSession = ["schema": "odf-air-beta-user-session-v1", "sessionID": sessionID,
            "selectedWindowID": windowID, "ownerPID": ownerPID, "productSourceGeneration": generation,
            "intendedProtocol": externallyDriven ? "diagnostic-owned-window" : "html30-first-60s-then-own-content-120s",
            "contentIdentity": ["observed": false, "basis": "protocol_only"], "endpoint": "output"]
        root = ["schema": "odf-air-stream-result-v1", "legacySchemaPresent": true,
                "legacySchema": "odf-air-beta-user-session-v1", "stage": "beta-user-session",
                "associationTailObserved": false, "associationPresentationOrder": NSNull(), "sourceInput": NSNull()]
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        root["machTimebase"] = ["numer": timebase.numer, "denom": timebase.denom]
        formalWindow = ["beginHostTicks": NSNull(), "endHostTicks": NSNull(), "complete": false]
        attachObservers()
        persistStage("session-armed", details: ["intendedRole": "html30", "roleBasis": "three-minute-user-protocol"])
        beginNativeSession()
        readExecutableIdentity()
        if !externallyDriven {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.sampleTimeline(reason: "periodic", host: mach_absolute_time()) }
            self.timer = timer; timer.resume()
        }
        let saturation = DispatchSource.makeTimerSource(queue: .main)
        saturation.schedule(deadline: .now() + 720)
        saturation.setEventHandler { [weak self] in self?.sealRecordingForSaturation() }
        saturationTimer = saturation; saturation.resume()
    }

    func observeReadyStats(_ stats: [String: Any]) {
        guard isActive else { return }
        let plan = processor.resolvedPlan
        if state == .recording, plan.configVersion != formalConfig || source.currentGeneration != formalGeneration {
            closeFormal(complete: false, reason: "installed-plan-or-source-generation-changed")
        }
        measurementReadiness = stats["airBetaMeasurementReadiness"] as? [String: Any] ?? [:]
        maybeBeginFormal()
    }

    private func attachObservers() {
        previousPresented = preview?.presented
        let production = SPAirBetaPresentedForwarder(previousPresented)
        let ledger = ledger
        preview?.presented = { @Sendable [weak self] info in
            production.callback?(info)
            guard ledger.append(info) else { return }
            DispatchQueue.main.async { self?.maybeBeginFormal() }
        }
        source.setAirBetaSessionObserver { [weak self] event in
            let box = SPAirBetaSessionBox(event)
            DispatchQueue.main.async { self?.recordCaptureEvent(box.value) }
        }
    }

    private func recordCaptureEvent(_ event: [String: Any]) {
        guard eventRecording else { return }
        eventTotal &+= 1
        var row = event; row["sequence"] = eventTotal
        row["observerMainHostTicks"] = mach_absolute_time()
        let cache = processor.cachedStatsSnapshot()
        let stats = cache["stats"] as? [String: Any] ?? [:]
        var context: [String: Any] = [:]
        for key in ["sourceGeneration", "configVersion", "measurementEpoch", "clockEpoch", "sourceWidth", "sourceHeight",
                    "statsSampling", "airBeta"] { context[key] = stats[key] ?? NSNull() }
        row["processorCachedObservation"] = context
        row["processorCacheAgeNs"] = cache["ageNs"] ?? NSNull()
        row["processorCacheStale"] = cache["snapshotStale"] ?? NSNull()
        row["keeperSessionSummary"] = keeperJournal?.summary() ?? [:]
        if events.count < 4096 { events.append(row) }
        else { events[nextEventIndex] = row; nextEventIndex = (nextEventIndex + 1) % 4096 }
    }

    private func maybeBeginFormal() {
        guard !externallyDriven, state == .armed, nativeSessionReady else { return }
        let proof = SPAirBetaMeasurementGate.evaluate(readiness: measurementReadiness, positive: ledger.positiveWitness())
        guard proof["ready"] as? Bool == true,
              (measurementReadiness["sourceGeneration"] as? NSNumber)?.uint64Value == source.currentGeneration,
              (measurementReadiness["configVersion"] as? NSNumber)?.uint64Value == processor.resolvedPlan.configVersion else { return }
        root["measurementReadyProof"] = proof
        state = .recording
        formalBeginHost = mach_absolute_time()
        formalConfig = processor.resolvedPlan.configVersion; formalGeneration = source.currentGeneration
        formalWindow = ["beginHostTicks": formalBeginHost, "endHostTicks": NSNull(), "complete": false]
        processor.markResidentKeepAlivePhase("phase0")
        persistStage("formal-begin", details: ["intendedRole": "html30", "roleBasis": "three-minute-user-protocol"])
        sampleTimeline(reason: "formal-begin", host: formalBeginHost)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { [weak self] in self?.closeFormal(complete: true, reason: "sixty-second-window-ended") }
        formalTimer = timer; timer.resume()
    }

    private func closeFormal(complete: Bool, reason: String) {
        guard formalBeginHost != 0, formalEndHost == 0 else { return }
        formalTimer?.cancel(); formalTimer = nil
        formalEndHost = mach_absolute_time()
        formalWindow["endHostTicks"] = formalEndHost
        formalWindow["complete"] = complete
        if !complete { formalWindow["interruptionReason"] = reason }
        persistStage("formal-end", details: ["complete": complete, "reason": reason,
            "nextIntendedRole": "subjective-own-content", "contentIdentityObserved": false])
        sampleTimeline(reason: "formal-end", host: formalEndHost)
        captureFormalCheckpoint(host: formalEndHost)
    }

    @objc(finishForReason:completion:)
    func finish(reason: String, completion: @escaping ([String: Any]) -> Void) {
        if let result { completion(result); return }
        guard state != .idle else { completion(["state": "idle", "complete": true]); return }
        callbacks.append(completion)
        guard state != .finishing else { return }
        state = .finishing
        finishReason = reason
        finishHost = mach_absolute_time()
        finishDeadline = finishHost + Self.hostTicks(seconds: Self.finishTimeoutSeconds)
        closeFormal(complete: false, reason: reason)
        timer?.cancel(); timer = nil
        saturationTimer?.cancel(); saturationTimer = nil
        persistStage("stop-requested", details: ["reason": reason, "timeoutSeconds": Self.finishTimeoutSeconds,
                                                "deadlineHostTicks": finishDeadline])
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + Self.finishTimeoutSeconds)
        timeout.setEventHandler { [weak self] in self?.forceIncomplete(reason: "stop-drain-export-timeout") }
        finishTimer = timeout; timeout.resume()
        source.stopAirBetaSession { [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            DispatchQueue.main.async {
                guard let self, self.state == .finishing else { return }
                self.sourceStopped = true
                self.root["sourceStopAndFence"] = box.value
                self.persistStage("source-stop-and-queue-fence", details: box.value)
                if let error = box.value["error"] as? String { self.root["sourceStopError"] = error }
                self.finishNativeSession()
            }
        }
    }

    func forceIncomplete(reason: String) {
        guard state != .idle else { return }
        if var exported = result {
            guard !finalLiveLogPersisted, !finalLiveLogAborted else { return }
            finalLiveLogAborted = true
            exported["exportStatusBeforeFinalizationTimeout"] = exported["exportStatus"] ?? NSNull()
            exported["exportStatus"] = exportStatus(complete: false, timedOut: true, reason: reason)
            exported["complete"] = false; exported["reason"] = reason
            result = exported; state = .incomplete
            source.endAirBetaSessionStop(allowRestart: false)
            persistStage("finalization-incomplete", details: exported)
            let value = SPAirBetaSessionBox(exported)
            let path = directory.appendingPathComponent("finalization-incomplete.json")
            DispatchQueue.global(qos: .utility).async { Self.writeSmallJSON(value.value, to: path) }
            finalLiveLogPersisting = false
            let waiting = finalLiveLogWaiters; finalLiveLogWaiters = []
            waiting.forEach { $0() }
            return
        }
        ledger.seal(); eventRecording = false
        writeBudget?.cancel()
        keeperWaitTimer?.cancel(); keeperWaitTimer = nil
        timer?.cancel(); formalTimer?.cancel(); saturationTimer?.cancel()
        let status = exportStatus(complete: false, timedOut: true, reason: reason)
        persistStage("export-incomplete", details: status)
        let value = SPAirBetaSessionBox(["exportStatus": status, "complete": false, "directory": directory.path,
                                       "sessionID": sessionID, "reason": reason])
        let path = directory.appendingPathComponent("incomplete.json")
        // This independent small write never gates the main-thread timeout reply.
        DispatchQueue.global(qos: .utility).async { Self.writeSmallJSON(value.value, to: path) }
        completeFinish(value.value)
    }

    @objc(recordFinalLiveLogReceipt:completion:)
    func recordFinalLiveLogReceipt(_ receipt: [String: Any], completion: @escaping () -> Void) {
        if finalLiveLogPersisted || finalLiveLogAborted { completion(); return }
        finalLiveLogWaiters.append(completion)
        guard !finalLiveLogPersisting else { return }
        finalLiveLogPersisting = true
        persistStage("final-live-log-flushed", details: receipt) {
            guard !self.finalLiveLogAborted else { return }
            self.finalLiveLogPersisted = true; self.finalLiveLogPersisting = false
            let waiting = self.finalLiveLogWaiters; self.finalLiveLogWaiters = []
            waiting.forEach { $0() }
        }
    }

    private func exportStatus(complete: Bool, timedOut: Bool, reason: String) -> [String: Any] {
        ["state": complete ? "complete" : "incomplete", "complete": complete, "timedOut": timedOut,
         "saturated": recordingSaturated, "reason": reason, "beginHostTicks": finishHost,
         "endHostTicks": mach_absolute_time(), "timeoutSeconds": Self.finishTimeoutSeconds]
    }

    private func completeFinish(_ value: [String: Any]) {
        guard result == nil else { return }
        result = value
        state = (value["complete"] as? Bool == true) ? .complete : .incomplete
        finishTimer?.cancel(); finishTimer = nil
        source.setAirBetaSessionObserver(nil)
        source.endAirBetaSessionStop(allowRestart: value["complete"] as? Bool == true)
        preview?.presented = previousPresented
        previousPresented = nil
        let waiting = callbacks; callbacks.removeAll()
        waiting.forEach { $0(value) }
    }

    private func beginNativeSession() {
        let journal = SPAirKeeperSessionJournal(sessionID: sessionID, beginHostTicks: beginHost)
        keeperJournal = journal
        nativeBeginPending = true
        processor.beginAirTraceRecordingSession(sessionID, keeperJournal: journal, payloadBudget: payloadBudget, retiredServiceHandler: { @Sendable [weak self] token, context in
            let box = SPAirBetaSessionBox(["snapshot": token, "context": context])
            DispatchQueue.main.async {
                guard let self else { return }
                self.retiredServiceAttempts &+= 1
                if self.retiredServices.count < 64 { self.retiredServices.append(box.value) }
            }
        }, replyQueue: .main) { [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            MainActor.assumeIsolated {
                let receipt = box.value
                guard let self else { return }
                self.nativeBeginPending = false
                self.nativeSessionReady = (receipt["success"] as? Bool == true) && (receipt["resetComplete"] as? Bool == true)
                self.root["recordingBegin"] = receipt
                self.persistStage("native-recording-reset", details: receipt)
                self.maybeBeginFormal()
                if self.sourceStopped { self.finishNativeSession() }
            }
        }
    }

    private func sampleTimeline(reason: String, host: UInt64) {
        guard state == .armed || state == .recording || state == .finishing, !recordingSaturated else { return }
        snapshotSequence &+= 1
        let sequence = snapshotSequence
        let callbacks = ledger.checkpoint()
        let beginSequence = lastCallbackSequence
        lastCallbackSequence = callbacks.sequence
        let boundary = processor.statsBoundaryCountersSnapshot()
        let cache = processor.cachedStatsSnapshot()
        let context = cache["stats"] as? [String: Any] ?? [:]
        let phase = formalBeginHost == 0 ? -1 : (formalEndHost == 0 || host <= formalEndHost ? 0 : 1)
        let checkpoint: [String: Any] = ["sequence": sequence, "reason": reason, "snapshotHostTicks": host,
            "phase": phase, "hostElapsedSeconds": Self.seconds(ticks: host - beginHost),
            "callbackSequenceBeginExclusive": beginSequence, "callbackSequenceEndInclusive": callbacks.sequence,
            "drawable": ["validPresentedCallbacks": callbacks.positive, "endpoint": "output"],
            "processorBoundary": boundary, "processorContext": context, "processorCacheObservation": cache]
        pendingSnapshots += 1
        let collection = SPAirBetaSnapshotCollection()
        let ready = DispatchGroup()
        ready.enter()
        source.airBetaSessionSnapshot { value in collection.capture = value; ready.leave() }
        ready.enter()
        processor.requestStatsSnapshot(on: utility) { @Sendable value in collection.stats = value; ready.leave() }
        let checkpointBox = SPAirBetaSessionBox(checkpoint)
        ready.notify(queue: utility) { @Sendable [weak self] in
            let source = collection.capture
            let sampledStats = collection.stats
            var row = checkpointBox.value
            row["capture"] = source
            let boundary = row.removeValue(forKey: "processorBoundary") as? [String: Any] ?? [:]
            let context = row.removeValue(forKey: "processorContext") as? [String: Any] ?? [:]
            row["processor"] = Self.stats(sampledStats, boundary: boundary, context: context)
            let assembled = SPAirBetaSessionBox(row)
            DispatchQueue.main.async {
                guard let self, self.result == nil else { return }
                self.timeline.append(assembled.value)
                if reason == "formal-end" { self.formalEndStats = assembled.value["processor"] as? [String: Any] }
                self.pendingSnapshots -= 1
                self.maybeExport()
            }
        }
    }

    private func captureFormalCheckpoint(host: UInt64) {
        pendingSnapshots += 1
        processor.captureAirTraceCheckpoint(cutoffHostTicks: host, replyQueue: .main) { [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            MainActor.assumeIsolated {
                let receipt = box.value
                guard let self else { return }
                self.formalSnapshot = receipt["snapshot"] as AnyObject?
                if receipt["snapshot"] is NSNull { self.formalSnapshot = nil }
                self.root["formalPresentationOrder"] = receipt["metadata"] ?? NSNull()
                self.root["formalCheckpointReceipt"] = receipt.filter { $0.key != "snapshot" }
                self.pendingSnapshots -= 1
                self.maybeExport()
            }
        }
    }

    private func sealRecordingForSaturation() {
        guard isActive, !recordingSaturated else { return }
        let cutoff = mach_absolute_time()
        ledger.seal(); eventRecording = false
        sampleTimeline(reason: "recording-limit", host: cutoff)
        recordingSaturated = true
        timer?.cancel(); timer = nil
        _ = keeperJournal?.sealRecording(atHostTicks: cutoff, reason: "recording-limit-720s")
        persistStage("recording-saturated", details: ["limitSeconds": 720, "pipelineStopRequested": false])
        processor.sealAirTraceRecording(reason: "recording-limit-720s", replyQueue: .main) { [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            MainActor.assumeIsolated {
                let receipt = box.value
                self?.root["saturationReceipt"] = receipt
            }
        }
    }

    private func finishNativeSession() {
        guard state == .finishing, sourceStopped, !nativeBeginPending, !nativeStopRequested else { return }
        nativeStopRequested = true
        processor.requestStopResidentKeepAlive(forDiagnostics: finishReason)
        processor.stopAirTraceSession(deadlineHostTicks: finishDeadline, replyQueue: .main) { [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            MainActor.assumeIsolated {
                let receipt = box.value
                guard let self, self.state == .finishing else { return }
                self.nativeStopReceipt = receipt
                self.root["nativeStop"] = receipt
                self.persistStage("native-stop-drain-observed", details: receipt)
                self.waitForKeeperClosure()
            }
        }
    }

    private func waitForKeeperClosure() {
        let journal = keeperJournal
        let readiness = journal?.readiness() ?? [:]
        root["keeperReadiness"] = readiness
        guard readiness["allPlansObservedTerminal"] as? Bool == true else {
            guard keeperWaitTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.observeKeeperClosure() }
            keeperWaitTimer = timer; timer.resume()
            return
        }
        observeKeeperClosure()
    }

    private func observeKeeperClosure() {
        guard state == .finishing else { keeperWaitTimer?.cancel(); keeperWaitTimer = nil; return }
        let readiness = keeperJournal?.readiness() ?? [:]
        root["keeperReadiness"] = readiness
        guard readiness["allPlansObservedTerminal"] as? Bool == true else { return }
        keeperWaitTimer?.cancel(); keeperWaitTimer = nil
        _ = keeperJournal?.sealRecording(atHostTicks: mach_absolute_time(), reason: finishReason)
        persistStage("keeper-lifecycle-closed", details: readiness)
        processor.sealAirTraceRecording(reason: finishReason, replyQueue: .main) { [weak self] seal in
            let box = SPAirBetaSessionBox(seal)
            MainActor.assumeIsolated {
                let seal = box.value
                guard let self, self.state == .finishing else { return }
                self.root["recordingSeal"] = seal
                self.processor.captureSealedAirTraceSnapshot(replyQueue: .main) { [weak self] receipt in
                    let box = SPAirBetaSessionBox(receipt)
                    MainActor.assumeIsolated {
                        let receipt = box.value
                        guard let self, self.state == .finishing else { return }
                        self.ledger.seal(); self.eventRecording = false
                        self.sampleTimeline(reason: "final-cutoff", host: mach_absolute_time())
                        self.finalSnapshot = receipt["snapshot"] as AnyObject?
                        if receipt["snapshot"] is NSNull { self.finalSnapshot = nil }
                        self.root["presentationOrder"] = receipt["metadata"] ?? NSNull()
                        self.root["finalCheckpointReceipt"] = receipt.filter { $0.key != "snapshot" }
                        self.persistStage("final-sealed-checkpoint", details: receipt.filter { $0.key != "snapshot" })
                        self.maybeExport()
                    }
                }
            }
        }
    }

    private func maybeExport() {
        guard state == .finishing, finalSnapshot != nil, pendingSnapshots == 0, !identityPending, !finalizationRequested else { return }
        if externallyDriven, diagnosticOptions == nil {
            guard !diagnosticOptionsPending, let provider = diagnosticOptionsProvider else { return }
            diagnosticOptionsPending = true
            var context = root
            context["formal"] = formalSnapshot as Any? ?? NSNull()
            context["final"] = finalSnapshot as Any? ?? NSNull()
            context["finalTimelineSnapshot"] = timeline.last as Any? ?? NSNull()
            provider(context) { [weak self] options in
                let box = SPAirBetaSessionBox(options)
                DispatchQueue.main.async {
                    self?.diagnosticOptions = box.value
                    self?.diagnosticOptionsPending = false
                    self?.maybeExport()
                }
            }
            return
        }
        finalizationRequested = true
        if let external = diagnosticOptions?["document"] as? [String: Any] {
            root.merge(external) { _, diagnostic in diagnostic }
        }
        let callbackMetadata = ledger.metadata()
        userSession["markers"] = markers
        userSession["markerCapacity"] = 256
        userSession["markerAttemptsAtExport"] = markerTotal
        userSession["droppedMarkers"] = markerDropped
        userSession["controlMarkerCapacity"] = 32
        userSession["postCutoffMarkerAttempts"] = postCutoffMarkerAttempts
        userSession["formalWindow"] = formalWindow
        userSession["binaryIdentity"] = executableIdentity
        root["betaUserSession"] = userSession
        if !externallyDriven { root["formalEndProcessorStats"] = formalEndStats as Any? ?? NSNull() }
        root["outputCallbackTrace"] = callbackMetadata
        root["retainedPODPayloadBudget"] = payloadBudget.snapshot()
        let orderedEvents = Array(events[nextEventIndex...]) + Array(events[..<nextEventIndex])
        root["captureEvents"] = ["capacity": 4096, "total": eventTotal, "exportedCount": events.count,
            "dropped": eventTotal - UInt64(events.count), "records": orderedEvents]
        root["retiredServiceTraceSummary"] = ["capacity": 64, "total": retiredServiceAttempts,
            "retained": retiredServices.count, "dropped": retiredServiceAttempts - UInt64(retiredServices.count)]
        root["keeperSessionJournal"] = keeperJournal?.summary() ?? [:]
        root["markerPersistence"] = markerIO.snapshot()
        let recordingBegin = (root["recordingBegin"] as? [String: Any])?["beginHostTicks"] as? NSNumber
        let recordingEnd = (root["recordingSeal"] as? [String: Any])?["sealHostTicks"] as? NSNumber
        if let recordingBegin, let recordingEnd, recordingEnd.uint64Value >= recordingBegin.uint64Value {
            let seconds = Self.seconds(ticks: recordingEnd.uint64Value - recordingBegin.uint64Value)
            root["writePeriod"] = ["limitSeconds": 720, "startHostTicks": recordingBegin,
                "finalCaptureEndHostTicks": recordingEnd, "actualSeconds": seconds, "exceeded": seconds > 720,
                "saturated": recordingSaturated, "scope": "Actual native logger begin/seal receipts; processing may continue after the recording cutoff."]
        } else {
            root["writePeriod"] = ["limitSeconds": 720, "startHostTicks": recordingBegin as Any? ?? NSNull(),
                "finalCaptureEndHostTicks": recordingEnd as Any? ?? NSNull(), "actualSeconds": NSNull(),
                "exceeded": NSNull(), "saturated": recordingSaturated]
        }
        if !externallyDriven {
            root["phases"] = [["index": 0, "label": "enhanced", "requestedSeconds": 60,
                "measurementStartHostTicks": formalBeginHost > 0 ? formalBeginHost as Any : NSNull(),
                "measurementEndHostTicks": formalEndHost > 0 ? formalEndHost as Any : NSNull(),
                "complete": formalWindow["complete"] ?? false]]
        }
        let sourceReceipt = root["sourceStopAndFence"] as? [String: Any] ?? [:]
        let sourceObserved = sourceReceipt["captureQueueDrained"] as? Bool == true &&
            (sourceReceipt["streamPresentAtRequest"] as? Bool == false || sourceReceipt["completionObserved"] as? Bool == true)
        let complete = sourceObserved && markerIO.snapshot()["complete"] as? Bool == true &&
            (nativeStopReceipt["nativeDrainComplete"] as? Bool == true) &&
            (root["keeperReadiness"] as? [String: Any])?["allPlansObservedTerminal"] as? Bool == true &&
            (callbackMetadata["dropped"] as? UInt64 == 0) && (callbackMetadata["unsupportedRows"] as? UInt64 == 0) &&
            (callbackMetadata["payloadBudgetAttached"] as? Bool == true) &&
            (payloadBudget.snapshot()["reservationFailures"] as? UInt64 == 0) &&
            retiredServiceAttempts == UInt64(retiredServices.count) && eventTotal == UInt64(events.count) &&
            markerDropped == 0 && nativeSessionReady && (executableIdentity["executableSHA256"] as? String)?.count == 64
        var pendingStatus = exportStatus(complete: false, timedOut: false, reason: finishReason)
        pendingStatus["state"] = "exporting"; pendingStatus["observationsComplete"] = complete
        root["exportStatus"] = pendingStatus
        var rows = timeline.sorted { ($0["sequence"] as? UInt64 ?? 0) < ($1["sequence"] as? UInt64 ?? 0) }
        if let external = diagnosticOptions?["timeline"] as? [[String: Any]] { rows = external + rows }
        let timelineBox = SPAirBetaTimelineBox(rows)
        let ledger = ledger
        let provider: @convention(block) @Sendable (UInt) -> NSDictionary = { index in
            var row = timelineBox.rows[Int(index)]
            var drawable = row["drawable"] as? [String: Any] ?? [:]
            let begin = (row["callbackSequenceBeginExclusive"] as? NSNumber)?.uint64Value ?? 0
            let end = (row["callbackSequenceEndInclusive"] as? NSNumber)?.uint64Value ?? 0
            drawable["presentedEventsSinceSnapshot"] = ledger.records(after: begin, through: end)
            row["drawable"] = drawable
            return row as NSDictionary
        }
        var options: [String: Any] = ["processor": processor, "document": root,
            "directory": directory.path, "outputPath": diagnosticOutputPath ?? directory.appendingPathComponent("session.json").path,
            "progressPath": directory.appendingPathComponent("export-progress.ndjson").path,
            "deadlineHostTicks": finishDeadline, "timelineCount": rows.count, "timelineProvider": provider,
            "retiredServiceTraces": retiredServices]
        options["formal"] = formalSnapshot as Any? ?? NSNull()
        options["association"] = diagnosticOptions?["association"] ?? NSNull()
        options["extraTraceWriter"] = diagnosticOptions?["extraTraceWriter"]
        options["final"] = finalSnapshot as Any? ?? NSNull()
        options["keeperJournal"] = keeperJournal as Any? ?? NSNull()
        persistStage("stream-export-begin")
        writeBudget = SPAirBetaSessionExportBridge.write(options: options) { @Sendable [weak self] receipt in
            let box = SPAirBetaSessionBox(receipt)
            DispatchQueue.main.async {
                guard let self, self.state == .finishing else { return }
                let completed = complete && box.value["complete"] as? Bool == true && self.markerIO.snapshot()["complete"] as? Bool == true
                var result = box.value
                result["complete"] = completed
                result["exportStatus"] = self.exportStatus(complete: completed, timedOut: false, reason: self.finishReason)
                result["directory"] = self.directory.path; result["sessionID"] = self.sessionID
                self.persistStage(completed ? "stream-export-complete" : "export-incomplete", details: result) {
                    var observed = result
                    let markerStatus = self.markerIO.snapshot()
                    observed["markerPersistence"] = markerStatus
                    if markerStatus["complete"] as? Bool != true {
                        observed["complete"] = false
                        observed["exportStatus"] = self.exportStatus(complete: false, timedOut: false, reason: "stage-persistence-failed")
                    }
                    self.completeFinish(observed)
                }
            }
        }
    }

    @objc(configureDiagnosticOutputPath:)
    func configureDiagnosticOutputPath(_ path: String) {
        guard state == .idle else { return }
        externallyDriven = true; diagnosticOutputPath = path
    }

    @objc(setDiagnosticOptionsProvider:)
    func setDiagnosticOptionsProvider(_ provider: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) {
        diagnosticOptionsProvider = provider
    }

    @objc(diagnosticCallbackRange)
    func diagnosticCallbackRange() -> [String: Any] {
        let cutoff = ledger.checkpoint().sequence
        let begin = lastCallbackSequence; lastCallbackSequence = cutoff
        return ["callbackSequenceBeginExclusive": begin, "callbackSequenceEndInclusive": cutoff]
    }

    @objc(adoptDiagnosticFormalCheckpoint:)
    func adoptDiagnosticFormalCheckpoint(_ values: [String: Any]) {
        guard externallyDriven else { return }
        formalSnapshot = values["snapshot"] as AnyObject?
        if values["snapshot"] is NSNull { formalSnapshot = nil }
        formalBeginHost = (values["beginHostTicks"] as? NSNumber)?.uint64Value ?? 0
        formalEndHost = (values["endHostTicks"] as? NSNumber)?.uint64Value ?? 0
        formalWindow = ["beginHostTicks": formalBeginHost, "endHostTicks": formalEndHost,
                        "complete": values["complete"] ?? false, "externallyDriven": true]
        root["formalPresentationOrder"] = values["metadata"] ?? NSNull()
        persistStage("formal-end", details: ["complete": values["complete"] ?? false,
            "measurementStartHostTicks": formalBeginHost, "measurementEndHostTicks": formalEndHost,
            "externallyDriven": true, "contentIdentityObserved": false])
    }

    private func readExecutableIdentity() {
        guard let path = Bundle.main.executableURL else {
            executableIdentity = ["executableSHA256": NSNull(), "error": "Bundle executableURL is unavailable"]
            identityPending = false
            return
        }
        utility.async { [weak self] in
            var identity: [String: Any] = ["executablePath": path.path, "sampleBeginHostTicks": mach_absolute_time()]
            do {
                let file = try FileHandle(forReadingFrom: path)
                defer { try? file.close() }
                var hasher = SHA256()
                while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
                identity["executableSHA256"] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } catch {
                identity["executableSHA256"] = NSNull(); identity["error"] = error.localizedDescription
            }
            identity["sampleEndHostTicks"] = mach_absolute_time()
            let box = SPAirBetaSessionBox(identity)
            DispatchQueue.main.async {
                guard let self else { return }
                self.executableIdentity = box.value; self.identityPending = false; self.maybeExport()
            }
        }
    }

    nonisolated private static func stats(_ value: [String: Any], boundary: [String: Any], context: [String: Any]) -> [String: Any] {
        var result = value
        var slots = result["presentationSlots"] as? [String: Any] ?? [:]
        var output = slots["output"] as? [String: Any] ?? [:]
        output["preparedTexture"] = ((boundary["presentationSlots"] as? [String: Any])?["output"] as? [String: Any])?["preparedTexture"] ?? [:]
        slots["output"] = output; result["presentationSlots"] = slots
        var failures = result["presentationFailuresLifetime"] as? [String: Any] ?? [:]
        failures["output.display-submit-deadline"] = boundary["enabled"] as? Bool == true
            ? (boundary["presentationFailuresLifetime"] as? [String: Any])?["output.display-submit-deadline"] ?? NSNull() : NSNull()
        result["presentationFailuresLifetime"] = failures
        for key in ["sourceGeneration", "configVersion", "measurementEpoch", "clockEpoch", "engineID", "qualityID",
                    "rifeStreamEnabled", "rateRequestedMultiplier", "selectionGuardNs"] { result[key] = context[key] ?? NSNull() }
        result["statsBoundaryCountersSampling"] = boundary
        result["statsContextSampling"] = context["statsSampling"] ?? NSNull()
        return result
    }

    nonisolated private static func seconds(ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func persistStage(_ stage: String, details: [String: Any] = [:], completion: (() -> Void)? = nil) {
        let control = ["stop-requested", "source-stop-and-queue-fence", "native-stop-drain-observed", "keeper-lifecycle-closed",
            "final-sealed-checkpoint", "stream-export-begin", "stream-export-complete", "export-incomplete", "final-live-log-flushed", "finalization-incomplete", "recording-saturated"].contains(stage)
        markerTotal &+= 1
        if control {
            guard controlMarkerCount < 32 else { markerDropped &+= 1; completion?(); return }
            controlMarkerCount += 1
        } else if recordingSaturated {
            postCutoffMarkerAttempts &+= 1; completion?(); return
        } else if markers.count >= 256 {
            markerDropped &+= 1; completion?(); return
        }
        let event: [String: Any] = ["schema": "odf-air-beta-session-stage-v1", "stage": stage,
            "sessionID": sessionID, "hostTicks": mach_absolute_time(), "uptimeNs": DispatchTime.now().uptimeNanoseconds,
            "utcEpochSeconds": Date().timeIntervalSince1970, "details": details]
        if markers.count < 256 { markers.append(event) }
        let box = SPAirBetaSessionBox(event)
        let path = directory.appendingPathComponent("session-stages.ndjson")
        let completion = completion.map { callback in SPAirBetaMainCompletion(callback) }
        let io = markerIO
        markerQueue.async {
            io.record(Self.appendStageJSON(box.value, to: path))
            if let completion { DispatchQueue.main.async { completion.callback() } }
        }
    }

    nonisolated private static func hostTicks(seconds: Double) -> UInt64 {
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        return UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    nonisolated private static func writeSmallJSON(_ value: [String: Any], to path: URL) {
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: path, options: .atomic)
        } catch { fputs("Air session marker write failed: \(error.localizedDescription)\n", stderr) }
    }

    nonisolated private static func appendStageJSON(_ value: [String: Any], to path: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
            let file = try FileHandle(forWritingTo: path)
            defer { try? file.close() }
            try file.seekToEnd()
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
            try file.write(contentsOf: data); try file.synchronize()
            return nil
        } catch {
            fputs("Air session stage write failed: \(error.localizedDescription)\n", stderr)
            return error.localizedDescription
        }
    }
}

private final class SPAirBetaMarkerIOState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: UInt64 = 0
    private var firstFailure: [String: Any]?
    func record(_ error: String?) {
        lock.lock()
        attempts &+= 1
        if let error, firstFailure == nil {
            firstFailure = ["message": error, "observedHostTicks": mach_absolute_time(),
                            "utcEpochSeconds": Date().timeIntervalSince1970]
        }
        lock.unlock()
    }
    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["attempts": attempts, "complete": firstFailure == nil, "firstFailure": firstFailure as Any? ?? NSNull()]
    }
}

private final class SPAirBetaPresentedForwarder: @unchecked Sendable {
    let callback: (([String: Any]) -> Void)?
    init(_ callback: (([String: Any]) -> Void)?) { self.callback = callback }
}

private final class SPAirBetaSnapshotCollection: @unchecked Sendable {
    // Each property has one producer. DispatchGroup leave/notify publishes both
    // completed immutable dictionaries before the utility assembly reads them.
    var capture: [String: Any] = [:]
    var stats: [String: Any] = [:]
}

private final class SPAirBetaTimelineBox: @unchecked Sendable {
    let rows: [[String: Any]]
    init(_ rows: [[String: Any]]) { self.rows = rows }
}

private final class SPAirBetaMainCompletion: @unchecked Sendable {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
}
#endif
