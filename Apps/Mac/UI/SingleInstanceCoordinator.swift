import AppKit
import Darwin

@MainActor enum SingleInstanceCoordinator {

    private static func processInfo(_ pid: pid_t) -> (uid: uid_t, start: TimeInterval)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride {
            let tv = info.kp_proc.p_starttime
            return (info.kp_eproc.e_ucred.cr_uid, Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        }
        var bsd = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard bytes == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return (bsd.pbi_uid, Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
    }

    private static func identity(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.processIdentifier > 0,
              let bundleURL = app.bundleURL, let bundle = Bundle(url: bundleURL),
              SingleInstancePolicy.matchesProductMetadata(
                  bundle.object(forInfoDictionaryKey: "SPProductName") as? String,
                  bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let declared = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
              let actual = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
              declared == actual else { return false }
        if let process = processInfo(app.processIdentifier), process.uid != getuid() { return false }
        guard SingleInstancePolicy.namespace(bundle: bundle) == SingleInstancePolicy.namespace(bundle: .main) else { return false }
        // NSWorkspace lists applications in the current login session. When
        // sandbox restrictions hide process credentials, retain that boundary.
        return true
    }

    static func isProductProcess(_ pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return identity(app)
    }

    private static func hasLockProtocol(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return false }
        let value = bundle.object(forInfoDictionaryKey: "SPSingleInstanceLockVersion")
        return (value as? Int ?? (value as? String).flatMap(Int.init) ?? 0) >= 1
    }

    private static func relay(_ app: NSApplication, to existing: NSRunningApplication, arguments: [String]) -> Never {
        if SingleInstancePolicy.isContract(arguments) {
            fputs("Single-instance guard: contract was not run because another product instance is active.\n", stderr)
            exit(73)
        }
        guard let url = existing.bundleURL else { exit(74) }
        let relay = SecondaryLaunchRelay(existing: existing, bundleURL: url, arguments: arguments)
        app.delegate = relay
        withExtendedLifetime(relay) { app.run() }
        exit(74) // The relay exits with the actual delivery result.
    }

#if !SP_APP_STORE
    // Keep this descriptor alive for the entire primary process lifetime.
    private static var primaryLock: SingleInstanceLock?

    private static func enforceWithLock(_ app: NSApplication, arguments: [String]) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let namespace = SingleInstancePolicy.namespace(bundle: .main)
        let suffix = namespace.isEmpty ? "" : "-\(namespace)"
        let path = "/private/tmp/odf-chuanflow-\(getuid())\(suffix).lock"
        guard let lock = SingleInstanceLock(path: path) else {
            fputs("Single-instance guard: could not securely open the product lock.\n", stderr)
            exit(74)
        }
        let deadline = Date().addingTimeInterval(8)
        var acquired = false
        repeat {
            if !acquired {
                switch lock.tryAcquire() {
                case .acquired: acquired = true
                case .busy:
                    if SingleInstancePolicy.isContract(arguments) {
                        fputs("Single-instance guard: contract was not run because the product lock is held.\n", stderr)
                        exit(73)
                    }
                case .failed(let error):
                    fputs("Single-instance guard: product lock failed (errno \(error)).\n", stderr)
                    exit(74)
                }
            }
            let apps = NSWorkspace.shared.runningApplications.filter(identity)
            let ownRegistered = apps.contains { $0.processIdentifier == ownPID }
            if acquired {
                // A pre-existing, non-cooperating build cannot hold the new
                // lock. Yield to it before making any GPU/UI objects.
                let legacy = apps.filter { $0.processIdentifier != ownPID && !hasLockProtocol($0) }
                let candidates = legacy.map { candidate -> SingleInstancePolicy.Candidate in
                    .init(pid: candidate.processIdentifier,
                          start: processInfo(candidate.processIdentifier)?.start ?? candidate.launchDate?.timeIntervalSince1970)
                }
                if let selected = SingleInstancePolicy.winner(candidates),
                   let existing = legacy.first(where: { $0.processIdentifier == selected.pid }) {
                    lock.release()
                    fputs("Single-instance guard: handing off to existing legacy pid \(selected.pid).\n", stderr)
                    relay(app, to: existing, arguments: arguments)
                }
                if ownRegistered { primaryLock = lock; return }
            } else {
                switch lock.holder() {
                case .process(let pid):
                    if ownRegistered, let existing = apps.first(where: { $0.processIdentifier == pid }),
                       existing.isFinishedLaunching,
                       case .process(let stillOwner) = lock.holder(), stillOwner == pid {
                        fputs("Single-instance guard: lock holder is pid \(pid).\n", stderr)
                        relay(app, to: existing, arguments: arguments)
                    }
                case .unlocked: break // The holder exited; the next loop retries acquisition.
                case .failed(let error):
                    fputs("Single-instance guard: could not identify lock holder (errno \(error)).\n", stderr)
                    exit(74)
                }
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
        } while Date() < deadline
        fputs("Single-instance guard: lock owner or application registration did not become available.\n", stderr)
        exit(74)
    }
#endif

    /// Called after NSApplication initialization, before GPU prewarming or
    /// window creation. Allow the main run loop to refresh Workspace's list;
    /// otherwise two direct-exec launches can both miss registration.
    static func enforce(_ app: NSApplication, arguments: [String]) {
#if SP_APP_STORE
        enforceWithWorkspace(app, arguments: arguments)
#else
        enforceWithLock(app, arguments: arguments)
#endif
    }

    // App Store retains the previous sandbox-compatible path. It is not
    // claimed to have the cross-container atomic-lock guarantee.
    private static func enforceWithWorkspace(_ app: NSApplication, arguments: [String]) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(2)
        var sawSelf = false
        var registrationTime: Date?
        repeat {
            let apps = NSWorkspace.shared.runningApplications.filter(identity)
            if apps.contains(where: { $0.processIdentifier == ownPID }) {
                sawSelf = true
                if registrationTime == nil { registrationTime = Date() }
            }
            let candidates = apps.map { candidate -> SingleInstancePolicy.Candidate in
                let process = processInfo(candidate.processIdentifier)
                return .init(pid: candidate.processIdentifier,
                             start: process?.start ?? candidate.launchDate?.timeIntervalSince1970)
            }
            // A process not yet registered must not yield to a newer peer: its
            // own kernel start identity is not in Workspace's snapshot yet.
            if let winner = SingleInstancePolicy.preferredPeer(candidates, ownPID: ownPID),
               let existing = apps.first(where: { $0.processIdentifier == winner.pid }) {
                let order = candidates.allSatisfy { $0.start != nil } ? "start-time/PID" : "PID fallback"
                fputs("Single-instance guard: pid \(ownPID) selected pid \(winner.pid) by \(order).\n", stderr)
                relay(app, to: existing, arguments: arguments)
            }
            if let registered = registrationTime, Date().timeIntervalSince(registered) >= 0.25 { break }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
        } while Date() < deadline
        guard sawSelf else {
            fputs("Single-instance guard: application registration was not observable; launch refused.\n", stderr)
            exit(74)
        }
    }

    @MainActor private final class SecondaryLaunchRelay: NSObject, NSApplicationDelegate {
        private let existing: NSRunningApplication
        private let bundleURL: URL
        private var urls: [URL]
        private var submitted: Set<URL> = []
        private var started = false
        private var pending = 0
        private var failed = false
        private var reopenPending = false
        private var usesReopenProtocol = false
        private let deadline = Date().addingTimeInterval(5)

        init(existing: NSRunningApplication, bundleURL: URL, arguments: [String]) {
            self.existing = existing
            self.bundleURL = bundleURL
            if let path = arguments.dropFirst().first, !path.hasPrefix("-"), FileManager.default.fileExists(atPath: path) {
                self.urls = [URL(fileURLWithPath: path).standardizedFileURL]
            } else { self.urls = [] }
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            self.urls.append(contentsOf: urls)
            if started && !reopenPending { relayDocuments() }
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            started = true
            guard !existing.isTerminated else {
                fputs("Single-instance guard: existing instance exited before handoff.\n", stderr)
                exit(74)
            }
            _ = existing.unhide()
            _ = existing.activate(options: [])
            usesReopenProtocol = (Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "SPSingleInstanceProtocol") as? Int ?? 0) >= 1
            if usesReopenProtocol {
                reopenPending = true
                pending += 1
                SingleInstanceIPC.request(targetPID: existing.processIdentifier, urls: [], timeout: 4.5) { [weak self] ok, error in
                    DispatchQueue.main.async { self?.finishReopen(ok: ok, error: error) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in self?.finishWhenSettled() }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            config.allowsRunningApplicationSubstitution = false
            config.promptsUserIfNeeded = false
            pending += 1
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] application, error in
                DispatchQueue.main.async { self?.finishDelivery(application, error) }
            }
            relayDocuments()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in self?.finishWhenSettled() }
        }

        private func finishReopen(ok: Bool, error: String) {
            guard reopenPending else { return }
            reopenPending = false
            pending -= 1
            if !ok { failed = true; fputs("Single-instance reopen failed: \(error).\n", stderr) }
            else { relayDocuments() }
        }

        private func relayDocuments() {
            let fresh = urls.map(\.standardizedFileURL).filter { submitted.insert($0).inserted }
            guard !fresh.isEmpty else { return }
            if usesReopenProtocol {
                pending += 1
                SingleInstanceIPC.request(targetPID: existing.processIdentifier, urls: fresh, timeout: 4.5) { [weak self] ok, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.pending -= 1
                        if !ok { self.failed = true; fputs("Single-instance document handoff failed: \(error).\n", stderr) }
                    }
                }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            config.allowsRunningApplicationSubstitution = false
            config.promptsUserIfNeeded = false
            pending += 1
            NSWorkspace.shared.open(fresh, withApplicationAt: bundleURL, configuration: config) { [weak self] application, error in
                DispatchQueue.main.async { self?.finishDelivery(application, error) }
            }
        }

        private func finishDelivery(_ application: NSRunningApplication?, _ error: Error?) {
            pending -= 1
            if let error {
                failed = true
                fputs("Single-instance handoff failed: \(error.localizedDescription)\n", stderr)
            } else if application?.processIdentifier != existing.processIdentifier {
                failed = true
                fputs("Single-instance handoff did not reach the selected process.\n", stderr)
            }
        }

        private func finishWhenSettled() {
            if pending == 0 { exit(failed ? 74 : 0) }
            if Date() >= deadline {
                fputs("Single-instance handoff timed out.\n", stderr)
                exit(74)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finishWhenSettled() }
        }
    }
}
