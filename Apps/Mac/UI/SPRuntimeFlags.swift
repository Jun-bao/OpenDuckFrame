import Foundation

let spDebugEnabled = ProcessInfo.processInfo.environment["SP_DEBUG"] != nil

@inline(__always) func spReleaseSecurityScopedGrant(_ url: URL) {
#if SP_APP_STORE
    url.stopAccessingSecurityScopedResource()
#endif
}
