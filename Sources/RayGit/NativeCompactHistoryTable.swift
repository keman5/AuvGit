import AppKit
import SwiftUI
import GitCore
import RayGitLocalization

/// Compact history keeps native rows alive when repository commit identities change.
struct NativeCompactHistoryTable: NSViewRepresentable {
    let commits: [GitCommit]
    let graph: CommitGraph
    let styles: HistoryGraphStylePlan
    @Binding var selection: String?
    let navigationGeneration: UUID?
    let graphWidth: CGFloat
    let nameWidth: CGFloat
    let dateWidth: CGFloat
    let showAvatars: Bool
    let showNames: Bool
    let showRemoteLabels: Bool
    let showTagLabels: Bool
    let isBusy: Bool
    let hasMore: Bool
    let isLoading: Bool
    let onLoadMore: () -> Void
    let onAction: (HistoryAction, GitCommit) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = CompactHistoryTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = HistoryColumnLayout.rowHeight(compact: true)
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("history"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.showCommit)
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.requestMore() }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updatingSelection = true
        let changed = previous.commits != commits
        if changed {
            if previous.commits.first?.hash != commits.first?.hash { coordinator.gate.reset() }
            table.reloadData()
        } else {
            // Appearance and selection updates reuse the visible native cells too.
            let visibleRows = table.rows(in: table.visibleRect)
            for row in visibleRows.location..<NSMaxRange(visibleRows) where row < table.numberOfRows {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CompactHistoryCell {
                    cell.configure(parent: self, index: row)
                }
            }
        }
        let row = commits.firstIndex { $0.hash == selection }
        table.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        coordinator.updatingSelection = false
        if previous.navigationGeneration != navigationGeneration { coordinator.pendingScroll = true }
        if coordinator.pendingScroll || coordinator.appliedSelection != selection, let row {
            coordinator.pendingScroll = false
            table.scrollRowToVisible(row)
        }
        coordinator.appliedSelection = selection
        coordinator.requestMore()
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NativeCompactHistoryTable
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        var updatingSelection = false
        var pendingScroll = true
        var appliedSelection: String?
        var gate = HistoryPaginationGate(prefetchDistance: 10)
        init(_ parent: NativeCompactHistoryTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.commits.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("commit")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CompactHistoryCell ?? CompactHistoryCell()
            cell.identifier = identifier
            cell.configure(parent: parent, index: row)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CompactHistoryRowView() }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table else { return }
            let row = table.selectedRow
            parent.selection = parent.commits.indices.contains(row) ? parent.commits[row].hash : nil
        }
        @objc func showCommit() {
            guard let table, parent.commits.indices.contains(table.clickedRow) else { return }
            parent.onAction(.show, parent.commits[table.clickedRow])
        }
        func requestMore() {
            guard let table else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.length > 0, gate.shouldRequestMore(visibleIndex: NSMaxRange(rows) - 1, commitCount: parent.commits.count, hasMore: parent.hasMore, isLoading: parent.isLoading) else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.onLoadMore() }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard parent.commits.indices.contains(row) else { return }
            let commit = parent.commits[row]
            let actions: [HistoryAction] = [.viewLog, .show, .reset, .resetAdvanced, .createBranch, .createTag, .checkout, .rebase, .cherryPick, .revert, .copyHash, .copyMessage, .useCommitMessage]
            for action in actions {
                if [.reset, .copyHash].contains(action) { menu.addItem(.separator()) }
                let title: String
                switch action {
                case .viewLog: title = sidebarRefinementText("viewLog")
                case .show: title = sidebarRefinementText("commitDetails")
                case .rebase: title = designText("Interactive Rebase")
                case .useCommitMessage: title = shortcutText("Use Message for Commit")
                default: title = historyActionText(action.rawValue)
                }
                let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
                item.target = self
                if let command = ShortcutCommand(rawValue: action.rawValue) {
                    let binding = KeyboardShortcuts.shared.binding(command)
                    if binding.isAssigned {
                        item.keyEquivalent = String(binding.character)
                        item.keyEquivalentModifierMask = binding.eventModifiers
                    }
                }
                item.representedObject = (action, commit)
                item.isEnabled = !action.isMutation || !parent.isBusy
                menu.addItem(item)
            }
            menu.autoenablesItems = false
        }
        @objc func performAction(_ item: NSMenuItem) {
            guard let (action, commit) = item.representedObject as? (HistoryAction, GitCommit), !action.isMutation || !parent.isBusy else { return }
            parent.onAction(action, commit)
        }
    }
}

private final class CompactHistoryTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

final class CompactHistoryCell: NSView {
    private var parent: NativeCompactHistoryTable?
    var displayedCommitHash: String? {
        guard let parent, parent.commits.indices.contains(index) else { return nil }
        return parent.commits[index].hash
    }
    private var index = 0
    private var avatarURL: URL?
    private var avatar: NSImage?
    private var avatarTask: Task<Void, Never>?
    override var isFlipped: Bool { true }
    func configure(parent: NativeCompactHistoryTable, index: Int) {
        self.parent = parent
        self.index = index
        let commit = parent.commits[index]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L10n.text("history.commitAccessibility", table: "Detail", arguments: [commit.subject, commit.author, commit.shortHash]))
        toolTip = commit.subject + "\n" + commit.author + " <" + commit.authorEmail + ">\n" + HistoryCalendarDate.text(commit.committedDate)
        let url = parent.showAvatars ? CommitAvatarIdentity.url(email: commit.authorEmail) : nil
        if avatarURL != url {
            avatarTask?.cancel()
            avatarURL = url
            avatar = url.flatMap { CommitAvatarCache.shared.cachedImage(for: $0) }
            if avatar == nil, let url {
                avatarTask = Task { @MainActor [weak self] in
                    let image = await CommitAvatarCache.shared.image(for: url)
                    guard !Task.isCancelled, self?.avatarURL == url else { return }
                    self?.avatar = image
                    self?.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let parent, parent.commits.indices.contains(index), parent.graph.rows.indices.contains(index) else { return }
        let commit = parent.commits[index]
        let row = parent.graph.rows[index]
        let selected = parent.selection == commit.hash
        let primary: NSColor = selected ? .white : .labelColor
        let secondary: NSColor = selected ? .white : .secondaryLabelColor
        let halo = NSColor(selected ? RayGitStyle.blue : RayGitStyle.canvas)
        let widths = HistoryColumnLayout.graphMessageWidths(activeLaneCount: row.laneCount, maximumLaneCount: parent.graph.laneCount, maximumGraphWidth: parent.graphWidth, baseMessageWidth: 220)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 12, y: 0, width: widths.graph, height: bounds.height).clip()
        let spacing = HistoryColumnLayout.laneSpacing
        for segment in row.segments {
            let start = NSPoint(x: 12 + spacing / 2 + CGFloat(segment.fromLane) * spacing, y: bounds.height * segment.fromY)
            let end = NSPoint(x: 12 + spacing / 2 + CGFloat(segment.toLane) * spacing, y: bounds.height * segment.toY)
            let path = NSBezierPath()
            path.move(to: start)
            path.curve(to: end, controlPoint1: .init(x: start.x, y: (start.y + end.y) / 2), controlPoint2: .init(x: end.x, y: (start.y + end.y) / 2))
            let style = parent.styles.lineStyle(for: segment.lineageHash)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = style.lineWidth + 4
            halo.setStroke(); path.stroke()
            path.lineWidth = style.lineWidth
            path.setLineDash(style.dashPattern.map { CGFloat($0) }, count: style.dashPattern.count, phase: CGFloat(style.variant * 2))
            NSColor(style.color.color).setStroke(); path.stroke()
        }
        let node = parent.styles.nodeStyle(for: row.hash)
        let point = NSRect(x: 12 + spacing / 2 - 5 + CGFloat(row.nodeLane) * spacing, y: bounds.height / 2 - 5, width: 10, height: 10)
        halo.setFill(); NSBezierPath(ovalIn: point.insetBy(dx: -2.5, dy: -2.5)).fill()
        NSColor(node.color.color).setFill(); NSColor(node.color.color).setStroke()
        switch node.kind {
        case .ordinary: NSBezierPath(ovalIn: point).fill()
        case .merge, .remoteOnly:
            let circle = NSBezierPath(ovalIn: point); circle.lineWidth = 2.5; circle.stroke()
            if node.kind == .merge { NSBezierPath(ovalIn: point.insetBy(dx: 3, dy: 3)).fill() }
        }
        if node.isHead { let ring = NSBezierPath(ovalIn: point.insetBy(dx: -3.5, dy: -3.5)); ring.lineWidth = 2; ring.stroke() }
        NSGraphicsContext.restoreGraphicsState()
        var x = 12 + widths.graph + 4
        let messageEnd = x + widths.message
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: x, y: 0, width: widths.message, height: bounds.height).clip()
        if let ref = commit.refs.first(where: { (parent.showRemoteLabels || !parent.styles.isRemoteReference($0)) && (parent.showTagLabels || !parent.styles.isTagReference($0)) }) {
            let label = ref.hasPrefix("tag: ") ? "tag " + String(ref.dropFirst(5)) : ref.replacingOccurrences(of: " -> ", with: " → ")
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            let width = min(90, (label as NSString).size(withAttributes: [.font: font]).width + 10)
            let rect = NSRect(x: x, y: (bounds.height - 18) / 2, width: width, height: 18)
            let tint = NSColor(parent.styles.referenceStyle(for: ref, commitHash: commit.hash).color.color)
            let badge = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (selected ? NSColor.white.withAlphaComponent(0.92) : tint.withAlphaComponent(0.13)).setFill(); badge.fill()
            tint.withAlphaComponent(0.8).setStroke(); badge.lineWidth = 0.8; badge.stroke()
            drawText(label, x: x + 5, width: width - 10, font: font, color: tint)
            x += width + 5
        }
        drawText(commit.subject, x: x, width: max(0, messageEnd - x), font: .systemFont(ofSize: 12), color: primary)
        NSGraphicsContext.restoreGraphicsState()
        x = messageEnd + 4
        let identityWidth = min(100, (parent.showAvatars ? 18 : 0) + (parent.showNames ? parent.nameWidth : 0) + (parent.showAvatars && parent.showNames ? 4 : 0))
        if parent.showAvatars || parent.showNames {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: 0, width: identityWidth, height: bounds.height).clip()
            if parent.showAvatars {
                let rect = NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                (avatar ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil))?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            if parent.showNames { drawText(commit.author, x: x + (parent.showAvatars ? 22 : 0), width: parent.nameWidth, font: .systemFont(ofSize: 10), color: primary) }
            NSGraphicsContext.restoreGraphicsState()
            x += identityWidth + 4
        }
        drawText(HistoryCalendarDate.text(commit.committedDate), x: x, width: parent.dateWidth, font: .systemFont(ofSize: 10), color: secondary)
        x += parent.dateWidth + 4
        drawText(commit.shortHash, x: x, width: 75, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: secondary)
    }
    private func drawText(_ value: String, x: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let textHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: x, y: (bounds.height - textHeight) / 2, width: width, height: textHeight))
    }
}

private final class CompactHistoryRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(RayGitStyle.blue).setFill()
        bounds.fill()
    }
}
