import Foundation

/// The hover request's 100ms trailing edge. Movement updates the latest intent
/// without allocating another Timer. Leading requests and commit remain owned
/// by PlayerViewController; this object never deduplicates completed targets.
@MainActor
final class SPTrailingPreviewRequest {
    typealias Schedule = (TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let send: (Double) -> Void
    private var timer: Timer?
    private var target: Double?
    private var deadline: TimeInterval = 0

    // Injectable clock/scheduler let tests use the same production state
    // machine without sleeping or starting an application/run loop.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = {
             Timer.scheduledTimer(withTimeInterval: $0, repeats: false, block: $1)
         },
         send: @escaping (Double) -> Void) {
        self.now = now
        self.schedule = schedule
        self.send = send
    }

    func submit(_ seconds: Double) {
        target = seconds
        deadline = now() + 0.100
        if timer == nil { arm(after: 0.100) }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
        deadline = 0
    }

    private func arm(after delay: TimeInterval) {
        timer = schedule(delay) { [weak self] fired in
            let firedID = ObjectIdentifier(fired)
            MainActor.assumeIsolated {
                guard let self, self.timer.map(ObjectIdentifier.init) == firedID else { return }
                self.timer = nil
                guard let target = self.target else { return }
                let remaining = self.deadline - self.now()
                if remaining > 0 {
                    self.arm(after: remaining) // No early-fire tolerance here.
                    return
                }
                self.target = nil // Clear before send: reentrant submit survives.
                self.deadline = 0
                self.send(target)
            }
        }
    }
}
