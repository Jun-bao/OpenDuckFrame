import AppKit
import QuartzCore

final class SPPlaybackNoticeView: NSView {
    private enum G {
        static let height: CGFloat = 30
        static let padH: CGFloat = 14
        static let topGap: CGFloat = 24
        static let fontSize: CGFloat = 13
        static let fade: CFTimeInterval = 0.15
        static let transientSeconds: TimeInterval = 3
    }

    private let label = NSTextField(labelWithString: "")
    private var stickyText: String?
    private var transientText: String?
    private var transientTimer: Timer?
    private var lastBounds: NSRect = .zero
    private var lastTopInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        layer?.cornerRadius = G.height / 2
        label.font = .systemFont(ofSize: G.fontSize, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SPPlaybackNoticeView: no coder path") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSticky(_ text: String?) {
        stickyText = text
        refresh()
    }

    func showTransient(_ text: String) {
        transientText = text
        transientTimer?.invalidate()
        transientTimer = Timer.scheduledTimer(withTimeInterval: G.transientSeconds, repeats: false) { [weak self] _ in
            self?.transientText = nil
            self?.refresh()
        }
        refresh()
    }

    func clearAll() {
        transientTimer?.invalidate()
        transientTimer = nil
        stickyText = nil
        transientText = nil
        refresh()
    }

    func place(in bounds: NSRect, topInset: CGFloat) {
        lastBounds = bounds
        lastTopInset = topInset
        guard let text = currentText else { return }
        label.stringValue = text
        let textW = ceil(label.intrinsicContentSize.width)
        let w = min(textW + G.padH * 2, max(bounds.width - 32, 80))
        frame = NSRect(x: bounds.midX - w / 2, y: bounds.maxY - topInset - G.topGap - G.height,
                       width: w, height: G.height)
        let labelH = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: G.padH, y: (G.height - labelH) / 2, width: w - G.padH * 2, height: labelH)
    }

    private var currentText: String? { transientText ?? stickyText }

    private func refresh() {
        if currentText != nil {
            place(in: lastBounds, topInset: lastTopInset)

            if isHidden || alphaValue < 1 {
                isHidden = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = G.fade
                    animator().alphaValue = 1
                }
            }
        } else if !isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = G.fade
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.currentText == nil else { return }
                self.isHidden = true
            })
        }
    }
}
