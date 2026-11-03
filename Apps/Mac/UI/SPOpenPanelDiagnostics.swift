import AppKit
import Foundation

/// Construction intent only; never contains a selected file or directory.
enum SPOpenPanelBuildSource: String, Codable, Sendable {
    case explicitOpen, hover, occluded, test

    var isPrewarm: Bool {
        self == .hover || self == .occluded
    }
}

#if SP_INTERNAL_BUILD && !SP_APP_STORE
struct SPOpenPanelUsageEvent: Sendable {
    enum Kind: Sendable { case construction, presentation, unusedDiscard }
    let kind: Kind
    let source: SPOpenPanelBuildSource
    var duration: TimeInterval = 0
    var cacheHit = false
    var firstPrewarmUse = false
}

/// One cached panel instance per player window. Kept free of AppKit so fast
/// construction, reuse, and abandoned prewarms can be tested without a display.
struct SPOpenPanelUsageSession: Sendable {
    private var source: SPOpenPanelBuildSource?
    private var hasPresented = false

    mutating func constructed(source: SPOpenPanelBuildSource, duration: TimeInterval) -> SPOpenPanelUsageEvent {
        self.source = source
        hasPresented = false
        return SPOpenPanelUsageEvent(kind: .construction, source: source, duration: duration)
    }

    mutating func presented(duration: TimeInterval, cacheHit: Bool) -> SPOpenPanelUsageEvent? {
        guard let source else { return nil }
        let firstPrewarmUse = source.isPrewarm && !hasPresented
        hasPresented = true
        return SPOpenPanelUsageEvent(kind: .presentation, source: source, duration: duration,
                                     cacheHit: cacheHit, firstPrewarmUse: firstPrewarmUse)
    }

    mutating func discarded() -> SPOpenPanelUsageEvent? {
        defer { source = nil; hasPresented = false }
        guard let source, !hasPresented else { return nil }
        return SPOpenPanelUsageEvent(kind: .unusedDiscard, source: source)
    }
}

struct SPOpenPanelUsageTiming: Codable, Sendable {
    var count = 0
    var totalMilliseconds: Double = 0
    var maximumMilliseconds: Double = 0

    mutating func add(_ duration: TimeInterval) {
        let milliseconds = duration.isFinite ? max(0, duration * 1000) : 0
        count += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
    }
}

struct SPOpenPanelUsageDay: Codable, Sendable {
    var constructions: [String: SPOpenPanelUsageTiming] = [:]
    var presentations = SPOpenPanelUsageTiming()
    var presentationCacheHits = 0
    var firstPrewarmUses: [String: Int] = [:]
    var unusedDiscards: [String: Int] = [:]

    mutating func record(_ event: SPOpenPanelUsageEvent) {
        switch event.kind {
        case .construction:
            constructions[event.source.rawValue, default: SPOpenPanelUsageTiming()].add(event.duration)
        case .presentation:
            presentations.add(event.duration)
            if event.cacheHit { presentationCacheHits += 1 }
            if event.firstPrewarmUse { firstPrewarmUses[event.source.rawValue, default: 0] += 1 }
        case .unusedDiscard:
            unusedDiscards[event.source.rawValue, default: 0] += 1
        }
    }
}

/// UTC calendar days, including today and the previous 13 days. Entries are
/// small fixed-schema aggregates, independent of hang-only events.jsonl.
struct SPOpenPanelUsageSummary: Codable, Sendable {
    var schemaVersion = 1
    var days: [String: SPOpenPanelUsageDay] = [:]

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = utcCalendar().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    mutating func record(_ event: SPOpenPanelUsageEvent, at date: Date) {
        days[Self.dayKey(date), default: SPOpenPanelUsageDay()].record(event)
        let cutoff = Self.utcCalendar().date(byAdding: .day, value: -13, to: date)!
        let firstDay = Self.dayKey(cutoff)
        let lastDay = Self.dayKey(date)
        days = days.filter { $0.key >= firstDay && $0.key <= lastDay }
    }
}

private enum SPOpenPanelUsageStore {
    private static let queue = DispatchQueue(label: "sp.open-panel.usage", qos: .utility)
    // Loaded and updated only on queue; never performs I/O on the UI thread.
    nonisolated(unsafe) private static var summary: SPOpenPanelUsageSummary?

    static func record(_ event: SPOpenPanelUsageEvent) {
        let date = Date()
        queue.async {
            let directory = SPMainThreadSentinel.diagnosticsDirectory
            let file = directory.appendingPathComponent("open-panel-usage.json")
            if summary == nil {
                summary = (try? Data(contentsOf: file)).flatMap {
                    try? JSONDecoder().decode(SPOpenPanelUsageSummary.self, from: $0)
                } ?? SPOpenPanelUsageSummary()
            }
            summary!.record(event, at: date)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(summary!).write(to: file, options: .atomic)
            } catch {
                NSLog("[OpenPanelUsage] summary write failed: %@", String(describing: error))
            }
        }
    }
}

@MainActor
final class SPOpenPanelUsageTracker {
    private var session = SPOpenPanelUsageSession()

    func constructed(source: SPOpenPanelBuildSource, duration: TimeInterval) {
        SPOpenPanelUsageStore.record(session.constructed(source: source, duration: duration))
    }

    func presented(duration: TimeInterval, cacheHit: Bool) {
        if let event = session.presented(duration: duration, cacheHit: cacheHit) {
            SPOpenPanelUsageStore.record(event)
        }
    }

    func discarded() {
        if let event = session.discarded() { SPOpenPanelUsageStore.record(event) }
    }

    deinit {
        if let event = session.discarded() { SPOpenPanelUsageStore.record(event) }
    }
}
#else
/// External builds keep call sites without diagnostic storage or a worker queue.
@MainActor
final class SPOpenPanelUsageTracker {
    @inline(__always) func constructed(source: SPOpenPanelBuildSource, duration: TimeInterval) {}
    @inline(__always) func presented(duration: TimeInterval, cacheHit: Bool) {}
    @inline(__always) func discarded() {}
}
#endif

/// A separate owner for each presentation: an old completion can only cancel
/// its own observer. Canceled/failed presentations cannot leak a notification
/// token, and repeated key notifications do not double-count an actual open.
@MainActor
final class SPOpenPanelPresentationObservation {
    nonisolated(unsafe) private var token: NSObjectProtocol?
    private var onPresented: (() -> Void)?

    init(panel: NSWindow, onPresented: @escaping () -> Void) {
        self.onPresented = onPresented
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: panel, queue: .main) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let panel else { return }
                    self?.recordIfVisibleAndKey(panel)
                }
            }
    }

    func recordIfVisibleAndKey(_ panel: NSWindow) {
        guard panel.isVisible, panel.isKeyWindow, let callback = onPresented else { return }
        cancel()
        callback()
    }

    func cancel() {
        onPresented = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
