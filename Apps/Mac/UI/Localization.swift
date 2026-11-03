import AppKit

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

enum AppLanguage {

    static let supported: [String] = [
        "de", "en", "es", "fr", "id", "it", "ja", "ko", "nl", "pl",
        "pt", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    static var current: String? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard
                  .persistentDomain(forName: bundleID),
              let langs = domain["AppleLanguages"] as? [String],
              let first = langs.first else { return nil }

        return supported.first { first == $0 || first.hasPrefix($0 + "-") }
    }

    static func effectiveLanguage(for code: String?) -> String? {
        let prefs: [String]
        if let code {
            prefs = [code]
        } else {
            prefs = UserDefaults.standard
                .persistentDomain(forName: UserDefaults.globalDomain)?[
                    "AppleLanguages"] as? [String] ?? []
        }
        return Bundle.preferredLocalizations(from: supported,
                                             forPreferences: prefs).first
    }

    static func apply(_ code: String?) {
        let defaults = UserDefaults.standard
        if let code {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    static func displayName(for code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else {
            return code
        }
        return name.capitalized(with: locale)
    }
}
