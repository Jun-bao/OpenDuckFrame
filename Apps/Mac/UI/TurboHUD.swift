import AppKit
import QuartzCore

final class SPTurboHUDView: NSView {
    private enum G {
        static let height: CGFloat = 32
        static let padL: CGFloat = 12, padR: CGFloat = 14, gap: CGFloat = 8
        static let flowW: CGFloat = 30, flowH: CGFloat = 20
        static let chevCount = 3
        static let spacing: CGFloat = 11
        static let baseSpeed: CGFloat = 36
        static let lineH: CGFloat = 2
        static let lineDelay: CFTimeInterval = 0.15
        static let lineReveal: CFTimeInterval = 0.08
        static let topGap: CGFloat = 24
        static let fontSize: CGFloat = 16
        static let fadeOut: CFTimeInterval = 0.15
        static let vent: CFTimeInterval = 0.16
    }
    enum Phase { case idle, charging, active, dismissing }
    private(set) var phase: Phase = .idle

    private let pill = CALayer()
    private let line = CALayer()
    private let flow = CALayer()
    private var chevrons: [CAShapeLayer] = []
    private let digits = SPRollingDigitLabel(fontSize: G.fontSize, weight: .semibold, slots: 5)
    private var pillWidth: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let amber = SPT.turboAccentColor.cgColor
    private static let noActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "contents": NSNull(), "sublayers": NSNull(), "path": NSNull(),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.actions = Self.noActions
        for l in [pill, line, flow, digits] { l.actions = Self.noActions }
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        pill.cornerRadius = G.height / 2
        pill.opacity = 0
        line.backgroundColor = Self.amber
        line.cornerRadius = G.lineH / 2
        line.opacity = 0
        for _ in 0..<G.chevCount {
            let c = CAShapeLayer()
            c.actions = Self.noActions
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 2)); p.addLine(to: CGPoint(x: 5.5, y: 10)); p.addLine(to: CGPoint(x: 0, y: 18))
            c.path = p
            c.fillColor = nil
            c.strokeColor = Self.amber
            c.lineWidth = 2.4
            c.lineCap = .round
            c.lineJoin = .round
            c.bounds = CGRect(x: 0, y: 0, width: 6, height: G.flowH)
            c.anchorPoint = .zero
            c.opacity = 0
            flow.addSublayer(c)
            chevrons.append(c)
        }
        pill.addSublayer(flow)
        pill.addSublayer(digits)
        layer?.addSublayer(pill)
        layer?.addSublayer(line)
        isHidden = true
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        digits.updateContentsScale(scale)
    }

    func place(in bounds: CGRect, topInset: CGFloat) {
        guard pillWidth > 0 else { return }
        frame = CGRect(x: (bounds.width - pillWidth) / 2,
                       y: bounds.height - G.height - G.topGap - topInset,
                       width: pillWidth, height: G.height).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: pillWidth / 2, y: G.height / 2)
        pill.bounds = CGRect(x: 0, y: 0, width: pillWidth, height: G.height)
        pill.position = center
        line.position = center
        flow.frame = CGRect(x: G.padL, y: (G.height - G.flowH) / 2, width: G.flowW, height: G.flowH)
        digits.frame = CGRect(x: G.padL + G.flowW + G.gap, y: (G.height - G.flowH) / 2,
                              width: textWidth, height: G.flowH)
        digits.relayoutSlots()
        CATransaction.commit()
    }

    private func measure(rate: Double) {
        textWidth = ceil(digits.measure(SPChromeView.fmtRate(rate)))
        pillWidth = ceil(G.padL + G.flowW + G.gap + textWidth + G.padR)
    }

    func beginCharge(targetRate: Double) {
        phase = .charging
        measure(rate: targetRate)
        isHidden = false
        resetContent()
        guard !reduceMotion else { return }
        line.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.bounds = CGRect(x: 0, y: 0, width: pillWidth, height: G.lineH)
        line.opacity = 1
        CATransaction.commit()

        let hold = SPTurboSpeed.holdThreshold
        let tStart = G.lineDelay / hold
        let tShown = min(1, (G.lineDelay + G.lineReveal) / hold)
        let grow = CAKeyframeAnimation(keyPath: "bounds.size.width")
        grow.values = [0, 0, pillWidth]
        grow.keyTimes = [0, NSNumber(value: tStart), 1]
        grow.timingFunctions = [.init(name: .linear), .init(name: .easeOut)]
        grow.duration = hold
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 0, 1, 1]
        show.keyTimes = [0, NSNumber(value: tStart), NSNumber(value: tShown), 1]
        show.timingFunctions = [.init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
        show.duration = hold
        let group = CAAnimationGroup()
        group.animations = [grow, show]
        group.duration = SPTurboSpeed.holdThreshold
        line.add(group, forKey: "charge")
    }

    func cancelCharge() {
        guard phase == .charging else { return }
        phase = .idle
        guard !reduceMotion else { isHidden = true; return }
        let pres = line.presentation() ?? line
        let w = pres.bounds.width, a = pres.opacity
        line.removeAnimation(forKey: "charge")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.bounds = CGRect(x: 0, y: 0, width: 0, height: G.lineH)
        line.opacity = 0
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.isHidden = true
        }
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = w; shrink.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = a; fade.toValue = 0
        for anim in [shrink, fade] {
            anim.duration = 0.10
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        line.add(shrink, forKey: "retractW")
        line.add(fade, forKey: "retractA")
        CATransaction.commit()
    }

    func engage(baseRate: Double, rate: Double) {
        phase = .active
        measure(rate: rate)
        isHidden = false
        setAccessibilityValue(SPChromeView.fmtRate(rate))
        resetContent()
        line.removeAllAnimations()
        pill.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.opacity = 0
        pill.opacity = 1
        pill.transform = CATransform3DIdentity
        CATransaction.commit()
        if let bounds = superview?.bounds { place(in: bounds, topInset: currentTopInset()) }
        if reduceMotion {
            digits.setText(SPChromeView.fmtRate(rate), color: .white, increasing: true, animated: false)
            for (i, c) in chevrons.enumerated() where i < 2 {
                c.position = CGPoint(x: 4 + CGFloat(i) * 10, y: 0)
                c.opacity = 1
            }
            return
        }

        let unfold = CASpringAnimation(keyPath: "transform.scale.y")
        unfold.fromValue = G.lineH / G.height
        unfold.toValue = 1
        unfold.mass = 1; unfold.stiffness = 320; unfold.damping = 11; unfold.initialVelocity = 10
        unfold.duration = unfold.settlingDuration
        pill.add(unfold, forKey: "unfold")

        let whip = CAKeyframeAnimation(keyPath: "transform.translation.x")
        whip.values = [-14, 3, 0]
        whip.keyTimes = [0, 0.6, 1]
        whip.duration = 0.3
        whip.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flow.add(whip, forKey: "whip")
        startFlow(rate: rate)

        digits.setText(SPChromeView.fmtRate(baseRate), color: .white, increasing: true, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.phase == .active else { return }
            self.digits.setText(SPChromeView.fmtRate(rate), color: .white, increasing: rate >= baseRate, animated: true)
        }
    }

    private func startFlow(rate: Double) {
        let period = G.flowW + G.spacing
        let speed = G.baseSpeed * CGFloat(max(rate, 1) / 2)
        let dur = CFTimeInterval(period / speed)
        let x0 = -G.spacing / 2

        func kt(_ x: CGFloat) -> NSNumber { NSNumber(value: Double((x - x0) / period)) }
        for (i, c) in chevrons.enumerated() {
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = x0
            move.toValue = x0 + period
            let alpha = CAKeyframeAnimation(keyPath: "opacity")
            alpha.values = [0, 0, 1, 1, 0, 0]
            alpha.keyTimes = [0, kt(-3), kt(5.4), kt(18.6), kt(27), 1]
            for anim in [move, alpha] as [CAPropertyAnimation] {
                anim.duration = dur
                anim.repeatCount = .infinity
                anim.timeOffset = CFTimeInterval(CGFloat(i) * G.spacing / speed)
            }
            c.add(move, forKey: "flowX")
            c.add(alpha, forKey: "flowA")
        }
    }

    func dismiss() {
        guard phase == .active || phase == .charging else { return }
        if phase == .charging { cancelCharge(); return }
        phase = .dismissing
        if reduceMotion {
            phase = .idle
            isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in

            guard let self, self.phase == .dismissing else { return }
            self.phase = .idle
            self.isHidden = true
            self.resetContent()
        }

        for l in [flow, digits] as [CALayer] {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0; slide.toValue = 10
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            for anim in [slide, fade] {
                anim.duration = G.vent
                anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
            }
            l.add(slide, forKey: "ventX")
            l.add(fade, forKey: "ventA")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = G.fadeOut
        pill.opacity = 0
        pill.add(fade, forKey: "turboFade")
        CATransaction.commit()
    }

    private func resetContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [flow, digits] as [CALayer] {
            l.removeAllAnimations()
            l.transform = CATransform3DIdentity
            l.opacity = 1
        }
        for c in chevrons {
            c.removeAllAnimations()
            c.opacity = 0
            c.position = .zero
        }
        CATransaction.commit()
    }

    private func currentTopInset() -> CGFloat {
        guard let win = window, let content = win.contentView else { return 0 }
        return content.bounds.maxY - win.contentLayoutRect.maxY
    }
}
