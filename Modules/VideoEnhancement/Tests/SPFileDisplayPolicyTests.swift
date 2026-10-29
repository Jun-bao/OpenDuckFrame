import AppKit

@main struct SPFileDisplayPolicyTests {
    static func main() {
        func step(_ exists: Bool = true, _ visible: Bool = true, _ mini: Bool = false, _ transition: Bool = false,
                  _ full: Bool = false, _ same: Bool = true, _ wantsFull: Bool = false) -> WorkbenchFileDisplayStep {
            WorkbenchFileDisplayPolicy.next(screenExists: exists, visible: visible, miniaturized: mini, transitioning: transition,
                                           fullscreen: full, sameScreen: same, wantsFullscreen: wantsFull)
        }
        let tests: [(String, WorkbenchFileDisplayStep, WorkbenchFileDisplayStep)] = [
            ("screen disappeared", step(false), .unavailable),
            ("closed", step(true, false), .unavailable),
            ("minimized", step(true, true, true), .unavailable),
            ("wait for animation", step(true, true, false, true), .wait),
            ("exit fullscreen", step(true, true, false, false, true), .exitFullscreen),
            ("exit to change screen", step(true, true, false, false, true, false, true), .exitFullscreen),
            ("move to chosen screen", step(true, true, false, false, false, false, true), .move),
            ("enter fullscreen", step(true, true, false, false, false, true, true), .enterFullscreen),
            ("already fullscreen", step(true, true, false, false, true, true, true), .done),
            ("already windowed", step(), .done)
        ]
        let failed = tests.filter { $0.1 != $0.2 }
        for test in failed { fputs("FAIL \(test.0): \(test.1), expected \(test.2)\n", stderr) }
        print("{\"ok\":\(failed.isEmpty),\"cases\":\(tests.count),\"scope\":\"pure output-window state policy; no NSWindow or GUI\"}")
        if !failed.isEmpty { exit(1) }
    }
}
