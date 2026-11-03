import Foundation

// Pure segmentation of timed words into translation sentences and subtitle
// lines. Sentence boundaries combine punctuation, pauses and recognition
// segment boundaries. Oversized sentences split at clause punctuation or the
// longest pause. Subtitle lines never cross sentence boundaries.

struct CaptionSegmentationPolicy: Equatable, Sendable {
    var script: CaptionScript
    /// Line length limit: Latin characters include spaces; CJK counts non-whitespace characters.
    var maxChars: Int
    var maxDuration: Double
    /// A pause at or above this threshold starts a new subtitle line.
    var gap: Double
    /// Pause threshold for starting a new sentence.
    var sentenceGap: Double
    var sentenceMaxDuration: Double
    var sentenceMaxChars: Int

    static func forScript(_ script: CaptionScript) -> CaptionSegmentationPolicy {
        switch script {
        case .latin:
            return CaptionSegmentationPolicy(script: .latin, maxChars: 84, maxDuration: 7.0, gap: 0.8,
                                             sentenceGap: 0.6, sentenceMaxDuration: 8.0, sentenceMaxChars: 168)
        case .cjk, .korean:
            // Use a shorter duration and pause budget for CJK reading.
            return CaptionSegmentationPolicy(script: script, maxChars: 36, maxDuration: 6.0, gap: 0.5,
                                             sentenceGap: 0.6, sentenceMaxDuration: 8.0, sentenceMaxChars: 72)
        }
    }
}

enum CaptionSegmenter {
    // MARK: Text joining

    static func joinWords(_ words: ArraySlice<CaptionWord>, script: CaptionScript) -> String {
        let parts = words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch script {
        case .latin, .korean: return parts.joined(separator: " ")
        case .cjk: return parts.joined()
        }
    }

    static func joinWords(_ words: [CaptionWord], script: CaptionScript) -> String {
        joinWords(words[...], script: script)
    }

    /// Latin line length includes inter-word spaces; CJK length excludes whitespace.
    static func length(_ words: ArraySlice<CaptionWord>, script: CaptionScript) -> Int {
        var n = 0
        var count = 0
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            n += wordLength(t, script: script)
            count += 1
        }
        if script == .latin, count > 1 { n += count - 1 }
        return n
    }

    private static func wordLength(_ text: String, script: CaptionScript) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve Korean word boundaries while retaining CJK reading-length budgets.
        return script == .korean ? trimmed.filter { !$0.isWhitespace }.count : trimmed.count
    }

    // MARK: Sentences

    private static func isBlank(_ w: CaptionWord) -> Bool {
        w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Group chronologically ordered words into translation sentences. Every
    /// nonempty word with valid timing is covered. wordRange indexes the original
    /// input, including intervening blank words that do not contribute text.
    static func groupSentences(_ words: [CaptionWord],
                               policy: CaptionSegmentationPolicy) -> [CaptionSentence] {
        let clean = words.indices.filter {
            let word = words[$0]
            return !isBlank(word) && word.start.isFinite && word.end.isFinite
                && word.start >= 0 && word.end > word.start
        }
        guard !clean.isEmpty else { return [] }
        // First pass: natural boundaries over the indices of nonempty words.
        var runs: [[Int]] = []
        var cur: [Int] = []
        for i in clean {
            if let p = cur.last {
                let prev = words[p], w = words[i]
                let boundary = CaptionPunctuation.endsSentence(prev.text)
                    || (w.start - prev.end) >= policy.sentenceGap
                    || w.segment != prev.segment
                if boundary { runs.append(cur); cur = [] }
            }
            cur.append(i)
        }
        if !cur.isEmpty { runs.append(cur) }
        // Second pass: split oversized sentences at clause punctuation or the longest pause.
        var out: [CaptionSentence] = []
        for run in runs {
            for piece in splitLong(run, words: words, policy: policy) {
                let members = piece.map { words[$0] }
                out.append(CaptionSentence(id: out.count, start: members.first!.start,
                                           end: members.last!.end,
                                           text: joinWords(members, script: policy.script),
                                           wordRange: piece.first! ..< (piece.last! + 1)))
            }
        }
        return out
    }

    /// Range maxima retain both ends of a tie, so queries on either side of the
    /// midpoint can choose the nearest equally good boundary. Building once per
    /// long run avoids rescanning a shrinking suffix for every split (O(n²)).
    private struct SentenceBoundaries {
        private struct Choice {
            var score: Double
            var first: Int
            var last: Int

            static let empty = Choice(score: -.infinity, first: -1, last: -1)

            func merging(_ other: Choice) -> Choice {
                if score > other.score { return self }
                if score < other.score { return other }
                return Choice(score: score, first: min(first, other.first), last: max(last, other.last))
            }
        }

        private let base: Int
        private var tree: [Choice]

        init(run: [Int], words: [CaptionWord]) {
            var size = 1
            while size < run.count { size *= 2 }
            base = size
            tree = [Choice](repeating: .empty, count: size * 2)
            for i in 1..<run.count {
                let previous = words[run[i - 1]], next = words[run[i]]
                let gap = next.start - previous.end
                // Overlaps are not pauses. Ignore sub-microsecond arithmetic
                // noise, consistent with caption timestamp serialization.
                let pause = gap.isFinite ? (max(0, gap) * 1_000_000).rounded() : 0
                let score = CaptionPunctuation.endsClause(previous.text) ? Double.infinity : pause
                tree[base + i] = Choice(score: score, first: i, last: i)
            }
            for i in stride(from: base - 1, through: 1, by: -1) {
                tree[i] = tree[i * 2].merging(tree[i * 2 + 1])
            }
        }

        private func query(_ range: Range<Int>) -> Choice {
            var lower = base + range.lowerBound, upper = base + range.upperBound
            var result = Choice.empty
            while lower < upper {
                if lower & 1 == 1 { result = result.merging(tree[lower]); lower += 1 }
                if upper & 1 == 1 { upper -= 1; result = result.merging(tree[upper]) }
                lower /= 2
                upper /= 2
            }
            return result
        }

        func cut(in range: Range<Int>) -> Int {
            let middle = range.lowerBound + range.count / 2
            let left = query((range.lowerBound + 1)..<middle)
            let right = query(middle..<range.upperBound)
            if left.first < 0 { return right.first }
            if left.score > right.score { return left.last }
            if left.score < right.score { return right.first }
            return middle - left.last <= right.first - middle ? left.last : right.first
        }
    }

    private static func splitLong(_ run: [Int], words: [CaptionWord],
                                  policy: CaptionSegmentationPolicy) -> [ArraySlice<Int>] {
        guard run.count > 1 else { return [run[...]] }
        // Every member is nonblank. Prefix sums preserve the script-specific
        // length budget while checking a subrange in O(1), without copying it.
        var lengths = [0]
        lengths.reserveCapacity(run.count + 1)
        for i in run { lengths.append(lengths.last! + wordLength(words[i].text, script: policy.script)) }
        func fits(_ range: Range<Int>) -> Bool {
            let duration = words[run[range.upperBound - 1]].end - words[run[range.lowerBound]].start
            let spaces = policy.script == .latin ? range.count - 1 : 0
            let chars = lengths[range.upperBound] - lengths[range.lowerBound] + spaces
            return duration <= policy.sentenceMaxDuration && chars <= policy.sentenceMaxChars
        }
        guard !fits(run.indices) else { return [run[...]] }
        let boundaries = SentenceBoundaries(run: run, words: words)
        var pending = [run.indices]
        var pieces: [ArraySlice<Int>] = []
        // Existing subtitles may contain an entire film in one natural run.
        // Explicit ranges keep call-stack use constant; O(n log n) worst-case
        // work and O(n) storage also cover highly unbalanced pause positions.
        while let range = pending.popLast() {
            if range.count == 1 || fits(range) {
                pieces.append(run[range])
            } else {
                let cut = boundaries.cut(in: range)
                pending.append(cut..<range.upperBound)
                pending.append(range.lowerBound..<cut)
            }
        }
        return pieces
    }

    /// Resolve sentence membership by wordRange, not timestamps. Uncovered or
    /// blank words map to nil. Sentences must come from the same input word array.
    static func sentenceIndex(forWords words: [CaptionWord], sentences: [CaptionSentence]) -> [Int?] {
        var out = [Int?](repeating: nil, count: words.count)
        for (si, s) in sentences.enumerated() {
            for i in s.wordRange where i < words.count && !isBlank(words[i])
                && words[i].start.isFinite && words[i].end.isFinite
                && words[i].start >= 0 && words[i].end > words[i].start { out[i] = si }
        }
        return out
    }

    // MARK: Subtitle lines

    /// Build lines within sentence boundaries using length, duration and pause
    /// limits. At a hard limit, prefer clause punctuation for Latin text or a CJK pause.
    static func segmentCues(_ words: [CaptionWord],
                            sentences: [CaptionSentence],
                            policy: CaptionSegmentationPolicy) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        for s in sentences {
            // Use recorded index membership; adjacent sentence timestamps may share a boundary.
            let sentWords = s.wordRange.clamped(to: words.indices)
                .map { words[$0] }.filter { !isBlank($0) && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= 0 && $0.end > $0.start }
            guard !sentWords.isEmpty else { continue }
            var cur: [CaptionWord] = []
            func flush() {
                guard !cur.isEmpty else { return }
                cues.append(CaptionCue(start: cur.first!.start, end: cur.last!.end,
                                       text: joinWords(cur, script: policy.script), sentenceID: s.id))
                cur = []
            }
            for w in sentWords {
                if !cur.isEmpty {
                    let g = w.start - cur.last!.end
                    let len = length(cur[...], script: policy.script)
                    let wlen = wordLength(w.text, script: policy.script)
                    let dur = w.end - cur.first!.start
                    let over = len + wlen + (policy.script == .latin ? 1 : 0) > policy.maxChars
                        || dur > policy.maxDuration
                    if g >= policy.gap || over {
                        var cut: Int? = nil
                        if g < policy.gap, cur.count >= 3 {
                            switch policy.script {
                            case .latin:
                                for k in stride(from: cur.count - 1, through: 2, by: -1)
                                where CaptionPunctuation.endsClause(cur[k - 1].text) {
                                    cut = k; break
                                }
                            case .cjk, .korean:
                                var bestGap = 0.0
                                for k in 2..<cur.count {
                                    let gg = cur[k].start - cur[k - 1].end
                                    if gg > bestGap { bestGap = gg; cut = k }
                                }
                                if bestGap < 0.12 { cut = nil }
                            }
                        }
                        if let cut, cut < cur.count {
                            let tail = Array(cur[cut...])
                            cur = Array(cur[..<cut])
                            flush()
                            cur = tail
                        } else {
                            flush()
                        }
                    }
                }
                cur.append(w)
            }
            flush()
        }
        return cues
    }

    /// Compute sentences and subtitle lines in one call.
    static func segment(_ words: [CaptionWord],
                        policy: CaptionSegmentationPolicy) -> (sentences: [CaptionSentence], cues: [CaptionCue]) {
        let sentences = groupSentences(words, policy: policy)
        return (sentences, segmentCues(words, sentences: sentences, policy: policy))
    }
}
