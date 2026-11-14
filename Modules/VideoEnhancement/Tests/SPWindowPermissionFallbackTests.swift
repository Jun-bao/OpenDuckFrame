import AppKit
import ScreenCaptureKit

// The workbench supplies its own localization helper in the app target.
enum EnhancementText {
    static func t(_ english: String, _ chinese: String) -> String { chinese }
}

@main
struct WindowPermissionFallbackTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        guard #available(macOS 15.2, *) else {
            print("System picker fallback requires macOS 15.2; skipped on this OS")
            return
        }

        var systemRequests = 0
        var pickerRequests = 0
        let permission = ScreenCapturePermission(preflight: { false }, request: {
            systemRequests += 1
            return false
        })
        let list = WindowSelectionList(permission: permission, selectUsingSystemPicker: {
            pickerRequests += 1
        }, select: { _ in
            preconditionFailure("The fallback must not choose a window itself")
        })

        // Automatic loading does not prompt; explicit refresh offers the
        // system picker without repeatedly requesting full recording access.
        list.reloadWindows()
        precondition(systemRequests == 0)
        guard let refresh = list.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "刷新列表" }) else {
            preconditionFailure("Refresh button is missing")
        }
        refresh.performClick(nil)
        refresh.performClick(nil)
        precondition(pickerRequests == 2, "Each explicit refresh must open the picker")
        precondition(systemRequests == 0, "Refresh must not request global access")
        let footer = list.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(footer.contains { $0.contains("弹窗") && $0.contains("刷新列表") })
        print("Window permission fallback tests passed")
    }
}
