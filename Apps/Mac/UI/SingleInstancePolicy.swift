import Foundation

// Election never depends on mutable AppKit launch state: a relay can itself
// finish launching while it is still handing off to the actual primary.
enum SingleInstancePolicy {
    static func matchesProductMetadata(_ product: String?, _ executable: String?) -> Bool {
        product == "OpenDuckFrame" && executable == "OpenDuckFrame"
    }

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
        let flags: Set<String> = ["--odf-enhancement-selftest", "--odf-session-contract", "--odf-engine-probe",
            "--odf-sr-pipeline-contract", "--odf-video-sr-pipeline-contract", "--odf-anime4k-pipeline-contract",
            "--odf-realcugan-pipeline-contract"]
        return arguments.contains { flags.contains($0) }
    }
}
