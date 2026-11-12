import AppKit

/// Three short hints for the existing workbench; no media or profile settings are changed.
enum WorkbenchGuideStep: Int, CaseIterable {
    case source, frameGeneration, start

    var next: WorkbenchGuideStep? { WorkbenchGuideStep(rawValue: rawValue + 1) }
}

enum WorkbenchGuidePreference {
    static let completionKey = "OpenDuckFrame.WorkbenchGuide.v1.completed"

    static func shouldShow(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: completionKey)
    }

    static func complete(in defaults: UserDefaults) {
        defaults.set(true, forKey: completionKey)
    }
}

@MainActor final class WorkbenchGuideContent: NSViewController {
    private let step: WorkbenchGuideStep
    private let sourceKind: String
    private let alreadyRunning: Bool
    private let skip: () -> Void
    private let advance: () -> Void

    init(step: WorkbenchGuideStep, sourceKind: String, alreadyRunning: Bool,
         skip: @escaping () -> Void, advance: @escaping () -> Void) {
        self.step = step
        self.sourceKind = sourceKind
        self.alreadyRunning = alreadyRunning
        self.skip = skip
        self.advance = advance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 328, height: 180))
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let progress = NSTextField(labelWithString: "\(step.rawValue + 1) / \(WorkbenchGuideStep.allCases.count)")
        progress.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progress.textColor = .secondaryLabelColor
        progress.setAccessibilityLabel(EnhancementText.t("Step \(step.rawValue + 1) of 3", "第 \(step.rawValue + 1) 步，共 3 步"))
        let title = NSTextField(wrappingLabelWithString: titleText)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .labelColor
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 3
        let skipButton = NSButton(title: EnhancementText.t("Skip", "跳过"), target: self, action: #selector(skipPressed))
        skipButton.bezelStyle = .inline
        skipButton.identifier = NSUserInterfaceItemIdentifier("workbench.guide.skip")
        let actionTitle = step.next == nil ? EnhancementText.t("Done", "完成") : EnhancementText.t("Next", "下一步")
        let nextButton = NSButton(title: actionTitle, target: self, action: #selector(nextPressed))
        nextButton.bezelStyle = .rounded
        nextButton.bezelColor = .controlAccentColor
        nextButton.contentTintColor = .white
        nextButton.identifier = NSUserInterfaceItemIdentifier("workbench.guide.next")
        nextButton.keyEquivalent = "\r"

        for child in [icon, progress, title, body, skipButton, nextButton] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            progress.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            nextButton.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            nextButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            nextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            skipButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            skipButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: nextButton.topAnchor, constant: -8),
        ])
        view = root
    }

    private var titleText: String {
        switch step {
        case .source: return EnhancementText.t("Choose a source", "选择画面来源")
        case .frameGeneration: return EnhancementText.t("Frame generation", "开启帧生成")
        case .start: return alreadyRunning ? EnhancementText.t("Enhancement is running", "增强已开启") : EnhancementText.t("Start enhancement", "开始增强")
        }
    }

    private var bodyText: String {
        switch step {
        case .source:
            return EnhancementText.t("Choose a window, display, or video file to enhance.", "选择要增强的窗口、显示器或视频。")
        case .frameGeneration:
            return EnhancementText.t("Turn on frame generation to make motion smoother.", "确认帧生成已开启，让画面更流畅。")
        case .start:
            if alreadyRunning {
                return EnhancementText.t("Use Stop when you want to end enhancement.", "需要结束增强时，可以点击停止。")
            }
            if sourceKind == "window" {
                return EnhancementText.t("Choose Delayed Enhancement, then switch to the window you want to enhance.", "点击延迟增强，然后切到要增强的窗口。")
            }
            return EnhancementText.t("After choosing a source, select Start Enhancement.", "选择来源后，点击开始增强。")
        }
    }

    @objc private func skipPressed() { skip() }
    @objc private func nextPressed() { advance() }
}
