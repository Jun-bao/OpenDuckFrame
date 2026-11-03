import AppKit

/// Modeless open panels need an explicit relationship to stay above their
/// player window when that window is clicked or ordered front again.
@MainActor
enum SPOpenPanelWindowOrder {
    /// Call after `begin` returns, once AppKit has presented the remote panel.
    static func attach(panel: NSWindow, to host: NSWindow) {
        guard panel !== host, panel.parent !== host else { return }
        detach(panel: panel)
        host.addChildWindow(panel, ordered: .above)
    }

    /// End the relationship on every completion and explicit dismissal so a
    /// cached panel can be presented again without retaining its old host.
    static func detach(panel: NSWindow) {
        panel.parent?.removeChildWindow(panel)
    }
}
