import AppKit

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseSlider: NSSlider {

    var onTrackingChanged: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onTrackingChanged?(true)
        super.mouseDown(with: event)
        onTrackingChanged?(false)
    }
}

final class PreviewControlsView: NSVisualEffectView {
    var onTogglePlay: (() -> Void)?
    var onSeekBy: ((Double) -> Void)?
    var onSeekTo: ((Double) -> Void)?

    private let playButton = FirstMouseButton()
    private let backButton = FirstMouseButton()
    private let forwardButton = FirstMouseButton()
    private let positionLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let slider = FirstMouseSlider(value: 0, minValue: 0, maxValue: 1,
                                          target: nil, action: nil)
    private var sliderDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12

        configureButton(playButton, symbol: "play.fill", pointSize: 24,
                        action: #selector(togglePlay))
        configureButton(backButton, symbol: "gobackward.10", pointSize: 20,
                        action: #selector(seekBack))
        configureButton(forwardButton, symbol: "goforward.10", pointSize: 20,
                        action: #selector(seekForward))

        for label in [positionLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        slider.controlSize = .large

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isEnabled = false
        slider.onTrackingChanged = { [weak self] tracking in
            self?.sliderDragging = tracking
        }

        let stack = NSStackView(views: [
            playButton, backButton, forwardButton,
            positionLabel, slider, durationLabel,
        ])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    private func configureButton(_ button: NSButton, symbol: String,
                                 pointSize: CGFloat, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([

            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    func update(position: Double, duration: Double, settled: Bool) {
        durationLabel.stringValue = Self.format(duration)
        if duration > 0 {
            slider.isEnabled = true
            slider.maxValue = duration
        }
        guard !sliderDragging, settled else { return }
        positionLabel.stringValue = Self.format(position)
        if duration > 0 { slider.doubleValue = position }
    }

    func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .medium))
    }

    @objc private func togglePlay() { onTogglePlay?() }
    @objc private func seekBack() { onSeekBy?(-10) }
    @objc private func seekForward() { onSeekBy?(10) }

    func showSeekTarget(_ seconds: Double) {
        positionLabel.stringValue = Self.format(seconds)
        if slider.maxValue > 0, !sliderDragging {
            slider.doubleValue = min(max(seconds, 0), slider.maxValue)
        }
    }

    @objc private func sliderChanged() {
        positionLabel.stringValue = Self.format(slider.doubleValue)
        onSeekTo?(slider.doubleValue)
    }

    private static func format(_ seconds: Double) -> String { SPTimeText.clock(seconds) }
}
