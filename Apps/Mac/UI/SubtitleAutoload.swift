import Foundation

enum SPSubtitleAutoload {
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    static func isSubtitleFile(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    private static let languageTags: [String: String] = [
        "zh": "zh", "chi": "zh", "zho": "zh", "chs": "zh", "cht": "zh",
        "sc": "zh", "tc": "zh", "gb": "zh", "big5": "zh",
        "zh-hans": "zh", "zh-hant": "zh", "zh-cn": "zh", "zh-tw": "zh",
        "zh-hk": "zh", "简体": "zh", "繁體": "zh", "繁体": "zh",
        "简中": "zh", "繁中": "zh", "简": "zh", "繁": "zh",
        "中文": "zh", "双语": "zh", "簡": "zh",
        "en": "en", "eng": "en", "英文": "en",
        "ja": "ja", "jpn": "ja", "jp": "ja", "日文": "ja", "日语": "ja",
        "ko": "ko", "kor": "ko",
        "fr": "fr", "fra": "fr", "fre": "fr",
        "de": "de", "ger": "de", "deu": "de",
        "es": "es", "spa": "es",
        "ru": "ru", "rus": "ru",
        "it": "it", "ita": "it",
        "pt": "pt", "por": "pt",
        "nl": "nl", "nld": "nl", "dut": "nl",
        "pl": "pl", "pol": "pl",
        "tr": "tr", "tur": "tr",
        "th": "th", "tha": "th",
        "vi": "vi", "vie": "vi",
        "id": "id", "ind": "id",
    ]

    private static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// "zh-Hans" / "zh_CN" → "zh"
    static func primaryLanguage(_ identifier: String) -> String {
        let lower = identifier.lowercased()
        if let cut = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(lower[..<cut])
        }
        return lower
    }

    private static func mapLanguage(_ tag: String) -> String? {
        if let hit = languageTags[tag] { return hit }

        for part in tag.split(separator: "-") {
            if let hit = languageTags[String(part)] { return hit }
        }
        return nil
    }

    static func rankedMatches(videoFileName: String,
                              candidates: [String],
                              uiLanguage: String,
                              shouldCancel: (() -> Bool)? = nil) -> [String] {
        let videoBase = normalize(
            (videoFileName as NSString).deletingPathExtension)
        let videoName = normalize(videoFileName)
        guard !videoBase.isEmpty else { return [] }
        let lang = primaryLanguage(uiLanguage)
        let boundary: Set<Character> = [".", "-", "_", " ", "(", "["]
        let tagSeparators = CharacterSet(charactersIn: ". _()[]&+")
        var scored: [(name: String, score: Int)] = []
        for (index, name) in candidates.enumerated() where !name.hasPrefix(".") {
            // Directory ranking is normally tiny, but subtitle repositories can
            // contain tens of thousands of names. Check in batches so rapid
            // Previous/Next coalesces obsolete background work without putting
            // a lock on every ordinary candidate.
            if (index & 63) == 0, shouldCancel?() == true { return [] }
            let ext = (name as NSString).pathExtension.lowercased()
            guard subtitleExtensions.contains(ext) else { continue }
            let base = normalize((name as NSString).deletingPathExtension)
            var score: Int
            var tags: [String] = []
            if base == videoBase {
                score = 1000
            } else if base.hasPrefix(videoBase),
                      let sep = base.dropFirst(videoBase.count).first,
                      boundary.contains(sep) {
                score = 500
                tags = base.dropFirst(videoBase.count)
                    .components(separatedBy: tagSeparators)
                    .filter { !$0.isEmpty }

                    .map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
                    .filter { !$0.isEmpty }
            } else {
                continue
            }
            // Only valid generated SRT names have an exact media owner. A marker
            // inside the already-matched movie stem belongs to its title (even
            // Movie.AI.en), so ordinary exact/tagged companions still match.
            // Legacy stem-only generated outputs remain explicit-load only.
            if let generated = CaptionOutputName.parse(name) {
                let owner = normalize(generated.mediaFileName)
                if owner.count >= videoBase.count, owner != videoName { continue }
            }
            var langMatched = false
            var otherLang = false
            for tag in tags {
                if tag == "forced" { score -= 150 }
                if tag == "sdh" || tag == "cc" || tag == "hi" { score -= 50 }
                if tag == "ai" { score -= 30 }
                if let mapped = mapLanguage(tag) {
                    if mapped == lang { langMatched = true }
                    else { otherLang = true }
                }
            }
            if langMatched { score += 200 }
            else if otherLang { score -= 100 }
            score += (ext == "ass" || ext == "ssa") ? 20 : (ext == "srt" ? 10 : 0)
            scored.append((name, score))
        }
        guard shouldCancel?() != true else { return [] }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.name.count != $1.name.count {
                return $0.name.count < $1.name.count
            }
            return $0.name < $1.name
        }.map(\.name)
    }
}
