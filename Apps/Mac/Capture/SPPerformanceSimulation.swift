import Foundation

/// Opt-in, process-local service-time simulation for the serial RIFE worker.
/// This models slower completion/throughput, not GPU architecture or memory capacity.
struct SPPerformanceSimulation: Sendable {
    static let current = SPPerformanceSimulation(environment: ProcessInfo.processInfo.environment)

    let profile: String
    let slowdown: Double
    let minimumJobSeconds: TimeInterval
    var enabled: Bool { profile != "off" }

    init(environment: [String: String]) {
        let requested = environment["ODF_PERF_PROFILE"] ?? "off"
        let defaultSlowdown: Double
        switch requested {
        case "m1pro-16": defaultSlowdown = 3.2
        case "m1pro-14": defaultSlowdown = 3.5
        case "custom": defaultSlowdown = 1
        default:
            profile = "off"; slowdown = 1; minimumJobSeconds = 0
            return
        }
        profile = requested
        let factor = Double(environment["ODF_PERF_MODEL_SLOWDOWN"] ?? "") ?? defaultSlowdown
        slowdown = factor.isFinite ? min(20, max(1, factor)) : defaultSlowdown
        let milliseconds = Double(environment["ODF_PERF_MODEL_MIN_MS"] ?? "") ?? 0
        minimumJobSeconds = milliseconds.isFinite ? min(2, max(0, milliseconds / 1000)) : 0
    }

    func targetDuration(measured: TimeInterval) -> TimeInterval {
        enabled ? max(measured * slowdown, minimumJobSeconds) : measured
    }

    /// Called on the inference worker while its task is still busy. Original
    /// timestamps and the player's clocks/deadlines remain untouched.
    func finish(started: TimeInterval) -> TimeInterval {
        let measured = max(0, ProcessInfo.processInfo.systemUptime - started)
        let remaining = targetDuration(measured: measured) - measured
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        return max(measured, ProcessInfo.processInfo.systemUptime - started)
    }
}
