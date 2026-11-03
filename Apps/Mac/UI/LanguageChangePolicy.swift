import Foundation

// Existing windows and the system-localized bundle are built at launch. Keep
// this process alive, persist the choice, and explain when a relaunch is needed.
enum LanguageChangePolicy {
    static func change(target: String?, current: String?, running: String?,
                       effective: (String?) -> String?, persist: (String?) -> Void,
                       notifyRelaunch: () -> Void) {
        guard target != current else { return }
        persist(target)
        if effective(target) != running { notifyRelaunch() }
    }
}
