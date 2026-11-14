import AppKit
import ScreenCaptureKit

// The workbench supplies its own localization helper in the app target.
enum EnhancementText {
    static func t(_ english: String, _ chinese: String) -> String { chinese }
}

@main
struct WindowPermissionPromptTests {
    @MainActor static func textFields(in view: NSView) -> [String] {
        let ownText = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return ownText + view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        var systemRequests = 0
        var refresh: NSButton?
        let permission = ScreenCapturePermission(preflight: { false }, request: {
            systemRequests += 1
            // A system dialog may re-enter the main run loop.
            refresh?.performClick(nil)
            return false
        })
        let list = WindowSelectionList(permission: permission) { _ in
            preconditionFailure("Refreshing must not choose a window")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = list

        // Background refresh does not request permission. A user click asks
        // once, then presents an explanation when the system denies access.
        list.reloadWindows()
        precondition(systemRequests == 0)
        refresh = list.subviews.compactMap { $0 as? NSButton }.first { $0.title == "刷新列表" }
        guard let refresh else { preconditionFailure("Refresh button is missing") }
        refresh.performClick(nil)
        precondition(systemRequests == 1, "The user gesture must request recording access")
        guard let sheet = window.attachedSheet else { preconditionFailure("Denied access needs a visible explanation") }
        guard let sheetContent = sheet.contentView else { preconditionFailure("The permission explanation is missing") }
        let explanation = textFields(in: sheetContent).joined(separator: " ")
        precondition(explanation.contains("开关已打开") && explanation.contains("移除旧的 OpenDuckFrame") &&
                     explanation.contains("添加当前应用") && explanation.contains(Bundle.main.bundleURL.path),
                     "The explanation must recover a stale permission entry for the current app")
        refresh.performClick(nil)
        precondition(systemRequests == 1 && window.attachedSheet === sheet, "Repeated clicks must not stack prompts")
        let footer = list.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(footer.contains { $0.contains("屏幕录制权限") && $0.contains("刷新列表") })
        window.endSheet(sheet, returnCode: .cancel)

        // When the system grants the request, the same button proceeds to
        // refresh the list without an app-owned denial sheet.
        var granted = false
        var grantRequests = 0
        let grant = ScreenCapturePermission(preflight: { granted }, request: {
            grantRequests += 1
            granted = true
            return true
        })
        let grantedList = WindowSelectionList(permission: grant) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        let grantedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        grantedWindow.contentView = grantedList
        guard let grantedRefresh = grantedList.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "刷新列表" }) else {
            preconditionFailure("Refresh button is missing")
        }
        grantedRefresh.performClick(nil)
        let grantedFooter = grantedList.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(grantRequests == 1 && grantedWindow.attachedSheet == nil)
        precondition(grantedFooter.contains("正在获取窗口…"), "A granted request must refresh the list")

        // Granting permission directly in System Settings must also refresh on
        // return, even when the app did not open System Settings itself.
        var externallyGranted = false
        var externalRequests = 0
        let externalPermission = ScreenCapturePermission(preflight: { externallyGranted }, request: {
            externalRequests += 1
            return false
        })
        let externalList = WindowSelectionList(permission: externalPermission) { _ in
            preconditionFailure("Refreshing must not select a window")
        }
        externalList.reloadWindows()
        externallyGranted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let externalFooter = externalList.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        precondition(externalRequests == 0, "Returning to the app must not request permission")
        precondition(externalFooter.contains("正在获取窗口…"), "A newly granted permission must refresh the list")
        print("Window permission prompt tests passed")
    }
}
