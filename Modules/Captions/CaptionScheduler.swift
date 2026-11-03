import Foundation

// Pure scheduling policy. Jobs advance through consecutive 30-second cells
// from the beginning, normally four cells per job, with overlap on both sides.
// Segment midpoints determine overlap ownership. Playback seeks affect I/O
// admission only; completed-cell count is the scheduling frontier.

struct CaptionJob: Equatable, Sendable {
    var firstCell: Int
    var cellCount: Int
    var cellSeconds: Double
    var totalSeconds: Double

    var start: Double { Double(firstCell) * cellSeconds }
    var end: Double { min(totalSeconds, Double(firstCell + cellCount) * cellSeconds) }
    var cells: Range<Int> { firstCell..<(firstCell + cellCount) }
}

enum CaptionScheduler {
    static let cellSeconds = 30.0
    static let steadyCells = 4          // 120 s
    static let overlapSeconds = 5.0

    static func cellCount(totalSeconds: Double, cellSeconds: Double = cellSeconds) -> Int {
        guard totalSeconds.isFinite, totalSeconds > 0, cellSeconds.isFinite, cellSeconds > 0,
              let count = Int(exactly: (totalSeconds / cellSeconds).rounded(.up)), count > 0 else { return 0 }
        return count
    }

    /// Return the next consecutive job, truncated at EOF, or nil when complete.
    /// doneCells is the number of completed cells from the beginning.
    static func nextJob(doneCells: Int, totalSeconds: Double,
                        cellSeconds: Double = cellSeconds,
                        steadyCells: Int = steadyCells) -> CaptionJob? {
        let n = cellCount(totalSeconds: totalSeconds, cellSeconds: cellSeconds)
        guard n > 0, doneCells < n else { return nil }
        let f = max(0, doneCells)
        return CaptionJob(firstCell: f, cellCount: min(max(1, steadyCells), n - f), cellSeconds: cellSeconds,
                          totalSeconds: totalSeconds)
    }

    /// Assign an overlapping recognition segment by its midpoint in [start, end).
    static func owns(job: CaptionJob, segmentStart: Double, segmentEnd: Double) -> Bool {
        guard segmentStart.isFinite, segmentEnd.isFinite, segmentEnd > segmentStart else { return false }
        let mid = segmentStart + (segmentEnd - segmentStart) / 2
        if job.firstCell == 0, mid < job.end { return true } // No preceding job exists at the start.
        if job.end >= job.totalSeconds - 1e-6, mid >= job.start { return true } // The final job owns the trailing overlap.
        return mid >= job.start && mid < job.end
    }

    /// Commit a cue only once its end plus the lookahead margin is behind the
    /// completed frontier, so later words cannot change its segmentation.
    static func committable(start: Double, end: Double, margin: Double, doneCells: Int,
                            totalSeconds: Double, cellSeconds: Double = cellSeconds) -> Bool {
        let n = cellCount(totalSeconds: totalSeconds, cellSeconds: cellSeconds)
        guard n > 0, doneCells > 0, start.isFinite, end.isFinite, start >= 0, end > start,
              margin.isFinite, margin >= 0,
              let last = Int(exactly: ((end + margin) / cellSeconds).rounded(.towardZero)) else { return false }
        return min(n - 1, last) < doneCells
    }
}

/// End-to-end job throughput, including decoding, ASR, translation and the
/// existing inter-job delay. Updated only on the caption worker, once per job.
struct CaptionWorkEstimate {
    private(set) var secondsPerCell: Double?

    mutating func record(cells: Int, elapsed: Double) {
        guard cells > 0, elapsed.isFinite, elapsed > 0 else { return }
        let sample = elapsed / Double(cells)
        secondsPerCell = secondsPerCell.map { $0 * 0.7 + sample * 0.3 } ?? sample
    }

    func remaining(cells: Int) -> Double? {
        guard cells >= 0, let secondsPerCell else { return nil }
        let result = Double(cells) * secondsPerCell
        return result.isFinite ? result : nil
    }
}

/// A stable user-visible pause, not a deadline that overrides playback demand.
/// Polling stays on the existing reader worker; only transitions reach the UI.
struct CaptionPlaybackWaitState {
    private var beganAt: Double?
    private(set) var isWaiting = false

    mutating func update(paused: Bool, now: Double) -> Bool? {
        if paused {
            if beganAt == nil { beganAt = now }
            if !isWaiting, now - (beganAt ?? now) >= 1 {
                isWaiting = true
                return true
            }
        } else {
            beganAt = nil
            if isWaiting {
                isWaiting = false
                return false
            }
        }
        return nil
    }
}
