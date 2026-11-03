import AppKit
import SwiftUI
import Translation

// On-demand download UI. The app owns the panel independently of the initiating
// playback window. SwiftUI remains confined to this dynamically loaded framework.
@available(macOS 26.0, *)
private struct DownloadHostView: View {
    let configuration: TranslationSession.Configuration
    let run: @MainActor (TranslationSession) async -> Void

    var body: some View {
        ProgressView()
            .frame(width: 300, height: 84)
            .translationTask(configuration) { session in
                await run(session)
            }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class DownloadRequest: NSObject, NSWindowDelegate {
    let id: String
    let completion: (NSError?) -> Void
    private var panel: NSPanel?
    private var host: NSView?
    private var session: TranslationSession?
    private var operation: Task<NSError?, Never>?
    private var cancelled = false
    private var finished = false

    init(id: String, completion: @escaping (NSError?) -> Void) {
        self.id = id
        self.completion = completion
    }

    func show(source: String, target: String, near window: NSWindow?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 84),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("captions.status.preparing", bundle: .main, comment: "")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let config = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                       target: Locale.Language(identifier: target))
        let hosting = NSHostingView(rootView: DownloadHostView(configuration: config) { [weak self] session in
            guard let self else { session.cancel(); return }
            await self.run(session)
        })
        panel.contentView = hosting
        if let window, window.isVisible {
            panel.setFrameOrigin(NSPoint(x: window.frame.midX - 150, y: window.frame.midY - 42))
        } else {
            panel.center()
        }
        self.panel = panel
        host = hosting
        panel.makeKeyAndOrderFront(nil)
    }

    private func run(_ session: TranslationSession) async {
        guard !finished, operation == nil else { session.cancel(); return }
        self.session = session
        let operation = Task { @MainActor [self] in
            let error: NSError?
            do {
                try Task.checkCancellation()
                if cancelled { throw CancellationError() }
                try await session.prepareTranslation()
                try Task.checkCancellation()
                error = nil
            } catch let failure {
                if cancelled || Task.isCancelled || failure is CancellationError {
                    error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                } else {
                    error = failure as NSError
                }
            }
            return error
        }
        self.operation = operation
        if cancelled { session.cancel(); operation.cancel() }
        let error = await operation.value
        self.session = nil
        finish(error)
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        session?.cancel()
        operation?.cancel()
        // No system operation is in flight yet; finished rejects callbacks after host removal.
        if operation == nil { finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func finish(_ error: NSError?) {
        guard !finished else { return }
        finished = true
        panel?.delegate = nil
        host?.removeFromSuperview()
        host = nil
        panel?.close()
        panel = nil
        operation = nil
        SPCaptionDownloadHost.remove(id)
        completion(error)
    }
}

@objc(SPCaptionDownloadHost)
public final class SPCaptionDownloadHost: NSObject {
    @MainActor private static var requests: [String: AnyObject] = [:]

    @MainActor @objc(downloadWithSource:target:window:requestID:completion:)
    public static func download(withSource source: NSString, target: NSString, window: NSWindow?,
                                requestID: NSString, completion: @escaping (NSError?) -> Void) {
        guard #available(macOS 26.0, *) else {
            completion(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return
        }
        let id = requestID as String
        guard requests[id] == nil else {
            completion(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        let request = DownloadRequest(id: id, completion: completion)
        requests[id] = request
        request.show(source: source as String, target: target as String, near: window)
    }

    @MainActor @objc(cancelWithRequestID:)
    public static func cancel(requestID: NSString) {
        guard #available(macOS 26.0, *) else { return }
        (requests[requestID as String] as? DownloadRequest)?.cancel()
    }

    @MainActor fileprivate static func remove(_ id: String) {
        requests.removeValue(forKey: id)
    }
}
