import Foundation

// Caption data models and language conventions. These value types depend only
// on Foundation. The controller connects generated events and a read-only
// playback admission probe; generation advances sequentially from the beginning.

/// A recognized word with zero-based media times in seconds. Segment identity
/// preserves recognition boundaries when punctuation alone cannot split sentences.
struct CaptionWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var confidence: Double
    var segment: Int
}

/// A source-language subtitle line associated with its translation sentence.
struct CaptionCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var sentenceID: Int
}

/// A sentence is one translation unit. wordRange records membership in the
/// original word array; downstream code must use those indices rather than
/// infer membership from timestamp ranges that can share a boundary.
struct CaptionSentence: Equatable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var wordRange: Range<Int>
}

/// Writing systems determine segmentation budgets and word-joining rules.
enum CaptionScript: Sendable {
    case latin
    case cjk
    /// Korean uses CJK reading budgets while preserving spaces between words.
    case korean

    static func forLocale(_ locale: Locale) -> CaptionScript {
        let lang = (locale.language.languageCode?.identifier ?? locale.identifier).lowercased()
        if lang == "ko" { return .korean }
        return ["zh", "yue", "ja"].contains(where: { lang.hasPrefix($0) }) ? .cjk : .latin
    }

    static func forLanguageTag(_ tag: String) -> CaptionScript {
        let lower = tag.lowercased()
        if lower == "ko" || lower.hasPrefix("ko-") || lower.hasPrefix("ko_") { return .korean }
        return ["zh", "yue", "ja"].contains(where: { lower.hasPrefix($0) }) ? .cjk : .latin
    }
}

/// Translation targets describe written output; Speech locales describe a
/// regional recognition model. Do not use a minimized Chinese locale (zh/TW)
/// as a substitute for its script when displaying translation targets.
enum CaptionLanguageNames {
    static func target(_ language: Locale.Language, in displayLocale: Locale = .current) -> String {
        var identifier = language.minimalIdentifier
        if language.languageCode?.identifier == "zh", let script = language.script?.identifier {
            identifier = "zh-\(script)"
        }
        return displayLocale.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func speech(_ locale: Locale, in displayLocale: Locale = .current) -> String {
        displayLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

enum CaptionPunctuation {
    static let sentenceEnd: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    static let clause: Set<Character> = [",", ";", ":", "，", "；", "：", "、"]

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return sentenceEnd.contains(last)
    }

    static func endsClause(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return clause.contains(last)
    }
}

/// Tags are used for filenames and language comparison, not language detection.
/// Subtitle text and speech recognition determine the source language.
enum CaptionLanguageTags {
    /// Convert a recognition locale to a BCP 47 filename tag.
    static func fileTag(forTranscriberLocale locale: Locale) -> String {
        let language = locale.language
        if language.languageCode?.identifier == "zh", let script = language.script?.identifier,
           script == "Hans" || script == "Hant" { return "zh-\(script)" }
        let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let lower = id.lowercased()
        switch lower {
        case "yue", "yue-cn", "yue-hk", "yue-hant", "yue-hans": return "yue"
        default:
            // Filename tags omit regional variants while retaining meaningful script distinctions.
            if let cut = lower.firstIndex(of: "-") { return String(lower[..<cut]) }
            return lower
        }
    }

    /// Extract the primary language from a filename tag.
    static func primaryLanguage(_ tag: String) -> String {
        let lower = tag.lowercased()
        if let cut = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) { return String(lower[..<cut]) }
        return lower
    }

    /// Convert a translation target identifier to a filename tag.
    static func fileTag(forTargetLanguage identifier: String) -> String {
        fileTag(forTranscriberLocale: Locale(identifier: identifier))
    }
}

/// A completed pass with no usable text is a no-result outcome, never a newly
/// generated empty sidecar. Sparse but valid speech is not rejected by density.
struct CaptionNoContentError: LocalizedError, Sendable {
    var speech: Bool
    var errorDescription: String? {
        if speech { return NSLocalizedString("captions.error.noSpeech", comment: "") }
        return NSLocalizedString("captions.error.noSubtitleText", comment: "")
    }
}
