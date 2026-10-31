import AppKit

enum WorkbenchFileDisplayStep: Equatable { case wait, unavailable, exitFullscreen, move, enterFullscreen, done }

enum WorkbenchFileDisplayPolicy {
    static func next(screenExists: Bool, visible: Bool, miniaturized: Bool, transitioning: Bool,
                     fullscreen: Bool, sameScreen: Bool, wantsFullscreen: Bool) -> WorkbenchFileDisplayStep {
        guard screenExists, visible, !miniaturized else { return .unavailable }
        if transitioning { return .wait }
        if fullscreen && (!wantsFullscreen || !sameScreen) { return .exitFullscreen }
        if !fullscreen && !sameScreen { return .move }
        if !fullscreen && wantsFullscreen { return .enterFullscreen }
        return .done
    }
}

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private struct FileOutputRequest {
        let id = UUID()
        let displayID: UInt32
        let fullscreen: Bool
        let completion: (Bool, String) -> Void
    }
    private enum FileWindowTransition { case entering, exiting }
    private var fileOutputRequest: FileOutputRequest?
    private var fileWindowTransition: FileWindowTransition?
    private let playerVC: PlayerViewController
    var playerViewController: PlayerViewController { playerVC }

    // Empty windows use the welcome view's fixed 640x360 size. Cold launches
    // and Dock reopens return to this size; opening media lets
    // resizeWindowToVideoAspect choose a larger width within the screen bounds.
    static let defaultContentSize = NSSize(width: 640, height: 360)

    static func mediaContentSize(on screen: NSScreen?) -> NSSize {
        let vis = (screen ?? NSScreen.main)?.visibleFrame.size ?? .zero
        return LaunchWindowSize.mediaContentSize(visible: vis)
    }

    private static let audioOnlyExtensions: Set<String> =
        Set(SPDefaultPlayer.formats.filter { !$0.isVideo }.flatMap { $0.exts })

    init(deferCore: Bool = false, mediaSize: Bool = false) {
        let contentSize = mediaSize ? Self.mediaContentSize(on: NSScreen.main)
                                    : Self.defaultContentSize

        playerVC = PlayerViewController(deferCoreCreation: deferCore,
                                        contentSize: contentSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        spLaunchMark("NSWindow 已建")

        window.acceptsMouseMovedEvents = true
        // The video and empty scrim can drag the window without requiring the
        // title bar. Interactive controls opt out: buttons and sliders already
        // do so, the timeline overrides mouseDownCanMoveWindow, and transient
        // overlays pass hit testing through.
        window.isMovableByWindowBackground = true

        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.center()
        // Use the workbench language setting without loading the localization
        // catalog before the first window appears. Idle states use the catalog.
        window.title = EnhancementText.t("ChuanFlow", "小川帧流")
        window.minSize = NSSize(width: 480, height: 270)
        window.isReleasedWhenClosed = false

        window.isRestorable = false
        spLaunchMark("窗口属性已设")
        super.init(window: window)
        window.contentViewController = playerVC
        spLaunchMark("contentVC 已挂（含 loadView）")
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PlayerWindowController: no coder path") }

    // AppDelegate owns multi-window close semantics: destroy non-final windows
    // and return the final one to the welcome state. Without a callback, keep
    // the conservative single-window behavior of stopping and showing welcome.
    var onWillClose: (@MainActor (PlayerWindowController) -> Void)?

    func windowWillClose(_ notification: Notification) {
        cancelWorkbenchFileOutput()
        if let onWillClose {
            onWillClose(self)
        } else {
            playerVC.handleWindowClose()
        }
    }

    private func fileOutputScreen(_ displayID: UInt32) -> NSScreen? {
        if displayID == 0 { return NSScreen.screens.first ?? NSScreen.main }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }

    func applyWorkbenchFileOutput(displayID: UInt32, fullscreen: Bool, completion: @escaping (Bool, String) -> Void) {
        let previous = fileOutputRequest
        fileOutputRequest = FileOutputRequest(displayID: displayID, fullscreen: fullscreen, completion: completion)
        previous?.completion(false, "新的输出设置替代了上一次请求。")
        advanceWorkbenchFileOutput()
    }

    func cancelWorkbenchFileOutput() {
        let previous = fileOutputRequest
        fileOutputRequest = nil
        previous?.completion(false, "输出切换已取消。")
    }

    private func finishWorkbenchFileOutput(_ ok: Bool, _ message: String) {
        let request = fileOutputRequest
        fileOutputRequest = nil
        request?.completion(ok, message)
    }

    private func advanceWorkbenchFileOutput() {
        guard let request = fileOutputRequest else { return }
        guard let window else { finishWorkbenchFileOutput(false, "播放器窗口不可用。"); return }
        let screen = fileOutputScreen(request.displayID)
        func screenNumber(_ screen: NSScreen?) -> UInt32? {
            (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let same = screen != nil && screenNumber(window.screen) == screenNumber(screen)
        switch WorkbenchFileDisplayPolicy.next(screenExists: screen != nil, visible: window.isVisible,
                miniaturized: window.isMiniaturized, transitioning: fileWindowTransition != nil,
                fullscreen: window.styleMask.contains(.fullScreen), sameScreen: same, wantsFullscreen: request.fullscreen) {
        case .wait: return
        case .unavailable:
            finishWorkbenchFileOutput(false, screen == nil ? "所选显示器不可用。" : "播放器窗口不可见或已最小化。")
        case .exitFullscreen:
            fileWindowTransition = .exiting; window.toggleFullScreen(nil)
        case .move:
            guard let screen else { finishWorkbenchFileOutput(false, "所选显示器不可用。"); return }
            let area = screen.visibleFrame
            let width = min(window.frame.width, area.width), height = min(window.frame.height, area.height)
            guard width > 0, height > 0 else { finishWorkbenchFileOutput(false, "所选显示器尺寸不可用。"); return }
            window.setFrame(NSRect(x: area.midX-width/2, y: area.midY-height/2, width: width, height: height), display: true)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, let pending = self.fileOutputRequest, pending.id == request.id else { return }
                guard let actual = window.screen, let target = self.fileOutputScreen(pending.displayID),
                      screenNumber(actual) == screenNumber(target) else {
                    self.finishWorkbenchFileOutput(false, "播放器无法移动到所选显示器。"); return
                }
                self.advanceWorkbenchFileOutput()
            }
        case .enterFullscreen:
            fileWindowTransition = .entering; window.toggleFullScreen(nil)
        case .done: finishWorkbenchFileOutput(true, "")
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fileWindowTransition = .entering }
    func windowDidEnterFullScreen(_ notification: Notification) { fileWindowTransition = nil; advanceWorkbenchFileOutput() }
    func windowWillExitFullScreen(_ notification: Notification) { fileWindowTransition = .exiting }
    func windowDidExitFullScreen(_ notification: Notification) { fileWindowTransition = nil; advanceWorkbenchFileOutput() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fileWindowTransition = nil; finishWorkbenchFileOutput(false, "播放器无法进入全屏。") }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fileWindowTransition = nil; finishWorkbenchFileOutput(false, "播放器无法退出全屏。") }

    func open(url: URL) {

        prepareContentSizeBeforeFirstShow(for: url)

        window?.makeKeyAndOrderFront(nil)
        playerVC.open(url: url)
    }

    private func prepareContentSizeBeforeFirstShow(for url: URL) {
        guard let window, !window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let target = Self.audioOnlyExtensions.contains(url.pathExtension.lowercased())
            ? Self.defaultContentSize
            : Self.mediaContentSize(on: window.screen)
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - target.width) >= 1
                || abs(current.height - target.height) >= 1 else { return }

        if NSApp.windows.contains(where: { $0 !== window && $0.isVisible }) {
            window.spSetContentSizeKeepingCenter(target)
        } else {
            window.setContentSize(target)
            window.center()
        }
    }

    func showWindowForReopen() {
        guard let window else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        if !playerVC.hasOpenMedia, !window.styleMask.contains(.fullScreen) {
            // Closing already restores this size. Avoid an equal-size AppKit
            // mutation; exact comparison still repairs fractional mismatches.
            let current = window.contentRect(forFrameRect: window.frame).size
            if current != Self.defaultContentSize {
                window.setContentSize(Self.defaultContentSize)
            }
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        playerVC.noteWindowReexposed() // Retry work suppressed while the window was closed.
        if spDebugEnabled {
            NSLog("[UI] 热重开亮相耗时 %.1fms（进程常驻，Dock 点击→窗口上屏）",
                  (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
    }
}

extension NSWindow {

    func spSetContentSizeKeepingCenter(_ size: NSSize) {
        let before = frame
        setContentSize(size)
        var origin = NSPoint(x: (before.midX - frame.width / 2).rounded(),
                             y: (before.midY - frame.height / 2).rounded())
        if let vis = (screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(vis.minX, min(origin.x, vis.maxX - frame.width))
            origin.y = max(vis.minY, min(origin.y, vis.maxY - frame.height))
        }
        setFrameOrigin(origin)
    }
}
