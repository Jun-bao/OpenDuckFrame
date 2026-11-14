import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

@MainActor
private final class WindowSelectionTable: NSTableView {
    var groupKeyAction: ((Int, UInt16) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if [UInt16(123), 124, 49, 36, 76].contains(event.keyCode),
           groupKeyAction?(selectedRow, event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

/// Inline list: keep the ScreenCaptureKit identity associated with each row.
@MainActor
final class WindowSelectionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let window: SCWindow
        let title: String
        let appName: String
        let appKey: String
        let metadata: String
        let fillsDisplay: Bool
    }
    private struct Group {
        let key: String
        let name: String
        let entries: [Entry]
    }
    private enum Row {
        case group(Group)
        case window(Entry)
    }
    private let select: (SCWindow) -> Void
    private var entries: [Entry] = []
    private var rows: [Row] = []
    private var expandedGroups: Set<String> = []
    private var loading = false
    private var updating = false
    private var selectedID: CGWindowID?
    private let table = WindowSelectionTable()
    private let footer = NSTextField(labelWithString: "")

    init(select: @escaping (SCWindow) -> Void) {
        self.select = select
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: EnhancementText.t("Target window", "目标窗口"))
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let refresh = NSButton(title: EnhancementText.t("Refresh list", "刷新列表"), target: self, action: #selector(refreshRequested))
        refresh.bezelStyle = .rounded
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self
        table.delegate = self
        table.groupKeyAction = { [weak self] row, key in self?.handleGroupKey(row: row, key: key) ?? false }
        table.focusRingType = .default
        scroll.documentView = table
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        footer.lineBreakMode = .byTruncatingTail
        for view in [heading, refresh, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 218),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            heading.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            refresh.trailingAnchor.constraint(equalTo: trailingAnchor),
            refresh.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    @objc private func refreshRequested() {
        reloadWindows()
    }

    @objc func reloadWindows() {
        guard !loading else { return }
        loading = true
        guard ScreenCapturePermission.shared.ensureAccess() else {
            loading = false
            updating = true
            entries = []
            rows = []
            table.reloadData()
            updating = false
            footer.stringValue = EnhancementText.t("Allow Screen Recording in System Settings, then restart the app.", "请在系统设置中允许录屏，然后重新打开应用。")
            return
        }
        footer.stringValue = EnhancementText.t("Loading windows…", "正在获取窗口…")
        Task { @MainActor [weak self] in
            defer { self?.loading = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let self else { return }
                let bounds = content.displays.map { CGDisplayBounds($0.displayID) }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                self.entries = content.windows.compactMap { window in
                    guard let app = window.owningApplication, app.processID != ownPID,
                          app.bundleIdentifier != Bundle.main.bundleIdentifier,
                          window.windowLayer == 0, window.frame.width >= 100, window.frame.height >= 80,
                          let title = window.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    let frame = window.frame
                    // Screen-sized geometry is an estimate; ScreenCaptureKit does not expose Space type.
                    let full = bounds.contains { abs(frame.width - $0.width) <= 2 && abs(frame.height - $0.height) <= 2 && abs(frame.minX - $0.minX) <= 2 && abs(frame.minY - $0.minY) <= 2 }
                    let location = window.isOnScreen ? "" : EnhancementText.t(" · Off screen / another Space", " · 其他空间或未显示")
                    let mark = full ? EnhancementText.t("  ★ Full screen", "  ★全屏") : ""
                    let appKey = app.bundleIdentifier.isEmpty ? app.applicationName : app.bundleIdentifier
                    let metadata = "[\(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))]\(mark)\(location)"
                    return Entry(window: window, title: title, appName: app.applicationName, appKey: appKey, metadata: metadata, fillsDisplay: full)
                }.sorted { left, right in
                    if left.fillsDisplay != right.fillsDisplay { return left.fillsDisplay }
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
                self.rebuildRows()
                self.footer.stringValue = self.entries.isEmpty
                    ? EnhancementText.t("No windows found. Check Screen Recording permission, then refresh.", "没有找到窗口，请检查屏幕录制权限后刷新。")
                    : String(format: EnhancementText.t("%d windows · ★ estimated full screen first · includes off-screen windows", "共 %d 个窗口（★按尺寸估计全屏并优先；包含其他空间或未显示的窗口）"), self.entries.count)
            } catch {
                guard let self else { return }
                self.updating = true
                self.entries = []
                self.rows = []
                self.table.reloadData()
                self.updating = false
                self.footer.stringValue = EnhancementText.t("Unable to list windows. Check Screen Recording permission.", "无法获取窗口，请检查屏幕录制权限。")
                self.footer.toolTip = error.localizedDescription
            }
        }
    }
    private func rebuildRows(focusGroup: String? = nil) {
        let groups = Dictionary(grouping: entries, by: \.appKey).map { key, entries in
            Group(key: key, name: entries[0].appName, entries: entries)
        }.sorted { left, right in
            let leftFull = left.entries.contains { $0.fillsDisplay }
            let rightFull = right.entries.contains { $0.fillsDisplay }
            if leftFull != rightFull { return leftFull }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        rows = groups.flatMap { group in
            [.group(group)] + (expandedGroups.contains(group.key) ? group.entries.map { .window($0) } : [])
        }
        updating = true
        table.reloadData()
        if let key = focusGroup, let row = rows.firstIndex(where: {
            if case let .group(group) = $0 { return group.key == key }
            return false
        }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else if let id = selectedID, let row = rows.firstIndex(where: {
            if case let .window(entry) = $0 { return entry.window.windowID == id }
            return false
        }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updating = false
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case let .group(group) = rows[sender.tag] else { return }
        setGroup(group, expanded: !expandedGroups.contains(group.key))
    }

    private func setGroup(_ group: Group, expanded: Bool) {
        if expanded { expandedGroups.insert(group.key) }
        else { expandedGroups.remove(group.key) }
        rebuildRows(focusGroup: group.key)
    }

    private func handleGroupKey(row: Int, key: UInt16) -> Bool {
        guard rows.indices.contains(row), case let .group(group) = rows[row] else { return false }
        switch key {
        case 123: setGroup(group, expanded: false)
        case 124: setGroup(group, expanded: true)
        default: setGroup(group, expanded: !expandedGroups.contains(group.key))
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .group(group):
            let button = NSButton(title: "\(group.name)  (\(group.entries.count))", target: self, action: #selector(toggleGroup(_:)))
            button.isBordered = false
            button.alignment = .left
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            button.font = font
            if let pid = group.entries.first?.window.owningApplication?.processID,
               let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                let title = NSMutableAttributedString(attachment: attachment)
                title.append(NSAttributedString(string: "  \(group.name)  (\(group.entries.count))", attributes: [.font: font]))
                button.attributedTitle = title
            }
            button.image = NSImage(systemSymbolName: expandedGroups.contains(group.key) ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.tag = row
            button.toolTip = group.name
            return button
        case let .window(entry):
            let label = NSTextField(labelWithString: entry.title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let metadata = NSTextField(labelWithString: entry.metadata)
            metadata.font = .systemFont(ofSize: 13)
            metadata.lineBreakMode = .byTruncatingTail
            metadata.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let line = NSStackView(views: [label, metadata])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            line.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
            line.toolTip = entry.appName + " — " + entry.title + "  " + entry.metadata
            return line
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard !updating, rows.indices.contains(row), case let .window(entry) = rows[row] else { return }
        selectedID = entry.window.windowID
        select(entry.window)
    }
}
