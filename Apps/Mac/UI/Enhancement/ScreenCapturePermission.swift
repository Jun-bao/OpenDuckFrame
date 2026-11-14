import CoreGraphics

/// One permission request per app session, shared by all custom window-list entry points.
@MainActor
final class ScreenCapturePermission {
    static let shared = ScreenCapturePermission()

    private let preflight: () -> Bool
    private let request: () -> Bool
    private var requested = false

    init(preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         request: @escaping () -> Bool = CGRequestScreenCaptureAccess) {
        self.preflight = preflight
        self.request = request
    }

    var hasAccess: Bool { preflight() }

    func ensureAccess() -> Bool {
        if preflight() { return true }
        if !requested {
            // Mark before showing the system prompt: AppKit can re-enter while it is open.
            requested = true
            _ = request()
        }
        return preflight()
    }
}
