#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -pedantic -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPRateBudgetTests.cpp" -o "$TEST_DIR/rate-budget-tests"
"$TEST_DIR/rate-budget-tests"
cat > "$TEST_DIR/RateBudgetHUDTests.swift" <<'SWIFT'
import Foundation
@main struct RateBudgetHUDTests {
    static func main() {
        var stats: [String: Any] = [
            "sourceGeneration": UInt64(7), "configVersion": UInt64(13),
            "overlayInputEstimateFPS": 24.0, "overlayPresentedFPS": 48.0,
            "estimatedRequestedFPS": 72.0, "rateKind": "multiplier", "rateMultiplier": 3,
            "rateRequestedMultiplier": 3, "rateEffectiveMultiplier": 2,
            "rateBudgetPassthrough": false, "requestedFPSIsEstimated": true,
            "displayRefreshHz": 120.0, "nativeBudgetActive": false
        ]
        func render(_ chinese: Bool = true, now: Double = 10, running: Bool = true,
                    paused: Bool = false, generation: UInt64 = 7, config: UInt64 = 13) -> String {
            LiveFPSOverlay.text(stats: stats, now: now, receipt: 9, generation: generation,
                config: config, running: running, paused: paused, committed: true,
                interpolation: true, canObserve: true, outputObservable: true, chinese: chinese)
        }
        func check(_ ok: Bool, _ message: String) {
            if !ok { print("FAIL HUD: " + message); exit(1) }
        }
        let down = render()
        check(down.contains("目标≈ 72.0 (X3→X2)") && down.contains(" · 算力受限"), "x3→x2 target and status")
        check(render(false).contains("Target≈ 72.0 (X3→X2)") && render(false).contains(" · Limited by compute"), "English fallback")
        for stale in [render(now: 11), render(running: false), render(paused: true), render(generation: 8), render(config: 14)] {
            check(!stale.contains("→X") && !stale.contains("算力受限"), "stale fallback must clear")
        }
        stats["rateMultiplier"] = 2; stats["rateRequestedMultiplier"] = 2
        stats["rateEffectiveMultiplier"] = 1; stats["rateBudgetPassthrough"] = true
        stats["estimatedRequestedFPS"] = 120.0; stats["overlayInputEstimateFPS"] = 60.0
        let bypass = render()
        check(bypass.contains("120.0 (X2→X1)") && bypass.contains("算力受限") && !bypass.contains("原生直通"), "compute bypass label")
        stats["nativeBudgetActive"] = true
        check(render().contains("原生直通") && !render().contains("算力受限") && !render().contains("→X"), "native path has original label")
        stats["nativeBudgetActive"] = false; stats["rateEffectiveMultiplier"] = 2
        stats["rateBudgetPassthrough"] = false
        check(render().contains("120.0 (X2)") && !render().contains("算力受限"), "full rate keeps previous label")
        stats.removeValue(forKey: "rateRequestedMultiplier"); stats.removeValue(forKey: "rateEffectiveMultiplier")
        check(render().contains("120.0 (X2)"), "legacy snapshots remain supported")
        print("PASS HUD: requested target, effective multiplier, x1, stale state, English and native passthrough")
    }
}
SWIFT
xcrun swiftc -parse-as-library "$ROOT/Apps/Mac/UI/Enhancement/LiveFPSOverlay.swift" \
  "$TEST_DIR/RateBudgetHUDTests.swift" -o "$TEST_DIR/rate-budget-hud-tests"
"$TEST_DIR/rate-budget-hud-tests"
