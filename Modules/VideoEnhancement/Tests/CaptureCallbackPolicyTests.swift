import Foundation
import ScreenCaptureKit

@main struct CaptureCallbackPolicyTests {
    static func main() {
        precondition(CaptureCallbackPolicy.isRawCadenceEvidence(status: .complete, valid: true, dataReady: true))
        for status: SCFrameStatus? in [nil, .idle, .blank, .suspended, .stopped, .started] {
            precondition(!CaptureCallbackPolicy.isRawCadenceEvidence(status: status, valid: true, dataReady: true))
        }
        precondition(!CaptureCallbackPolicy.isRawCadenceEvidence(status: .complete, valid: false, dataReady: true))
        precondition(!CaptureCallbackPolicy.isRawCadenceEvidence(status: .complete, valid: true, dataReady: false))
        let binding = CaptureStreamBinding(), old = NSObject(), next = NSObject()
        binding.activate(old, generation: 1)
        let delayed = binding.snapshot(old)
        precondition(delayed == 1)
        binding.activate(next, generation: 2)
        var oldEmitted = false
        precondition(!binding.withCurrent(old, generation: delayed!, { oldEmitted = true }) && !oldEmitted)
        var currentEmitted = false
        precondition(binding.snapshot(old) == nil && binding.snapshot(next) == 2)
        precondition(binding.withCurrent(next, generation: 2, { currentEmitted = true }) && currentEmitted)
        binding.retire(); precondition(binding.snapshot(next) == nil)
        print("{\"ok\":true,\"scope\":\"production callback status policy and atomic stream binding, simulated object identities\"}")
    }
}
