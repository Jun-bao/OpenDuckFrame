import AppKit

@MainActor final class ExperimentComparisonPanel: NSWindowController {
    private let selectionChanged: @MainActor (SPRifeExperimentSelection) -> Void
    private let switchBuild: @MainActor () async throws -> Void
    private let ioCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let finetuneCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lowrankCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let maskCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let finetunePopup = NSPopUpButton()
    private let lowrankPopup = NSPopUpButton()
    private let buildLabel = NSTextField(labelWithString: "")
    private let buildState = NSTextField(labelWithString: "")
    private let buildButton = NSButton(title: "", target: nil, action: nil)
    private let combinationNote = NSTextField(wrappingLabelWithString: "")
    private let restartNote = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "", target: nil, action: nil)
    private var switchingBuild = false

    init(selectionChanged: @escaping @MainActor (SPRifeExperimentSelection) -> Void,
         switchBuild: @escaping @MainActor () async throws -> Void) {
        self.selectionChanged = selectionChanged
        self.switchBuild = switchBuild
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 388),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.identifier = NSUserInterfaceItemIdentifier("experiments.comparison")
        super.init(window: panel)
        panel.contentView = makeContent()
        panel.center()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        statusLabel.stringValue = ""
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showStatus(_ message: String, error: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        fitContent()
    }

    func refresh() {
        let selection = SPRifeExperiments.selection
        let finetune = selection.model == "finetune-a" || selection.model == "finetune-b"
        let lowrank = selection.model == "lowrank-initial" || selection.model == "lowrank-trained"
        window?.title = EnhancementText.t("Compare Options", "方案对比")
        ioCheck.title = EnhancementText.t("1. Data transfer optimization", "① 数据搬运优化")
        finetuneCheck.title = EnhancementText.t("2. Fine-tuned model", "② 微调模型")
        lowrankCheck.title = EnhancementText.t("3. Low-rank model", "③ 低秩模型")
        maskCheck.title = EnhancementText.t("4. Frame blending rule", "④ 画面融合规则")
        buildLabel.stringValue = EnhancementText.t("5. Optimized build", "⑤ 优化构建")
        buildState.stringValue = SPRifeExperiments.optimizedBuild
            ? EnhancementText.t("Current: optimized", "当前：优化构建")
            : EnhancementText.t("Current: comparison", "当前：对照构建")
        buildButton.title = SPRifeExperiments.optimizedBuild
            ? EnhancementText.t("Restart with comparison build", "重启到对照构建")
            : EnhancementText.t("Restart with optimized build", "重启到优化构建")
        resetButton.title = EnhancementText.t("Turn off options 1–4", "关闭前四项")
        combinationNote.stringValue = EnhancementText.t(
            "Choose either a fine-tuned or a low-rank model. Other options can be combined.",
            "微调模型与低秩模型只能选一个，其余选项可以组合试用。")
        restartNote.stringValue = EnhancementText.t(
            "Changing the build restarts this trial app.", "切换构建会重启这个试用应用。")
        finetunePopup.removeAllItems()
        finetunePopup.addItems(withTitles: [EnhancementText.t("Version 1", "微调版1"), EnhancementText.t("Version 2", "微调版2")])
        finetunePopup.selectItem(at: selection.model == "finetune-a" ? 0 : 1)
        lowrankPopup.removeAllItems()
        lowrankPopup.addItems(withTitles: [EnhancementText.t("Initial weights", "低秩初值"), EnhancementText.t("After training", "训练后")])
        lowrankPopup.selectItem(at: selection.model == "lowrank-trained" ? 1 : 0)
        ioCheck.state = selection.ioOptimized ? .on : .off
        finetuneCheck.state = finetune ? .on : .off
        lowrankCheck.state = lowrank ? .on : .off
        maskCheck.state = selection.replaceMask ? .on : .off
        for control in [ioCheck, finetuneCheck, lowrankCheck, maskCheck, buildButton] {
            control.isEnabled = !switchingBuild
        }
        finetunePopup.isEnabled = finetune && !switchingBuild
        lowrankPopup.isEnabled = lowrank && !switchingBuild
        resetButton.isEnabled = !switchingBuild && (selection.ioOptimized || selection.model != "original" || selection.replaceMask)
        finetunePopup.setAccessibilityLabel(EnhancementText.t("Fine-tuned model version", "微调模型版本"))
        lowrankPopup.setAccessibilityLabel(EnhancementText.t("Low-rank model version", "低秩模型版本"))
        if statusLabel.stringValue.isEmpty {
            showStatus(EnhancementText.t(
                "Changing options 1–4 stops enhancement. Click Start Enhancement in the workbench to apply them.",
                "调整前四项会停止增强；请回工作台点击开始增强后应用。"))
        } else {
            statusLabel.stringValue = EnhancementText.translated(statusLabel.stringValue, chinese: EnhancementText.chinese)
        }
        fitContent()
    }

    private func fitContent() {
        guard let window, let content = window.contentView else { return }
        window.setContentSize(NSSize(width: 540, height: max(360, ceil(content.fittingSize.height))))
    }

    private func makeContent() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for label in [combinationNote, restartNote, statusLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
        }
        statusLabel.identifier = NSUserInterfaceItemIdentifier("experiments.status")
        stack.addArrangedSubview(combinationNote)
        combinationNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let controls = [ioCheck, finetuneCheck, lowrankCheck, maskCheck]
        for (control, name) in zip(controls, ["io", "finetune", "lowrank", "mask"]) {
            control.identifier = NSUserInterfaceItemIdentifier("experiments.\(name)")
            control.target = self
            control.action = #selector(optionChanged(_:))
        }
        for (popup, name) in [(finetunePopup, "finetune.variant"), (lowrankPopup, "lowrank.variant")] {
            popup.identifier = NSUserInterfaceItemIdentifier("experiments.\(name)")
            popup.target = self
            popup.action = #selector(optionChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        let rows: [(NSButton, NSPopUpButton?)] = [(ioCheck, nil), (finetuneCheck, finetunePopup), (lowrankCheck, lowrankPopup), (maskCheck, nil)]
        for (control, detail) in rows {
            var views: [NSView] = [control, NSView()]
            if let detail { views.append(detail) }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let buildRow = NSStackView(views: [buildLabel, NSView(), buildState])
        buildRow.orientation = .horizontal
        buildRow.alignment = .centerY
        buildRow.spacing = 12
        stack.addArrangedSubview(buildRow)
        buildRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buildState.font = .systemFont(ofSize: 12)
        buildState.textColor = .secondaryLabelColor
        buildButton.bezelStyle = .rounded
        buildButton.identifier = NSUserInterfaceItemIdentifier("experiments.build.switch")
        buildButton.target = self
        buildButton.action = #selector(buildChanged)
        let buildActions = NSStackView(views: [buildButton, restartNote])
        buildActions.orientation = .horizontal
        buildActions.alignment = .centerY
        buildActions.spacing = 12
        stack.addArrangedSubview(buildActions)
        buildActions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        resetButton.bezelStyle = .rounded
        resetButton.identifier = NSUserInterfaceItemIdentifier("experiments.reset")
        resetButton.target = self
        resetButton.action = #selector(resetOptions)
        stack.addArrangedSubview(resetButton)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 540),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        return content
    }

    @objc private func optionChanged(_ sender: NSControl) {
        guard !switchingBuild else { return }
        var selection = SPRifeExperiments.selection
        if sender === ioCheck {
            selection.ioOptimized = ioCheck.state == .on
        } else if sender === finetuneCheck {
            selection.model = finetuneCheck.state == .on ? "finetune-b" : "original"
            if finetuneCheck.state == .on { selection.replaceMask = true }
        } else if sender === lowrankCheck {
            selection.model = lowrankCheck.state == .on ? "lowrank-initial" : "original"
            if lowrankCheck.state == .on { selection.replaceMask = false }
        } else if sender === maskCheck {
            selection.replaceMask = maskCheck.state == .on
        } else if sender === finetunePopup {
            selection.model = finetunePopup.indexOfSelectedItem == 0 ? "finetune-a" : "finetune-b"
        } else if sender === lowrankPopup {
            selection.model = lowrankPopup.indexOfSelectedItem == 0 ? "lowrank-initial" : "lowrank-trained"
        } else {
            return
        }
        selectionChanged(selection)
        refresh()
    }

    @objc private func resetOptions() {
        guard !switchingBuild else { return }
        var selection = SPRifeExperiments.selection
        selection.ioOptimized = false
        selection.model = "original"
        selection.replaceMask = false
        selectionChanged(selection)
        refresh()
    }

    @objc private func buildChanged() {
        guard !switchingBuild else { return }
        switchingBuild = true
        refresh()
        showStatus(EnhancementText.t("Starting the other build…", "正在启动另一构建…"))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.switchBuild()
                NSApp.terminate(nil)
            } catch {
                self.switchingBuild = false
                self.refresh()
                self.showStatus(EnhancementText.t("Could not switch builds: ", "未能切换构建：") + error.localizedDescription, error: true)
            }
        }
    }
}
