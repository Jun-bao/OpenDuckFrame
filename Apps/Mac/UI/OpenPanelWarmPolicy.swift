import Foundation

/// One independently throttled lane in OpenPanelWarmer. Kept as a pure value
/// so the two-lane claim/finish semantics can be tested without AppKit or I/O.
struct OpenPanelWarmLanePolicy {
    private(set) var lastCompletedWorkAt: TimeInterval?
    private(set) var isInFlight = false

    mutating func claim(now: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard !isInFlight else { return false }
        if let lastCompletedWorkAt, now - lastCompletedWorkAt < cooldown {
            return false
        }
        isInFlight = true
        return true
    }

    mutating func finish(now: TimeInterval, performedWork: Bool) {
        guard isInFlight else { return }
        isInFlight = false
        if performedWork { lastCompletedWorkAt = now }
    }
}
