#!/bin/bash
# Isolated guide behavior and AppKit controls; no user preferences are changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import AppKit
@MainActor enum EnhancementText {
    static var chinese = true
    static func t(_ en: String, _ zh: String) -> String { chinese ? zh : en }
}
@main struct GuideTest {
    @MainActor static func main() {
        _ = NSApplication.shared
        let name = "app.openduckframe.guide-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(WorkbenchGuidePreference.shouldShow(in: defaults))
        WorkbenchGuidePreference.complete(in: defaults)
        precondition(!WorkbenchGuidePreference.shouldShow(in: defaults))
        precondition(WorkbenchGuideStep.source.next == .frameGeneration)
        precondition(WorkbenchGuideStep.frameGeneration.next == .start)
        precondition(WorkbenchGuideStep.start.next == nil)
        var skipped = false
        var advanced = false
        func check(step: WorkbenchGuideStep, kind: String, running: Bool, text: String) {
            let content = WorkbenchGuideContent(step: step, sourceKind: kind, alreadyRunning: running,
                skip: { skipped = true }, advance: { advanced = true })
            let view = content.view
            let strings = view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            precondition(strings.contains(where: { $0.contains(text) }), "Missing \(text): \(strings)")
            precondition(view.subviews.contains(where: { ($0 as? NSButton)?.identifier?.rawValue == "workbench.guide.skip" }))
            precondition(view.subviews.contains(where: { ($0 as? NSButton)?.identifier?.rawValue == "workbench.guide.next" }))
        }
        check(step: .source, kind: "window", running: false, text: "选择画面来源")
        check(step: .frameGeneration, kind: "window", running: false, text: "确认帧生成")
        check(step: .start, kind: "window", running: false, text: "延迟增强")
        check(step: .start, kind: "window", running: false, text: "指定窗口增强")
        check(step: .start, kind: "file", running: false, text: "点击开始增强")
        check(step: .start, kind: "display", running: false, text: "点击开始增强")
        check(step: .start, kind: "file", running: true, text: "点击关闭增强")
        let content = WorkbenchGuideContent(step: .source, sourceKind: "window", alreadyRunning: false,
            skip: { skipped = true }, advance: { advanced = true })
        let buttons = content.view.subviews.compactMap { $0 as? NSButton }
        buttons.first(where: { $0.identifier?.rawValue == "workbench.guide.skip" })!.performClick(nil)
        buttons.first(where: { $0.identifier?.rawValue == "workbench.guide.next" })!.performClick(nil)
        precondition(skipped && advanced)
        EnhancementText.chinese = false
        check(step: .start, kind: "window", running: false, text: "Delayed Enhancement")
        check(step: .start, kind: "window", running: false, text: "Enhance Selected Window")
        print("Guide preference, steps, actions and source-specific Chinese/English text passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library "$ROOT/Apps/Mac/UI/Enhancement/WorkbenchOnboarding.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
