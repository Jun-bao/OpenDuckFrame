import Foundation

@main struct R6PolicyTests {
    static func main() {
        precondition(SingleInstancePolicy.matchesProductMetadata("OpenDuckFrame", "Khua"))
        precondition(SingleInstancePolicy.matchesProductMetadata("小川帧流 · ChuanFlow", "Khua"))
        precondition(!SingleInstancePolicy.matchesProductMetadata("OpenDuckFrame", "Other"))
        precondition(!SingleInstancePolicy.matchesProductMetadata("Other", "Khua"))
        precondition(!SingleInstancePolicy.matchesProductMetadata(nil, "Khua"))
        typealias C = SingleInstancePolicy.Candidate
        let first = C(pid: 90, start: 100)
        let later = C(pid: 12, start: 101)
        precondition(SingleInstancePolicy.winner([first, later]) == first)
        precondition(SingleInstancePolicy.winner([later, first]) == first)
        let tie1 = C(pid: 5, start: 100)
        let tie2 = C(pid: 9, start: 100)
        precondition(SingleInstancePolicy.winner([tie2, tie1]) == tie1)
        let unavailableStart = C(pid: 99, start: nil)
        precondition(SingleInstancePolicy.winner([first, unavailableStart]) == first)
        precondition(SingleInstancePolicy.winner([unavailableStart, first]) == first)
        precondition(SingleInstancePolicy.preferredPeer([later], ownPID: first.pid) == nil)
        precondition(SingleInstancePolicy.preferredPeer([later, first], ownPID: first.pid) == nil)
        precondition(SingleInstancePolicy.preferredPeer([first, later], ownPID: later.pid) == first)
        precondition(SingleInstancePolicy.isContract(["Khua", "--khua-session-contract"]))
        precondition(!SingleInstancePolicy.isContract(["Khua", "--khua-isolated-profile", "/tmp/example"]))

        var saved: [String?] = []
        var notices = 0
        func choose(_ target: String?, _ current: String?, _ running: String?, _ resolved: String?) {
            LanguageChangePolicy.change(target: target, current: current, running: running,
                effective: { _ in resolved }, persist: { saved.append($0) }, notifyRelaunch: { notices += 1 })
        }
        choose("en", "en", "en", "en")
        precondition(saved.isEmpty && notices == 0)
        choose("zh-Hans", "en", "en", "zh-Hans")
        precondition(saved.count == 1 && saved[0] == "zh-Hans" && notices == 1)
        choose(nil, "zh-Hans", "en", "en")
        precondition(saved.count == 2 && saved[1] == nil && notices == 1)
        let optIn = ["Khua", "--khua-pixel-diagnostics", "--khua-isolated-profile", "/tmp/profile", "--khua-live-log", "/tmp/live.ndjson"]
        precondition(PixelDiagnosticsPolicy.enabled(optIn))
        precondition(!PixelDiagnosticsPolicy.enabled(["Khua", "--khua-pixel-diagnostics", "--khua-isolated-profile", "/tmp/profile"]))
        precondition(!PixelDiagnosticsPolicy.enabled(["Khua", "--khua-pixel-diagnostics", "--khua-isolated-profile", "relative", "--khua-live-log", "/tmp/log"]))
        precondition(!PixelDiagnosticsPolicy.enabled(["Khua", "--khua-isolated-profile", "/tmp/profile", "--khua-live-log", "/tmp/log"]))

        let stats: [String: Any] = ["sourceGeneration": UInt64(7), "configVersion": UInt64(13),
            "overlayInputEstimateFPS": 120.1, "overlayPresentedFPS": 119.9, "estimatedRequestedFPS": 240.2,
            "rateKind": "multiplier", "rateMultiplier": 2, "requestedFPSIsEstimated": true,
            "displayRefreshHz": 120.0, "nativeBudgetActive": true]
        func text(_ s: [String: Any] = stats, _ now: Double = 10, _ generation: UInt64 = 7,
                  _ config: UInt64 = 13, _ running: Bool = true, _ paused: Bool = false,
                  _ committed: Bool = true, _ interpolation: Bool = true) -> String {
            LiveFPSOverlay.text(stats: s, now: now, receipt: 9, generation: generation, config: config,
                running: running, paused: paused, committed: committed, interpolation: interpolation,
                canObserve: true, outputObservable: true, chinese: true)
        }
        let current = text()
        precondition(current.contains("内容≈ 120.1") && current.contains("目标≈ 240.2 (X2)"))
        precondition(current.contains("呈现 119.9 FPS") && current.contains("屏幕 120 Hz") && current.contains("原生直通"))
        for stale in [text(stats, 11), text(stats, 10, 8), text(stats, 10, 7, 14),
                      text(stats, 10, 7, 13, false), text(stats, 10, 7, 13, true, true)] {
            precondition(!stale.contains("240.2") && !stale.contains("X2") && !stale.contains("原生直通"))
        }
        precondition(!text(stats, 10, 7, 13, true, false, false).contains("240.2"))
        precondition(!text(stats, 10, 7, 13, true, false, true, false).contains("原生直通"))
        func native(_ s: [String: Any] = stats, _ now: Double = 10, _ generation: UInt64 = 7,
                    _ config: UInt64 = 13, _ running: Bool = true, _ paused: Bool = false, _ pending: Bool = false) -> Bool {
            LiveRuntimeStatus.nativePassthroughIsCurrent(stats: s, now: now, receipt: 9, generation: generation,
                config: config, running: running, paused: paused, committed: true, interpolation: true, pending: pending)
        }
        let warning = LiveRuntimeStatus.interactiveBudgetWarning
        precondition(native() && LiveRuntimeStatus.shouldClearDisplayedWarning(warning, localizedWarning: warning, nativeCurrent: native()))
        precondition(!LiveRuntimeStatus.shouldClearDisplayedWarning("来源中断", localizedWarning: warning, nativeCurrent: native()))
        precondition(!native(stats, 11) && !native(stats, 10, 8) && !native(stats, 10, 7, 14))
        precondition(!native(stats, 10, 7, 13, false) && !native(stats, 10, 7, 13, true, true) && !native(stats, 10, 7, 13, true, false, true))
        var stale = stats; stale["snapshotStale"] = true
        precondition(!native(stale))
        print("R6 policy tests passed: election, contract guard, language choice without process restart, fresh 120→240 target and stale-state clearing")
    }
}
