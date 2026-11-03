import AppKit
import Foundation

#if SP_INTERNAL_BUILD && !SP_APP_STORE
/// Heartbeat observations alone cannot prove a hang. Only report delays while
/// active or a player window remains visible; becoming observable starts a fresh
/// observation window so App Nap delays do not carry over.
struct SPHangObservation: Sendable {
    enum Kind: String, Sendable { case stalled, resumed, backgrounded }
    let kind: Kind
    let sequence: Int
    let phase: String
    let duration: TimeInterval
}

struct SPHangWatchdogState {
    private var observableSince: TimeInterval?
    private var stallStartedAt: TimeInterval?
    private var stallPhase = "idle"
    private var sequence = 0

    mutating func observe(now: TimeInterval, lastBeatAt: TimeInterval,
                          phase: String, isObservable: Bool) -> SPHangObservation? {
        guard isObservable else {
            observableSince = nil
            guard let start = stallStartedAt else { return nil }
            stallStartedAt = nil
            return SPHangObservation(kind: .backgrounded, sequence: sequence,
                                     phase: stallPhase, duration: now - start)
        }
        if observableSince == nil { observableSince = now }
        let age = now - max(lastBeatAt, observableSince!)
        if stallStartedAt == nil, age > 0.5 {
            sequence += 1
            stallStartedAt = now - age
            stallPhase = phase
            return SPHangObservation(kind: .stalled, sequence: sequence,
                                     phase: phase, duration: age)
        }
        if let start = stallStartedAt, age <= 0.375 {
            stallStartedAt = nil
            return SPHangObservation(kind: .resumed, sequence: sequence,
                                     phase: stallPhase, duration: now - start)
        }
        return nil
    }
}

/// AppKit visibility is read on the main thread and published together with the
/// heartbeat under the sentinel lock. During a stall the last visible state
/// remains available without asking the blocked main thread for another read.
struct SPHangHeartbeat: Sendable {
    var timestamp: TimeInterval
    var hasVisiblePlayerWindow: Bool

    func isObservable(isActive: Bool) -> Bool {
        isActive || hasVisiblePlayerWindow
    }

    func shouldSample(now: TimeInterval, isActive: Bool,
                      activeStallSequence: Int?, observationSequence: Int) -> Bool {
        activeStallSequence == observationSequence && now - timestamp > 0.5
            && isObservable(isActive: isActive)
    }
}

/// File operations are used only for diagnostic events, never heartbeat polling.
/// Kept independent of AppKit so retention and failure cases can run without GUI.
enum SPHangDiagnosticFiles {
    static func component(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(value.unicodeScalars.prefix(100).map {
            allowed.contains($0) ? Character(String($0)) : "_"
        })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "unknown" : cleaned
    }

    static func directory(root: URL, bundleID: String) -> URL {
        root.appendingPathComponent(component(bundleID), isDirectory: true)
    }

    static func hasThreadSamples(_ text: String) -> Bool {
        guard let graph = text.range(of: "Call graph:") else { return false }
        let body = text[graph.upperBound...].components(separatedBy: "Total number in stack").first
            ?? String(text[graph.upperBound...])
        // Empty sample reports still contain headers and Binary Images. A real
        // thread entry (both current macOS name formats) is required.
        return body.range(of: #"(?m)^\s+[1-9][0-9]* Thread_[^\n]*"#,
                          options: .regularExpression) != nil
    }

    static func pruneSamples(in directory: URL, keeping limit: Int = 20) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.lastPathComponent.hasPrefix("hang_") && $0.pathExtension == "txt" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
        for (url, _) in files.prefix(max(0, files.count - max(0, limit))) {
            try fm.removeItem(at: url)
        }
    }

    /// At most two 128 KiB JSONL files; append writes complete event records.
    static func appendTrace(_ record: [String: Any], in directory: URL,
                            maximumBytes: Int = 128 * 1024) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0a)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let current = directory.appendingPathComponent("events.jsonl")
        let previous = directory.appendingPathComponent("events.previous.jsonl")
        let existingSize = (try? fm.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if existingSize > 0, existingSize + data.count > maximumBytes {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: current, to: previous)
        }
        if !fm.fileExists(atPath: current.path) { try Data().write(to: current) }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

/// Internal responsiveness diagnostics. Public builds omit all storage, watchdog
/// threads, periodic wakeups, and logging. This does not alter playback behavior.
enum SPMainThreadSentinel {
    private static let heartbeatInterval: TimeInterval = 0.25
    private static let lock = NSLock()
    nonisolated(unsafe) private static var heartbeat = SPHangHeartbeat(
        timestamp: 0, hasVisiblePlayerWindow: false)
    nonisolated(unsafe) private static var currentPhase = "idle"
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var activeStallSequence: Int?

    private static let diagnosticsQueue = DispatchQueue(label: "sp.hang.diagnostics", qos: .utility)
    // Accessed only on diagnosticsQueue, including Process completion callbacks.
    nonisolated(unsafe) private static var sampleProcess: Process?
    private static let runID = UUID().uuidString
    private static let sampleSetting = ProcessInfo.processInfo.environment["SP_HANG_SAMPLE"]
    static let diagnosticsDirectory: URL = {
        let root: URL
        if let setting = sampleSetting, !setting.isEmpty, setting != "0" {
            root = URL(fileURLWithPath: setting, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Logs/OpenDuckFrame/hangs", isDirectory: true)
        }
        return SPHangDiagnosticFiles.directory(root: root,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown-bundle")
    }()

    /// Start once, after launch work has left the first-frame critical path.
    @MainActor
    static func start(visibleWindowProvider: @escaping @MainActor @Sendable () -> Bool = { false }) {
        let initialHeartbeat = SPHangHeartbeat(timestamp: ProcessInfo.processInfo.systemUptime,
                                               hasVisiblePlayerWindow: visibleWindowProvider())
        lock.lock()
        let alreadyStarted = started
        started = true
        if !alreadyStarted { heartbeat = initialHeartbeat }
        lock.unlock()
        guard !alreadyStarted else { return }
        let thread = Thread { watchdogLoop(visibleWindowProvider: visibleWindowProvider) }
        thread.name = "sp.mainthread.sentinel"
        thread.qualityOfService = .utility
        thread.start()
    }

    @discardableResult
    static func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = currentPhase
        currentPhase = name
        lock.unlock()
        defer {
            lock.lock()
            currentPhase = previous
            lock.unlock()
        }
        return try body()
    }

    private static func trace(_ name: String, observation: SPHangObservation,
                              timestamp: Date = Date(), detail: String? = nil) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = [
            "timestamp": formatter.string(from: timestamp),
            "event": name, "run": runID, "pid": ProcessInfo.processInfo.processIdentifier,
            "stall": observation.sequence, "phase": observation.phase,
            "duration_ms": (observation.duration * 1000).rounded()
        ]
        if let detail { record["detail"] = detail }
        do {
            try SPHangDiagnosticFiles.appendTrace(record, in: diagnosticsDirectory)
        } catch {
            NSLog("[Hang] event trace write failed: %@", String(describing: error))
        }
    }

    /// One in-flight sample per process. Completed valid reports rotate within
    /// the bundle's directory; old shared-root reports and unrelated files stay.
    private static func captureMainThreadSample(_ observation: SPHangObservation) {
        guard sampleSetting != "0" else { return }
        let isActive = NSRunningApplication.current.isActive
        lock.lock()
        let shouldSample = heartbeat.shouldSample(now: ProcessInfo.processInfo.systemUptime,
            isActive: isActive, activeStallSequence: activeStallSequence,
            observationSequence: observation.sequence)
        lock.unlock()
        guard shouldSample else {
            trace("sample_skipped", observation: observation,
                  detail: "stall ended or app no longer observable before sampling")
            return
        }
        guard sampleProcess == nil else {
            trace("sample_skipped", observation: observation, detail: "sample already in flight")
            return
        }
        let file = diagnosticsDirectory.appendingPathComponent(
            "hang_\(runID)_\(observation.sequence)_\(SPHangDiagnosticFiles.component(observation.phase)).txt")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "1", "-file", file.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { finished in
            diagnosticsQueue.async {
                defer { sampleProcess = nil }
                do {
                    guard finished.terminationReason == .exit, finished.terminationStatus == 0 else {
                        throw NSError(domain: "SPHangSample", code: Int(finished.terminationStatus),
                                      userInfo: [NSLocalizedDescriptionKey: "sample exited unsuccessfully"])
                    }
                    let text = try String(contentsOf: file, encoding: .utf8)
                    guard SPHangDiagnosticFiles.hasThreadSamples(text) else {
                        trace("sample_invalid", observation: observation,
                              detail: "empty call graph; process may have exited before sampling")
                        try? FileManager.default.removeItem(at: file)
                        return
                    }
                } catch {
                    trace("sample_failed", observation: observation, detail: String(describing: error))
                    // Only this attempt's failed artifact is discarded.
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                trace("sample_saved", observation: observation, detail: file.lastPathComponent)
                do {
                    try SPHangDiagnosticFiles.pruneSamples(in: diagnosticsDirectory)
                } catch {
                    trace("retention_failed", observation: observation, detail: String(describing: error))
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            sampleProcess = proc
            try proc.run()
            trace("sample_started", observation: observation, detail: file.lastPathComponent)
        } catch {
            sampleProcess = nil
            trace("sample_failed", observation: observation, detail: String(describing: error))
        }
    }

    private static func watchdogLoop(visibleWindowProvider: @escaping @MainActor @Sendable () -> Bool) {
        var state = SPHangWatchdogState()
        while true {
            Thread.sleep(forTimeInterval: heartbeatInterval)
            DispatchQueue.main.async {
                let updatedHeartbeat = SPHangHeartbeat(timestamp: ProcessInfo.processInfo.systemUptime,
                    hasVisiblePlayerWindow: visibleWindowProvider())
                lock.lock()
                heartbeat = updatedHeartbeat
                lock.unlock()
            }
            lock.lock()
            let beat = heartbeat
            let phase = currentPhase
            lock.unlock()
            let now = ProcessInfo.processInfo.systemUptime
            guard let observation = state.observe(now: now, lastBeatAt: beat.timestamp, phase: phase,
                isObservable: beat.isObservable(isActive: NSRunningApplication.current.isActive))
            else { continue }
            lock.lock()
            activeStallSequence = observation.kind == .stalled ? observation.sequence : nil
            lock.unlock()
            let timestamp = Date()
            if observation.kind == .stalled {
                NSLog("[Hang] Main thread stalled >%.0fms · phase=%@",
                      observation.duration * 1000, observation.phase)
            } else {
                NSLog("[Hang] Main thread %@ · duration ~%.0fms · phase=%@",
                      observation.kind.rawValue, observation.duration * 1000, observation.phase)
            }
            diagnosticsQueue.async {
                trace(observation.kind.rawValue, observation: observation, timestamp: timestamp)
                if observation.kind == .stalled { captureMainThreadSample(observation) }
            }
        }
    }
}
#else
/// Keep shared call sites lightweight when internal diagnostics are disabled.
enum SPMainThreadSentinel {
    @inline(__always)
    @discardableResult
    static func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        try body()
    }
}
#endif
