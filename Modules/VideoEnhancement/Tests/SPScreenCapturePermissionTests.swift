import Foundation

@main
struct ScreenCapturePermissionTests {
    @MainActor static func main() {
        var allowed = false
        var requests = 0
        var gate: ScreenCapturePermission!
        gate = ScreenCapturePermission(preflight: { allowed }, request: {
            requests += 1
            // The system dialog can run a nested event loop and re-enter the caller.
            precondition(!gate.ensureAccess())
            return false
        })

        precondition(!gate.hasAccess)
        precondition(requests == 0, "Checking status alone must not request access")
        precondition(!gate.ensureAccess())
        for _ in 0..<20 { precondition(!gate.ensureAccess()) }
        precondition(requests == 1, "Repeated refreshes must not repeat the request")
        allowed = true
        precondition(gate.ensureAccess(), "A later system grant must be noticed")
        allowed = false
        precondition(!gate.ensureAccess())
        precondition(requests == 1, "Revocation must not restart the request loop")

        var alreadyAllowedRequests = 0
        let alreadyAllowed = ScreenCapturePermission(preflight: { true }, request: {
            alreadyAllowedRequests += 1
            return true
        })
        precondition(alreadyAllowed.ensureAccess())
        precondition(alreadyAllowedRequests == 0, "An authorized app must not request again")
        print("Screen capture permission tests passed")
    }
}
