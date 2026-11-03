import AppKit
import QuartzCore

final class PreviewPlayerView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        layer = metalLayer
        wantsLayer = true
        metalLayer.contentsScale = 2.0
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    var onWindowDetach: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            onWindowDetach?()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = NSSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {}
}
