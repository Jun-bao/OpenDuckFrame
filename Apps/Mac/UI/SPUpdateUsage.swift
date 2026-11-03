#if !SP_APP_STORE
import Foundation

/// Installation-level update statistics only. No hardware or media information
/// is read. The local token is created lazily when Sparkle checks the official feed.
@MainActor
final class SPUpdateUsageDelegate: NSObject {
    private let defaults: UserDefaults
    private let isEnabled: () -> Bool
    private let identifierKey = "SPUpdateUsageInstallationV1"

    init(defaults: UserDefaults = .standard, isEnabled: @escaping () -> Bool) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        super.init()
    }

    nonisolated static func supports(feedURL: URL?) -> Bool {
        feedURL?.absoluteString == "https://openduckframe.app/updates/appcast.xml"
    }

    @objc(feedParametersForUpdater:sendingSystemProfile:)
    func feedParameters(for updater: NSObject, sendingSystemProfile: Bool) -> [[String: String]] {
        guard isEnabled() else { return [] }
        // Validate the effective URL, not just Info.plist: Sparkle also permits
        // a local feed override. Never attach this token to another host/feed.
        guard Self.supports(feedURL: updater.value(forKey: "feedURL") as? URL) else { return [] }
        let identifier: String
        if let stored = defaults.string(forKey: identifierKey),
           let uuid = UUID(uuidString: stored) {
            identifier = uuid.uuidString.lowercased()
        } else {
            identifier = UUID().uuidString.lowercased()
            defaults.set(identifier, forKey: identifierKey)
        }
        // This delegate only enriches an existing appcast request. It must not
        // start requests, change check cadence, or set global download headers.
        return [
            ["key": "odf_usage", "value": identifier,
             "displayKey": "Update installation ID", "displayValue": identifier],
            ["key": "odf_usage_v", "value": "1",
             "displayKey": "Update statistics format", "displayValue": "1"],
        ]
    }
}
#endif
