import Foundation

@main struct PerformanceSimulationTests {
    static func main() {
        let off = SPPerformanceSimulation(environment: [:])
        precondition(!off.enabled && off.targetDuration(measured: 0.01) == 0.01)
        let high = SPPerformanceSimulation(environment: ["ODF_PERF_PROFILE": "m1pro-16"])
        let low = SPPerformanceSimulation(environment: ["ODF_PERF_PROFILE": "m1pro-14"])
        precondition(abs(high.targetDuration(measured: 0.01) - 0.032) < 1e-9)
        precondition(abs(low.targetDuration(measured: 0.01) - 0.035) < 1e-9)
        let floor = SPPerformanceSimulation(environment: ["ODF_PERF_PROFILE": "custom", "ODF_PERF_MODEL_MIN_MS": "60"])
        precondition(floor.targetDuration(measured: 0.01) == 0.06)
        let start = ProcessInfo.processInfo.systemUptime
        let elapsed = floor.finish(started: start)
        precondition(elapsed >= 0.059 && elapsed < 0.25)
        print("{\"ok\":true,\"disabledByDefault\":true,\"profilesAndLatencyFloor\":true,\"measuredFloorMs\":\(elapsed * 1000)}")
    }
}
