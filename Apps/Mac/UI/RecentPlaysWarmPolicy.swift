import Foundation

/// I/O-free bookkeeping for recent-file storage warming.
///
/// Path claims prevent duplicate workers; volume claims prevent duplicate reads.
/// Resolve the real volume identity with statfs on each path's worker because a
/// disconnected mount can block. Claim the path before dispatch and the volume
/// after resolution, without inferring volume identity from path prefixes.
struct RecentWarmVolumeLedger {
    private(set) var inFlightPaths: Set<String> = []
    private(set) var volumeWarmedAt: [String: TimeInterval] = [:]

    /// Allow one worker per path. Skip repeated requests while a potentially
    /// blocking statfs/open is in flight instead of queuing behind it.
    mutating func claimPath(_ path: String) -> Bool {
        guard !inFlightPaths.contains(path) else { return false }
        inFlightPaths.insert(path)
        return true
    }

    mutating func finishPath(_ path: String) {
        inFlightPaths.remove(path)
    }

    /// The first worker to resolve a volume records its wake claim immediately.
    /// The cooldown suppresses duplicate reads without periodically keeping
    /// storage awake.
    mutating func claimVolumeWake(key: String, now: TimeInterval,
                                  cooldown: TimeInterval) -> Bool {
        if let last = volumeWarmedAt[key], now - last < cooldown { return false }
        volumeWarmedAt[key] = now
        return true
    }

    /// Revoke a claim that yielded to playback before reading so the next
    /// warming request can retry without consuming the cooldown.
    mutating func revokeVolumeWake(key: String) {
        volumeWarmedAt.removeValue(forKey: key)
    }

    // MARK: - Per-volume read slots and latest hover candidates

    /// Active read intent per volume. Zero denotes a welcome-time wake read,
    /// which any hover intent can supersede. Sequence comparisons prevent late
    /// resolution of an older intent from interrupting a newer read.
    private(set) var volumeReadSeqInFlight: [String: UInt64] = [:]
    private(set) var pendingEntryByVolume: [String: RecentWarmCandidate] = [:]
    /// Resolved volume identities let the main-thread entry point refresh an
    /// intent even when that path already has a worker in flight.
    private(set) var volumeKeyByPath: [String: String] = [:]
    /// Latest intent per path in pointer-event order. Workers read this value
    /// when claiming a slot or registering a candidate, preserving repeat hover
    /// events that arrive while volume resolution is still in progress.
    private(set) var intentSeqByPath: [String: UInt64] = [:]
    private var intentCounter: UInt64 = 0

    /// Record a new hover intent for this path.
    mutating func noteIntent(forPath path: String) -> UInt64 {
        intentCounter += 1
        intentSeqByPath[path] = intentCounter
        return intentCounter
    }

    func intentSeq(forPath path: String) -> UInt64 {
        intentSeqByPath[path] ?? 0
    }

    mutating func noteVolumeKey(_ key: String, forPath path: String) {
        volumeKeyByPath[path] = key
    }

    func volumeKey(forPath path: String) -> String? {
        volumeKeyByPath[path]
    }

    /// Keep volume and intent caches aligned with the retained entry lanes.
    mutating func pruneVolumeKeys(keepingPaths paths: Set<String>) {
        volumeKeyByPath = volumeKeyByPath.filter { paths.contains($0.key) }
        intentSeqByPath = intentSeqByPath.filter { paths.contains($0.key) }
    }

    func isVolumeReadInFlight(key: String) -> Bool {
        volumeReadSeqInFlight[key] != nil
    }

    /// Serialize hover and welcome reads per volume to avoid competing seeks.
    /// Release the slot only when the worker exits; cancellation alone does not
    /// end an underlying system call. Keep the sequence for candidate ordering.
    mutating func claimVolumeRead(key: String, seq: UInt64) -> Bool {
        guard volumeReadSeqInFlight[key] == nil else { return false }
        volumeReadSeqInFlight[key] = seq
        return true
    }

    /// Retain only the newest candidate for a busy volume. An older intent
    /// cannot replace a newer candidate or interrupt a newer active read.
    mutating func notePendingEntry(key: String, path: String, seq: UInt64) {
        if let running = volumeReadSeqInFlight[key], running >= seq { return }
        if let current = pendingEntryByVolume[key], current.seq >= seq { return }
        pendingEntryByVolume[key] = RecentWarmCandidate(path: path, seq: seq)
    }

    /// Yield between chunks only to a newer intent for a different file on the
    /// same volume; a different path alone does not establish priority.
    func hasNewerCandidate(key: String, than path: String) -> Bool {
        guard let pending = pendingEntryByVolume[key],
              pending.path != path else { return false }
        return pending.seq > (volumeReadSeqInFlight[key] ?? 0)
    }

    /// Release the slot while retaining candidates for atomic handoff through
    /// relaunchDecision. Discard candidates older than the completed read, which
    /// can arrive during a claim transition after delayed volume resolution.
    mutating func releaseVolumeRead(key: String) {
        guard let finished = volumeReadSeqInFlight.removeValue(forKey: key)
        else { return }
        if let pending = pendingEntryByVolume[key], pending.seq < finished {
            pendingEntryByVolume.removeValue(forKey: key)
        }
    }

    /// Called under the warmer's lock to atomically check a candidate, claim its
    /// path lane, and remove it from the pending set. Every worker retries this
    /// handoff on exit. Retain candidates while their path or volume is busy;
    /// deliberately discard candidates whose path is cooling down.
    mutating func relaunchDecision(
        key: String, lanes: inout [String: OpenPanelWarmLanePolicy],
        now: TimeInterval, cooldown: TimeInterval
    ) -> RecentWarmRelaunchDecision {
        guard let pending = pendingEntryByVolume[key] else { return .none }
        guard volumeReadSeqInFlight[key] == nil else { return .volumeBusy }
        var lane = lanes[pending.path] ?? OpenPanelWarmLanePolicy()
        if lane.isInFlight { return .waitForWindDown }
        guard lane.claim(now: now, cooldown: cooldown) else {
            pendingEntryByVolume.removeValue(forKey: key)
            return .droppedCooldown
        }
        lanes[pending.path] = lane
        pendingEntryByVolume.removeValue(forKey: key)
        return .launch(path: pending.path, seq: pending.seq)
    }
}

struct RecentWarmCandidate: Equatable {
    let path: String
    let seq: UInt64
}

enum RecentWarmRelaunchDecision: Equatable {
    case launch(path: String, seq: UInt64)
    case waitForWindDown // Retain until the candidate's current worker exits.
    case volumeBusy      // Retain until the active volume read exits.
    case droppedCooldown // Deliberately throttle a path that is cooling down.
    case none
}
