import Foundation
import ScreenCaptureKit

// Stream identity and generation are one atomic binding. Callers hold the
// lock only while emitting metadata or admitting an owned buffer, never while
// copying a borrowed surface.
final class CaptureStreamBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ObjectIdentifier?
    private var generation: UInt64 = 0
    func activate(_ stream: AnyObject, generation: UInt64) {
        lock.lock(); identity = ObjectIdentifier(stream); self.generation = generation; lock.unlock()
    }
    func retire() { lock.lock(); identity = nil; lock.unlock() }
    func snapshot(_ stream: AnyObject) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return identity == ObjectIdentifier(stream) ? generation : nil
    }
    func withCurrent(_ stream: AnyObject, generation: UInt64, _ emit: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard identity == ObjectIdentifier(stream), self.generation == generation else { return false }
        emit(); return true
    }
}

enum CaptureCallbackPolicy {
    static func isRawCadenceEvidence(status: SCFrameStatus?, valid: Bool, dataReady: Bool) -> Bool {
        valid && dataReady && status == .complete
    }
}
