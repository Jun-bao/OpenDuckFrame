import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Inline list: keep the ScreenCaptureKit identity associated with each row.
@MainActor
final class WindowSelectionList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let window: SCWindow
        let text: String
        let metadata: String
        let fillsDisplay: Bool
    }
    private let select: (SCWindow) -> Void
    private var entries: [Entry] = []
    private var loading = false
    private var updating = false
    private var selectedID: CGWindowID?
    private let table = NSTableView()
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
                    let text = "\(app.applicationName) — \(title)"
                    let metadata = "[\(Int(frame.width.rounded()))×\(Int(frame.height.rounded()))]\(mark)\(location)"
                    return Entry(window: window, text: text, metadata: metadata, fillsDisplay: full)
                }.sorted { left, right in
                    if left.fillsDisplay != right.fillsDisplay { return left.fillsDisplay }
                    return left.text.localizedStandardCompare(right.text) == .orderedAscending
                }
                self.updating = true
                self.table.reloadData()
                if let id = self.selectedID, let row = self.entries.firstIndex(where: { $0.window.windowID == id }) {
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.updating = false
                self.footer.stringValue = self.entries.isEmpty
                    ? EnhancementText.t("No windows found. Check Screen Recording permission, then refresh.", "没有找到窗口，请检查屏幕录制权限后刷新。")
                    : String(format: EnhancementText.t("%d windows · ★ estimated full screen first · includes off-screen windows", "共 %d 个窗口（★按尺寸估计全屏并优先；包含其他空间或未显示的窗口）"), self.entries.count)
            } catch {
                guard let self else { return }
                self.updating = true
                self.entries = []
                self.table.reloadData()
                self.updating = false
                self.footer.stringValue = EnhancementText.t("Unable to list windows. Check Screen Recording permission.", "无法获取窗口，请检查屏幕录制权限。")
                self.footer.toolTip = error.localizedDescription
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let label = NSTextField(labelWithString: entry.text)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let metadata = NSTextField(labelWithString: entry.metadata)
        metadata.font = .systemFont(ofSize: 13)
        metadata.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let line = NSStackView(views: [label, metadata])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.toolTip = entry.text + "  " + entry.metadata
        return line
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard !updating, entries.indices.contains(row) else { return }
        selectedID = entries[row].window.windowID
        select(entries[row].window)
    }
}
