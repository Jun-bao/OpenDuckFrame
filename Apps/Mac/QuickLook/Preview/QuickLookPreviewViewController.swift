import AppKit
import QuickLookUI
import os

final class QuickLookPreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private static let log = Logger(
        subsystem: "dev.openduckframe.quicklook.preview", category: "lifecycle")

    private let playerView = PreviewPlayerView()
    private let controls = PreviewControlsView()
    private var core: SPPlayerCore?
    private let playbackSleep = SPPlaybackSleepController()
    private var generation = 0
    private var pendingURL: URL?
    private var scopedURL: URL?
    private var hideControlsTimer: Timer?
    private var pendingPrepareHandler: ((Error?) -> Void)?
    private var displaySizeProbeToken: SPProbeCancellationToken?
    private var orphanExitTimer: Timer?
    private var orphanIdleTicks = 0
    private var errorLabel: NSTextField?
    private var specificFailureShown = false

    @MainActor private static weak var activeOwner: QuickLookPreviewViewController?

    override func loadView() {
        view = playerView

        view.appearance = NSAppearance(named: .darkAqua)
        playerView.onWindowDetach = { [weak self] in
            self?.teardownCore()
        }

        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0
        playerView.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            controls.bottomAnchor.constraint(
                equalTo: playerView.bottomAnchor, constant: -16),
            controls.leadingAnchor.constraint(
                greaterThanOrEqualTo: playerView.leadingAnchor, constant: 16),
        ])
        controls.onTogglePlay = { [weak self] in
            guard let self, let core = self.core else { return }
            core.togglePlayPause()

            self.controls.setPlaying(core.isPlaying)
        }
        controls.onSeekBy = { [weak self] delta in
            guard let self, let core = self.core else { return }
            let target = core.position + delta

            core.seek(to: target, precise: false, forward: delta > 0)
            self.controls.showSeekTarget(target)
        }
        controls.onSeekTo = { [weak self] seconds in
            // Timeline interaction commits directly to one coarse seek.
            self?.core?.seek(to: seconds, precise: false)
        }

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        playerView.addTrackingArea(tracking)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showControls()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        showControls()
    }

    private func showControls() {

        if controls.isHidden || controls.alphaValue < 1 {
            controls.isHidden = false
            controls.animator().alphaValue = 1
        }
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(
            withTimeInterval: 2.5, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                if self.core?.isPlaying ?? false {
                    NSAnimationContext.runAnimationGroup { _ in
                        self.controls.animator().alphaValue = 0
                    } completionHandler: {

                        MainActor.assumeIsolated {
                            if self.controls.alphaValue == 0 {
                                self.controls.isHidden = true
                            }
                        }
                    }
                }
            }
        }
    }

    func preparePreviewOfFile(
        at url: URL, completionHandler handler: @escaping (Error?) -> Void
    ) {
        generation += 1
        let gen = generation
        Self.activeOwner = self
        Self.log.notice(
            "prepare gen=\(gen) file=\(url.lastPathComponent, privacy: .public)")
        completePendingPrepare()
        errorLabel?.isHidden = true
        specificFailureShown = false

        teardownCore()
        pendingPrepareHandler = handler
        armOrphanWatchdog()
        pendingURL = url

        if view.window != nil {
            neutralizeClickDelays()
            openPendingURL()

            completePendingPrepare(ifGeneration: gen)
            return
        }

        let probeToken = SPProbeCancellationToken()
        displaySizeProbeToken = probeToken
        DispatchQueue.global(qos: .userInitiated).async {

            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let probed = SPPlayerCore.probeDisplaySize(
                for: url, cancellationToken: probeToken)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }

                    guard self.displaySizeProbeToken === probeToken,
                          gen == self.generation else { return }
                    self.displaySizeProbeToken = nil
                    if probed.width > 0, probed.height > 0 {
                        self.preferredContentSize = Self.fittedPanelSize(for: probed)
                    }
                    self.completePendingPrepare(ifGeneration: gen)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.cancelDisplaySizeProbe()
                self.completePendingPrepare(ifGeneration: gen)
            }
        }
    }

    private func completePendingPrepare(ifGeneration gen: Int? = nil) {
        if let gen, gen != generation { return }
        pendingPrepareHandler?(nil)
        pendingPrepareHandler = nil
    }

    private static func fittedPanelSize(for pixels: CGSize) -> CGSize {
        let bound = (NSScreen.main?.visibleFrame.size).map {
            CGSize(width: $0.width * 0.9, height: $0.height * 0.9)
        } ?? CGSize(width: 1600, height: 1000)
        let scale = min(1.0, bound.width / pixels.width, bound.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(),
                      height: (pixels.height * scale).rounded())
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        neutralizeClickDelays()
        openPendingURL()
    }

    private func neutralizeClickDelays() {
        guard let root = view.window?.contentView else { return }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            for g in v.gestureRecognizers where g.delaysPrimaryMouseButtonEvents {
                g.delaysPrimaryMouseButtonEvents = false
            }
            stack.append(contentsOf: v.subviews)
        }
    }

    override func viewWillDisappear() {
        teardownCore()
        super.viewWillDisappear()
    }

    private func showError(_ message: String) {
        controls.setPlaying(false)
        if errorLabel == nil {
            let l = NSTextField(labelWithString: "")
            l.textColor = NSColor.white.withAlphaComponent(0.85)
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.alignment = .center
            l.lineBreakMode = .byTruncatingMiddle
            l.maximumNumberOfLines = 2
            l.translatesAutoresizingMaskIntoConstraints = false
            playerView.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
                l.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
                l.leadingAnchor.constraint(
                    greaterThanOrEqualTo: playerView.leadingAnchor, constant: 16),
                l.trailingAnchor.constraint(
                    lessThanOrEqualTo: playerView.trailingAnchor, constant: -16),
            ])
            errorLabel = l
        }
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
    }

    private func openPendingURL() {
        guard let url = pendingURL else { return }

        cancelDisplaySizeProbe()
        pendingURL = nil
        let gen = generation
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        let core = SPPlayerCore(view: playerView, previewMode: true)
        core.delegate = self
        self.core = core
        do {
            try core.openMedia(at: url)
            Self.log.notice("open issued gen=\(gen)")
        } catch {
            Self.log.error(
                "open failed gen=\(gen) error=\(String(describing: error), privacy: .public)")

            if let handler = pendingPrepareHandler {
                pendingPrepareHandler = nil
                handler(error)
            } else {
                showError(error.localizedDescription)
            }
            teardownCore()
        }
    }

    private func teardownCore() {
        playbackSleep.stop()
        cancelDisplaySizeProbe()
        // Complete pending preparation with cancellation before releasing the core.
        // Closing the preview during a slow probe must not orphan its completion
        // handler or defer that callback until after the view has disappeared.
        if let handler = pendingPrepareHandler {
            pendingPrepareHandler = nil
            handler(CocoaError(.userCancelled))
        }
        if let core {
            core.stop()
            self.core = nil
        }
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
        pendingURL = nil
    }

    private func cancelDisplaySizeProbe() {
        displaySizeProbeToken?.cancel()
        displaySizeProbeToken = nil
    }

    private func armOrphanWatchdog() {
        orphanExitTimer?.invalidate()
        orphanIdleTicks = 0
        orphanExitTimer = Timer.scheduledTimer(
            withTimeInterval: 10, repeats: true
        ) { [weak self] timer in

            guard self != nil else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard let self else { return }

                let windowGone = !(self.view.window?.isVisible ?? false)
                guard windowGone else {
                    self.orphanIdleTicks = 0
                    return
                }
                self.orphanIdleTicks += 1

                if self.orphanIdleTicks >= 2,
                   self.core != nil || self.pendingURL != nil {
                    Self.log.notice("orphan watchdog: 窗口已不在屏，补 teardown")
                    self.teardownCore()
                }

                if let owner = Self.activeOwner, owner !== self { return }
                if self.orphanIdleTicks >= 3 { exit(0) }
            }
        }
    }

}

extension QuickLookPreviewViewController: SPPlayerCoreDelegate {
    func playerCore(_ core: SPPlayerCore, didUpdatePosition position: Double,
                    duration: Double) {
        controls.update(position: position, duration: duration,
                        settled: core.seekSettled)
    }

    func playerCore(_ core: SPPlayerCore, didChange state: SPPlayerState) {
        guard core === self.core else { return }
        playbackSleep.update(isPlaying: state == .playing, hasVideo: !core.audioOnlySession)
        controls.setPlaying(state == .playing)
        if state == .paused || state == .ended {
            showControls()
        }
        if state == .failed, !specificFailureShown {

            showError(NSLocalizedString("quicklook.error.playbackFailed", comment: ""))
        }
    }

    func playerCore(_ core: SPPlayerCore, didFailWithError error: Error) {
        guard core === self.core else { return }
        let nsError = error as NSError
        let terminal = (nsError.userInfo[SPPlayerErrorTerminalKey] as? NSNumber)?.boolValue ?? true
        Self.log.error(
            "playback error terminal=\(terminal) \(error.localizedDescription, privacy: .public)")

        guard terminal else { return }
        specificFailureShown = true
        showError(error.localizedDescription)
    }
}
