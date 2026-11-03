import Foundation
import IOKit.pwr_mgt

/// Playback edges only enqueue work. IOKit connection setup can take several
/// milliseconds, so it must not run between audio start and DisplayLink resume
/// (PlaybackReady). No timer or work on the frame/position hot path.
@MainActor
final class SPPlaybackSleepController {
    private let assertion: SPPlaybackSleepAssertion

    // A custom queue is a test seam and must also be serial.
    init(queue: DispatchQueue = SPPlaybackSleepAssertion.queue,
         createAssertion: @escaping @Sendable () -> IOPMAssertionID? = {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        // Resolve the product name on the worker too (OpenDuckFrame / Quick Look builds).
        let product = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        // Also prevents idle system sleep. Unlike declaring user activity, this
        // does not wake a sleeping display or interfere with explicit sleep.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "\(product) video playback" as CFString, &id)
        guard result == kIOReturnSuccess else {
            NSLog("[PlaybackSleep] Could not prevent idle display sleep: %d", result)
            return nil
        }
        return id
    }, releaseAssertion: @escaping @Sendable (IOPMAssertionID) -> Void = { id in
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            NSLog("[PlaybackSleep] Could not release idle display sleep assertion: %d", result)
        }
    }) {
        assertion = SPPlaybackSleepAssertion(queue: queue, create: createAssertion,
                                            release: releaseAssertion)
    }

    deinit {
        // Safe on any thread. Pending jobs retain only the worker; this final
        // release follows even a create still blocked in powerd. Never wait here.
        assertion.enqueue(holding: false)
    }

    func update(isPlaying: Bool, hasVideo: Bool) {
        assertion.enqueue(holding: isPlaying && hasVideo)
    }

    /// Explicit close/teardown also covers paths without a final state callback.
    func stop() {
        assertion.enqueue(holding: false)
    }
}

/// One owner per player; macOS combines claims across windows/processes.
/// Sendable because assertionID and both injected operations are used only on
/// the serial queue. Enqueued jobs retain this worker until cleanup completes.
private final class SPPlaybackSleepAssertion: @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.openduckframe.playback-sleep", qos: .utility)
    private let queue: DispatchQueue
    private let create: @Sendable () -> IOPMAssertionID?
    private let release: @Sendable (IOPMAssertionID) -> Void
    private var assertionID: IOPMAssertionID?

    init(queue: DispatchQueue, create: @escaping @Sendable () -> IOPMAssertionID?,
         release: @escaping @Sendable (IOPMAssertionID) -> Void) {
        self.queue = queue
        self.create = create
        self.release = release
    }

    func enqueue(holding: Bool) {
        queue.async { [self] in
            if holding {
                // Failed acquisition owns nothing; even another playing update
                // may retry. Successful repeated requests stay idempotent.
                if assertionID == nil { assertionID = create() }
            } else if let id = assertionID {
                assertionID = nil
                release(id)
            }
        }
    }
}
