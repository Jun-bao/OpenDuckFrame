import Foundation

// Election never depends on mutable AppKit launch state: a relay can itself
// finish launching while it is still handing off to the actual primary.
enum SingleInstancePolicy {
    struct Candidate: Equatable {
        let pid: Int32
        let start: TimeInterval?
    }

    static func winner(_ candidates: [Candidate]) -> Candidate? {
        // If any process time is unavailable, use PID consistently for the
        // whole candidate set rather than ranking a partial timestamp list.
        let useStart = candidates.allSatisfy { $0.start != nil }
        return candidates.min { a, b in
            if useStart, let x = a.start, let y = b.start, x != y { return x < y }
            return a.pid < b.pid
        }
    }

    static func preferredPeer(_ candidates: [Candidate], ownPID: Int32) -> Candidate? {
        guard candidates.contains(where: { $0.pid == ownPID }),
              let selected = winner(candidates), selected.pid != ownPID else { return nil }
        return selected
    }

    static func isContract(_ arguments: [String]) -> Bool {
        let flags: Set<String> = ["--khua-enhancement-selftest", "--khua-session-contract", "--khua-engine-probe",
            "--khua-sr-pipeline-contract", "--khua-video-sr-pipeline-contract", "--khua-anime4k-pipeline-contract",
            "--khua-realcugan-pipeline-contract"]
        return arguments.contains { flags.contains($0) }
    }
}
