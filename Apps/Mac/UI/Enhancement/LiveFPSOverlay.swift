import Foundation

// Uses only the current committed processor snapshot; an edited but unapplied
// control, an old source, and a stale sample cannot contribute a target label.
enum LiveFPSOverlay {
    static func fresh(stats: [String: Any], now: TimeInterval, receipt: TimeInterval,
                      generation: UInt64, config: UInt64, running: Bool, paused: Bool) -> Bool {
        running && !paused && receipt > 0 && now >= receipt && now - receipt < 1.5 &&
            (stats["snapshotStale"] as? Bool) != true &&
            (stats["sourceGeneration"] as? UInt64) == generation &&
            (stats["configVersion"] as? UInt64) == config
    }
    static func text(stats: [String: Any], now: TimeInterval, receipt: TimeInterval,
                     generation: UInt64, config: UInt64, running: Bool, paused: Bool,
                     committed: Bool, interpolation: Bool, canObserve: Bool,
                     outputObservable: Bool, chinese: Bool) -> String {
        let fresh = fresh(stats: stats, now: now, receipt: receipt, generation: generation, config: config,
                          running: running, paused: paused)
        func rate(_ key: String, _ permitted: Bool) -> Double? {
            guard fresh && permitted, let value = stats[key] as? Double, value.isFinite, value > 0 else { return nil }
            return value
        }
        func value(_ rate: Double?) -> String { rate.map { String(format: "%.1f", $0) } ?? "—" }
        let input = rate("overlayInputEstimateFPS", canObserve)
        let output = rate("overlayPresentedFPS", outputObservable)
        let target = rate("estimatedRequestedFPS", committed && interpolation)
        let multiplier = fresh && (stats["rateKind"] as? String) == "multiplier" ? (stats["rateMultiplier"] as? Int ?? 0) : 0
        let suffix = target != nil && multiplier > 1 ? " (X\(multiplier))" : ""
        let display = fresh ? (stats["displayRefreshHz"] as? Double ?? 0) : 0
        let screen = display.isFinite && display > 0 ? String(format: "%.0f", display) : "—"
        let passthrough = fresh && committed && interpolation && (stats["nativeBudgetActive"] as? Bool) == true
            ? (chinese ? " · 原生直通" : " · Native passthrough") : ""
        let approximate = !fresh || (stats["requestedFPSIsEstimated"] as? Bool) == true
        let targetLabel = chinese ? (approximate ? "目标≈" : "目标") : (approximate ? "Target≈" : "Target")
        return (chinese ? "输入/采集≈" : "Capture≈") + " \(value(input)) · " + targetLabel + " \(value(target))\(suffix) FPS\n" +
            (chinese ? "呈现" : "Presented") + " \(value(output)) FPS · " + (chinese ? "屏幕" : "Display") + " \(screen) Hz" + passthrough
    }
}

enum LiveRuntimeStatus {
    static let interactiveBudgetWarning = "互动预算已用尽，赶不上的帧会计入覆盖率"
    static func nativePassthroughIsCurrent(stats: [String: Any], now: TimeInterval, receipt: TimeInterval,
                                           generation: UInt64, config: UInt64, running: Bool, paused: Bool,
                                           committed: Bool, interpolation: Bool, pending: Bool) -> Bool {
        committed && interpolation && !pending && (stats["nativeBudgetActive"] as? Bool) == true &&
            LiveFPSOverlay.fresh(stats: stats, now: now, receipt: receipt, generation: generation,
                                 config: config, running: running, paused: paused)
    }
    static func shouldClearDisplayedWarning(_ displayed: String, localizedWarning: String, nativeCurrent: Bool) -> Bool {
        nativeCurrent && displayed == localizedWarning
    }
}
