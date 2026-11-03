import AppKit
import QuartzCore

@MainActor
final class WindowDragEffect: NSObject {
    // Direct-build comparison switch; store builds always use the shipping behavior.
#if SP_APP_STORE
    static let enabled = true
#else
    static let enabled = ProcessInfo.processInfo.environment["SP_DRAGFX"] != "0"
#endif

    var apply: ((Float, Float, CGPoint) -> Void)?

    private weak var view: NSView?
    private var link: CADisplayLink?

    private var anchorPt: CGPoint = .zero
    private var downOrigin: NSPoint = .zero
    private var lastTick: CFTimeInterval = 0
    private var tracking = false
    private var moved = false

    private var strength: Double = 0
    private var colorStrength: Double = 0
    private var target: Double = 0

    private var lastApplied: (blur: Float, color: Float, anchor: CGPoint)?

    private static let moveThreshold: CGFloat = 0
    private static let fadeIn: Double = 0.05
    private static let fadeOut: Double = 0.25
    private static let colorFadeOut: Double = 0.20

    @discardableResult
    func mouseDown(_ event: NSEvent, in view: NSView) -> Bool {
        guard Self.enabled, let window = view.window else { return false }

        if event.clickCount > 1 || window.styleMask.contains(.fullScreen) {
            tracking = false
            target = 0
            return false
        }
        self.view = view
        anchorPt = view.convert(event.locationInWindow, from: nil)
        downOrigin = window.frame.origin
        tracking = true
        moved = false

        target = 0
        startLink()
        return true
    }

    private func startLink() {
        guard link == nil, let view else { return }
        lastTick = 0

        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view, let window = view.window else {
            finish()
            return
        }
        let now = CACurrentMediaTime()
        let dt = lastTick > 0 ? min(max(now - lastTick, 1.0 / 240), 1.0 / 20) : 1.0 / 60
        lastTick = now
        let scale = window.backingScaleFactor
        let anchorPx = CGPoint(x: anchorPt.x * scale, y: (view.bounds.height - anchorPt.y) * scale)

        if tracking {
            let origin = window.frame.origin
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            if window.styleMask.contains(.fullScreen) {
                tracking = false
                target = 0
            } else {
                if !moved, hypot(origin.x - downOrigin.x, origin.y - downOrigin.y) > Self.moveThreshold {
                    moved = true
                    target = 1
                    if spDebugEnabled { NSLog("[DragFx] 拖动开始 锚点=(%.0f,%.0f)px", anchorPx.x, anchorPx.y) }
                }
                if !pressed {
                    tracking = false
                    target = 0
                    if moved, spDebugEnabled { NSLog("[DragFx] 松手，淡出") }
                }
            }
        }

        if target > strength {
            strength = min(target, strength + dt / Self.fadeIn)
        } else if target < strength {
            strength = max(target, strength - dt / Self.fadeOut)
        }
        if target > colorStrength {
            colorStrength = min(target, colorStrength + dt / Self.fadeIn)
        } else if target < colorStrength {
            colorStrength = max(target, colorStrength - dt / Self.colorFadeOut)
        }
        let eased = strength * strength * (3 - 2 * strength)
        let colorEased = colorStrength * colorStrength * (3 - 2 * colorStrength)
        let settled = target == 0 && strength <= 0 && colorStrength <= 0
        let value: Float = settled ? 0 : Float(eased)
        let colorValue: Float = settled ? 0 : Float(colorEased)

        if value > 0 || colorValue > 0 || lastApplied != nil {
            send(value, colorValue, anchorPx)
        }
        if settled && !tracking { finish() }
    }

    private func send(_ blur: Float, _ color: Float, _ anchor: CGPoint) {
        if let last = lastApplied, last.blur == blur, last.color == color, last.anchor == anchor { return }
        apply?(blur, color, anchor)
        lastApplied = (blur > 0 || color > 0) ? (blur, color, anchor) : nil
    }

    private func finish() {
        stopLink()
        tracking = false
        moved = false
        target = 0
        strength = 0
        colorStrength = 0
        if let last = lastApplied { send(0, 0, last.anchor) }
    }

    static func applyTestHookIfNeeded(core: SPPlayerCore, state: SPPlayerState, view: NSView) {
#if !SP_APP_STORE
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SP_DRAGFX_TEST"], !raw.isEmpty,
              env["SP_DEBUG"] != nil || env["SP_AUTOMATION"] != nil,
              state == .playing || state == .paused else { return }
        var fx = 0.5, fy = 0.5
        var blurValue: Float = 1, colorValue: Float = 1
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 || parts.count == 4 { fx = parts[0]; fy = parts[1] }
        if parts.count == 4 {
            blurValue = Float(parts[2])
            colorValue = Float(parts[3])
        }
        let scale = view.window?.backingScaleFactor ?? 2
        let anchor = CGPoint(x: view.bounds.width * fx * scale, y: view.bounds.height * fy * scale)
        core.setWindowDragEffectStrength(blurValue, colorStrength: colorValue, anchorPx: anchor)
#endif
    }
}
