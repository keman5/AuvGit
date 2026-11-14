import AppKit
import SwiftUI
import GitCore
import AuvGitLocalization

struct HistoryNativeReferenceBadge {
    let reference: String
    let label: String
    let state: String
    let labelWidth: CGFloat
    let stateWidth: CGFloat
    var width: CGFloat { labelWidth + stateWidth + 10 }
}

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

    var virtualRows: [HistoryVirtualRow] = []
    var selectedCommitIDs: Set<String> = []
    var onSelectCommits: ((Set<String>) -> Void)? = nil
    var identityMode: HistoryIdentityMode = .author
    var showEmails: Bool = false
    var showDate: Bool = true
    var showHash: Bool = true
    var showOverlap: Bool = false
    var overlapValues: [String: Int] = [:]
    var overlapIsLoading: Bool = false
    var collapsedCounts: [String: Int] = [:]
    var collapsedMerges: Set<String> = []
    var onToggleMerge: ((String) -> Void)? = nil
    var onGraphDrop: ((HistoryGraphDropRequest) -> Void)? = nil
    var currentBranch: GitBranch? = nil
    var branches: [GitBranch] = []
    var compact: Bool = true
    var messageWidth: CGFloat = 360
    var identityWidth: CGFloat = 110
    var hashWidth: CGFloat = 75
    var requiresSelectionActivation: Bool = false
    var rowIDs: [String] { virtualRows.map(\.id) + commits.map(\.hash) }
    func commit(at row: Int) -> GitCommit? {
        let index = row - virtualRows.count
        return commits.indices.contains(index) ? commits[index] : nil
    }
    func virtual(at row: Int) -> HistoryVirtualRow? { virtualRows.indices.contains(row) ? virtualRows[row] : nil }
    func mergeCount(_ commit: GitCommit) -> Int? { collapsedMerges.contains(commit.hash) ? collapsedCounts[commit.hash] ?? 0 : nil }

    func referenceBadges(_ commit: GitCommit) -> [HistoryNativeReferenceBadge] {
        let visible = commit.refs.filter { styles.isVisibleReference($0) && (showRemoteLabels || !styles.isRemoteReference($0)) && (showTagLabels || !styles.isTagReference($0)) }
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        return (compact ? Array(visible.prefix(1)) : visible).map { ref in
            let canonical = HistoryGraphStylePlan.canonicalReference(ref).replacingOccurrences(of: "HEAD -> ", with: "")
            let branch = branches.first { !$0.isRemote && "refs/heads/" + $0.name == canonical } ?? currentBranch.flatMap { canonical == "refs/heads/" + $0.name || canonical == $0.name ? $0 : nil }
            let state: String
            if let branch, branch.upstream != nil, let ahead = branch.ahead, let behind = branch.behind {
                state = ahead == 0 && behind == 0 ? " =" : " ↑\(ahead) ↓\(behind)"
            } else { state = "" }
            let label = styles.referenceLabel(ref)
            return HistoryNativeReferenceBadge(reference: ref, label: label, state: state,
                labelWidth: min(80, (label as NSString).size(withAttributes: [.font: font]).width),
                stateWidth: (state as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = CompactHistoryTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = HistoryColumnLayout.rowHeight(compact: compact)
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("history"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.showCommit)
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        table.registerForDraggedTypes([HistoryGraphDragPayload.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.graphClick = { [weak coordinator = context.coordinator] row, x in
            guard let coordinator, let commit = coordinator.parent.commit(at: row), commit.parents.count > 1,
                  x < coordinator.parent.graphWidth + 8 else { return false }
            coordinator.parent.onToggleMerge?(commit.hash)
            return coordinator.parent.onToggleMerge != nil
        }
        table.didClickSelection = { [weak coordinator = context.coordinator] row in
            coordinator?.activateSelectionFromExplicitClick(row: row)
        }
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
        if previous.navigationGeneration != navigationGeneration || (!previous.requiresSelectionActivation && requiresSelectionActivation) {
            coordinator.didDeliverSelectionActivation = false
        }
        guard let table = coordinator.table else { return }
        table.rowHeight = HistoryColumnLayout.rowHeight(compact: compact)
        coordinator.updatingSelection = true
        if previous.navigationGeneration != navigationGeneration {
            coordinator.rangeSelection = .init()
        }
        coordinator.rangeSelection.synchronize(primary: selection, orderedIDs: rowIDs)
        if !selectedCommitIDs.isEmpty {
            coordinator.rangeSelection.select(selectedCommitIDs, orderedIDs: rowIDs, preferred: selection)
        }
        let changed = previous.commits != commits || previous.virtualRows != virtualRows
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
        let row = rowIDs.firstIndex { $0 == selection }
        table.selectRowIndexes(IndexSet(rowIDs.indices.filter { coordinator.rangeSelection.ids.contains(rowIDs[$0]) }), byExtendingSelection: false)
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
        var didDeliverSelectionActivation = false
        var pendingScroll = true
        var appliedSelection: String?
        var rangeSelection = ListSelectionState<String>()
        var gate = HistoryPaginationGate(prefetchDistance: 10)
        init(_ parent: NativeCompactHistoryTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rowIDs.count }
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
            let ids = Set(table.selectedRowIndexes.compactMap { parent.rowIDs.indices.contains($0) ? parent.rowIDs[$0] : nil })
            let clicked = parent.rowIDs.indices.contains(table.clickedRow) ? parent.rowIDs[table.clickedRow] : nil
            guard ids != rangeSelection.ids else { return }
            parent.selection = rangeSelection.select(ids, orderedIDs: parent.rowIDs, preferred: clicked)
            didDeliverSelectionActivation = true
            parent.onSelectCommits?(ids)
        }
        /// Clicking the initially auto-selected HEAD is an explicit request to
        /// open its journal files, even though the native selection is unchanged.
        func activateSelectionFromExplicitClick(row: Int) {
            guard !updatingSelection, parent.requiresSelectionActivation, !didDeliverSelectionActivation,
                  let table, parent.rowIDs.indices.contains(row), table.selectedRowIndexes.contains(row) else { return }
            let orderedIDs = parent.rowIDs
            let ids = Set(table.selectedRowIndexes.compactMap { orderedIDs.indices.contains($0) ? orderedIDs[$0] : nil })
            guard !ids.isEmpty, ids == rangeSelection.ids else { return }
            didDeliverSelectionActivation = true
            parent.onSelectCommits?(ids)
        }
        @objc func showCommit() {
            guard let table, let commit = parent.commit(at: table.clickedRow) else { return }
            parent.onAction(.viewLog, commit)
        }
        func requestMore() {
            guard let table else { return }
            let rows = table.rows(in: table.visibleRect)
            guard rows.length > 0, gate.shouldRequestMore(visibleIndex: NSMaxRange(rows) - 1, commitCount: parent.rowIDs.count, hasMore: parent.hasMore, isLoading: parent.isLoading) else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.onLoadMore() }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard let commit = parent.commit(at: row) else { return }
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
                item.representedObject = (action, commit, parent.navigationGeneration)
                item.isEnabled = (!action.isMutation || !parent.isBusy)
                    && (table.selectedRowIndexes.count <= 1 || [.copyHash, .copyMessage].contains(action))
                menu.addItem(item)
            }
            if commit.parents.count > 1, parent.onToggleMerge != nil {
                menu.addItem(.separator())
                let item = NSMenuItem(title: graphFeatureText(parent.collapsedMerges.contains(commit.hash) ? "Expand merge path" : "Collapse merge path"), action: #selector(toggleMerge(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = (commit.hash, parent.navigationGeneration)
                menu.addItem(item)
            }
            menu.autoenablesItems = false
        }
        @objc func toggleMerge(_ item: NSMenuItem) {
            guard let (hash, generation) = item.representedObject as? (String, UUID?), generation == parent.navigationGeneration,
                  parent.commits.contains(where: { $0.hash == hash }) else { return }
            parent.onToggleMerge?(hash)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.onGraphDrop != nil, !parent.isBusy, let commit = parent.commit(at: row) else { return nil }
            let point = (tableView as? CompactHistoryTableView)?.mouseOrigin ?? .zero
            let source: HistoryGraphDragSource
            let graphRow = parent.graph.rows[row - parent.virtualRows.count]
            let widths = HistoryColumnLayout.graphMessageWidths(activeLaneCount: graphRow.laneCount, maximumLaneCount: parent.graph.laneCount,
                maximumGraphWidth: parent.graphWidth, baseMessageWidth: parent.compact ? 220 : parent.messageWidth)
            var badgeX = HistoryColumnLayout.leadingInset + widths.graph + 4
            var hitReference: String?
            for badge in parent.referenceBadges(commit) {
                if point.x >= badgeX && point.x < badgeX + badge.width { hitReference = badge.reference; break }
                badgeX += badge.width + 5
            }
            if point.x < widths.graph + 4, parent.styles.isCurrentCommit(commit.hash) { source = .head }
            else if let ref = hitReference {
                guard !parent.styles.isRemoteReference(ref), !parent.styles.isTagReference(ref), !ref.hasSuffix("~") else { return nil }
                let raw = HistoryGraphStylePlan.canonicalReference(ref).replacingOccurrences(of: "HEAD -> ", with: "")
                source = raw == "HEAD" || parent.styles.isCurrentReference(ref) ? .head : .localBranch(raw.hasPrefix("refs/heads/") ? raw : "refs/heads/" + raw)
            } else {
                let ids = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes.compactMap { parent.commit(at: $0)?.hash } : [commit.hash]
                source = .commits(ids)
            }
            let item = NSPasteboardItem()
            guard let data = try? JSONEncoder().encode(HistoryGraphDragPayload(source: source, generation: parent.navigationGeneration)) else { return nil }
            item.setData(data, forType: HistoryGraphDragPayload.pasteboardType)
            return item
        }
        private func dropPayload(_ info: NSDraggingInfo, row: Int) -> HistoryGraphDragPayload? {
            guard parent.onGraphDrop != nil, !parent.isBusy, let commit = parent.commit(at: row),
                  let data = info.draggingPasteboard.data(forType: HistoryGraphDragPayload.pasteboardType),
                  let payload = try? JSONDecoder().decode(HistoryGraphDragPayload.self, from: data),
                  payload.generation == parent.navigationGeneration else { return nil }
            if case .commits(let ids) = payload.source, ids.contains(commit.hash) || ids.isEmpty { return nil }
            return payload
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropPayload(info, row: row) != nil else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let payload = dropPayload(info, row: row), let commit = parent.commit(at: row), let operation = payload.source.operations.first else { return false }
            parent.onGraphDrop?(HistoryGraphDropRequest(source: payload.source, targetCommitID: commit.hash, operation: operation))
            return true
        }
        @objc func performAction(_ item: NSMenuItem) {
            guard item.isEnabled,
                  let (action, commit, generation) = item.representedObject as? (HistoryAction, GitCommit, UUID?),
                  generation == parent.navigationGeneration,
                  parent.commits.contains(where: { $0.hash == commit.hash }),
                  !action.isMutation || !parent.isBusy else { return }
            if let table, table.selectedRowIndexes.count > 1 {
                guard [.copyHash, .copyMessage].contains(action) else { return }
                let selected = table.selectedRowIndexes.compactMap { parent.commit(at: $0) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected.map { action == .copyHash ? $0.hash : $0.subject }.joined(separator: "\n"), forType: .string)
                return
            }
            parent.onAction(action, commit)
        }
    }
}

private final class CompactHistoryTableView: NSTableView {
    var graphClick: ((Int, CGFloat) -> Bool)?
    var didClickSelection: ((Int) -> Void)?
    var mouseOrigin = NSPoint.zero
    override func mouseDown(with event: NSEvent) {
        mouseOrigin = convert(event.locationInWindow, from: nil)
        let row = self.row(at: mouseOrigin)
        if row >= 0, graphClick?(row, mouseOrigin.x) == true { return }
        super.mouseDown(with: event)
        if row >= 0 { didClickSelection?(row) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

final class CompactHistoryCell: NSView {
    private(set) var drawnSelection: Bool?
    private var parent: NativeCompactHistoryTable?
    var displayedCommitHash: String? {
        guard let parent else { return nil }
        return parent.commit(at: index)?.hash
    }
    private var index = 0
    private var avatarURL: URL?
    private var avatar: NSImage?
    private var avatarTask: Task<Void, Never>?
    override var isFlipped: Bool { true }
    func configure(parent: NativeCompactHistoryTable, index: Int) {
        self.parent = parent
        self.index = index
        guard let commit = parent.commit(at: index) else {
            avatarTask?.cancel(); avatarURL = nil; avatar = nil
            let title = parent.virtual(at: index).map { graphFeatureText($0 == .workingTree ? "Working Tree" : "Index") } ?? ""
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(title); toolTip = title
            needsDisplay = true; return
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L10n.text("history.commitAccessibility", table: "Detail", arguments: [commit.subject, commit.author, commit.shortHash]))
        toolTip = commit.subject + "\n" + parent.identityMode.name(commit) + " <" + parent.identityMode.email(commit) + ">\n" + HistoryCalendarDate.text(commit.committedDate) + "\n" + graphFeatureText("Signature") + ": " + (commit.signatureStatus == "signed" ? graphFeatureText("Signed (not verified)") : commit.signatureStatus)
        let url = parent.showAvatars ? CommitAvatarIdentity.url(email: parent.identityMode.email(commit)) : nil
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
        guard let parent else { return }
        if let virtual = parent.virtual(at: index) { drawVirtual(virtual, parent: parent); return }
        let graphIndex = index - parent.virtualRows.count
        guard let commit = parent.commit(at: index), parent.graph.rows.indices.contains(graphIndex) else { return }
        let row = parent.graph.rows[graphIndex]
        let selected = (superview as? NSTableRowView)?.isSelected ?? (parent.selection == commit.hash)
        drawnSelection = selected
        let primary: NSColor = selected ? .white : .labelColor
        let secondary: NSColor = selected ? .white : .secondaryLabelColor
        let widths = HistoryColumnLayout.graphMessageWidths(activeLaneCount: row.laneCount, maximumLaneCount: parent.graph.laneCount, maximumGraphWidth: parent.graphWidth, baseMessageWidth: parent.compact ? 220 : parent.messageWidth)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: HistoryColumnLayout.leadingInset, y: 0, width: widths.graph, height: bounds.height).clip()
        HistoryGraphPainter.draw(row: row, styles: parent.styles, rowIndex: graphIndex, height: bounds.height, selected: selected, inset: HistoryColumnLayout.leadingInset)
        NSGraphicsContext.restoreGraphicsState()
        if !parent.virtualRows.isEmpty, let headIndex = parent.commits.firstIndex(where: { parent.styles.isCurrentCommit($0.hash) }), graphIndex <= headIndex {
            drawVirtualConnection(parent: parent, selected: selected, endAtNode: graphIndex == headIndex)
        }
        var x = HistoryColumnLayout.leadingInset + widths.graph + 4
        let messageEnd = x + widths.message
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: x, y: 0, width: widths.message, height: bounds.height).clip()
        for badgeLayout in parent.referenceBadges(commit) {
            let ref = badgeLayout.reference
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            let width = badgeLayout.width
            let rect = NSRect(x: x, y: (bounds.height - 16) / 2, width: width, height: 16)
            let tint = NSColor(parent.styles.referenceStyle(for: ref, commitHash: commit.hash).color.color)
            let badge = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (selected ? NSColor.white.withAlphaComponent(0.92) : tint.withAlphaComponent(0.13)).setFill(); badge.fill()
            tint.withAlphaComponent(0.4).setStroke(); badge.lineWidth = 0.5; badge.stroke()
            drawText(badgeLayout.label, x: x + 5, width: badgeLayout.labelWidth, font: font, color: tint)
            drawText(badgeLayout.state, x: x + 5 + badgeLayout.labelWidth, width: badgeLayout.stateWidth, font: font, color: tint)
            x += width + 5
        }
        let collapsed = parent.mergeCount(commit)
        let fold = commit.parents.count > 1 ? (collapsed.map { "▸\($0) " } ?? "▾ ") : ""
        let signature = commit.signatureStatus == "N" || commit.signatureStatus.isEmpty ? "" : commit.signatureStatus == "signed" ? "◇ " : (commit.signatureStatus == "G" || commit.signatureStatus == "U" ? "✓ " : "⚠ ")
        let upstream: String
        if parent.styles.isCurrentCommit(commit.hash), let branch = parent.currentBranch, branch.upstream != nil {
            if let ahead = branch.ahead, let behind = branch.behind { upstream = ahead == 0 && behind == 0 ? " = " : " ↑\(ahead) ↓\(behind) " }
            else { upstream = " ↔ " }
        } else { upstream = "" }
        drawText(fold + signature + upstream + commit.subject, x: x, width: max(0, messageEnd - x), font: .systemFont(ofSize: 12), color: primary)
        NSGraphicsContext.restoreGraphicsState()
        x = messageEnd + 4
        let hasText = parent.showNames || parent.showEmails
        let identityWidth = parent.compact ? min(100, (parent.showAvatars ? 18 : 0) + (hasText ? parent.nameWidth : 0) + (parent.showAvatars && hasText ? 4 : 0)) : parent.identityWidth
        if parent.showAvatars || hasText {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: x, y: 0, width: identityWidth, height: bounds.height).clip()
            if parent.showAvatars {
                let rect = NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                let image = avatar ?? NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [secondary]))
                image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            if hasText { drawText(parent.identityMode.text(commit, names: parent.showNames, emails: parent.showEmails), x: x + (parent.showAvatars ? 22 : 0), width: max(0, identityWidth - (parent.showAvatars ? 22 : 0)), font: .systemFont(ofSize: parent.compact ? 10 : 12), color: primary) }
            NSGraphicsContext.restoreGraphicsState()
            x += identityWidth + 4
        }
        if parent.showDate { drawText(HistoryCalendarDate.text(commit.committedDate), x: x, width: parent.dateWidth, font: .systemFont(ofSize: 10), color: secondary)
        x += parent.dateWidth + 4 }
        // A concrete font avoids the system monospace descriptor conversion that
        // can throw in CoreText while sizing this custom-drawn cell on macOS 27.
        if parent.showHash { drawText(commit.shortHash, x: x, width: parent.hashWidth, font: NSFont(name: "Menlo-Regular", size: 11) ?? NSFont.userFixedPitchFont(ofSize: 11) ?? .systemFont(ofSize: 11), color: secondary)
            x += parent.hashWidth + 4
        }
        if parent.showOverlap {
            let value = commit.hash == parent.selection ? "●" : parent.overlapValues[commit.hash].map { $0 == 0 ? "—" : "⚠ \($0)" } ?? (parent.overlapIsLoading ? "…" : "")
            drawText(value, x: x, width: 65, font: .systemFont(ofSize: 11), color: secondary)
        }
    }
    private func drawVirtual(_ virtual: HistoryVirtualRow, parent: NativeCompactHistoryTable) {
        let selected = (superview as? NSTableRowView)?.isSelected ?? (parent.selection == virtual.id)
        drawnSelection = selected
        let color: NSColor = selected ? .white : .labelColor
        let headLane = parent.commits.firstIndex(where: { parent.styles.isCurrentCommit($0.hash) }).map { parent.graph.rows[$0].nodeLane } ?? 0
        let nodeX = HistoryColumnLayout.leadingInset + HistoryColumnLayout.laneSpacing / 2 + CGFloat(headLane) * HistoryColumnLayout.laneSpacing
        let line = NSBezierPath(); line.move(to: NSPoint(x: nodeX, y: index == 0 ? bounds.midY : 0)); line.line(to: NSPoint(x: nodeX, y: bounds.maxY)); line.lineWidth = 1.5
        color.withAlphaComponent(0.65).setStroke(); line.setLineDash([3, 2], count: 2, phase: 0); line.stroke()
        let rect = NSRect(x: nodeX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)
        color.setStroke(); let node = virtual == .index ? NSBezierPath(rect: rect) : NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2); node.lineWidth = 1.5; node.stroke()
        let title = graphFeatureText(virtual == .workingTree ? "Working Tree" : "Index")
        drawText(title, x: HistoryColumnLayout.leadingInset + parent.graphWidth + 4, width: max(0, bounds.width - parent.graphWidth - 12), font: .systemFont(ofSize: 12, weight: .medium), color: color)
    }
    private func drawVirtualConnection(parent: NativeCompactHistoryTable, selected: Bool, endAtNode: Bool) {
        guard let headIndex = parent.commits.firstIndex(where: { parent.styles.isCurrentCommit($0.hash) }) else { return }
        let x = HistoryColumnLayout.leadingInset + HistoryColumnLayout.laneSpacing / 2 + CGFloat(parent.graph.rows[headIndex].nodeLane) * HistoryColumnLayout.laneSpacing
        let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: 0)); path.line(to: NSPoint(x: x, y: endAtNode ? bounds.midY - 5 : bounds.maxY))
        path.lineWidth = 1; path.setLineDash([2, 3], count: 2, phase: CGFloat(index) * bounds.height)
        (selected ? NSColor.white : NSColor.secondaryLabelColor).setStroke(); path.stroke()
    }
    private func drawText(_ value: String, x: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        guard width > 0, !value.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        // These are single-line cells; font metrics suffice without a second
        // attributed-string typesetting pass merely to determine the height.
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        text.draw(in: NSRect(x: x, y: (bounds.height - textHeight) / 2, width: width, height: textHeight))
    }
}

final class CompactHistoryRowView: NativeSelectionRowView {
    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected { display() }
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(AuvGitStyle.blue).setFill()
        bounds.fill()
    }
}


enum HistoryGraphPainter {
    static func draw(row: CommitGraph.Row, styles: HistoryGraphStylePlan, rowIndex: Int, height: CGFloat, selected: Bool, inset: CGFloat = 0) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Erase only graph pixels in this layer, revealing the native row below.
        // Painting a guessed background leaves rings when List changes focus.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        func erase(_ path: NSBezierPath, stroke: Bool = false) {
            context.saveGState()
            context.setBlendMode(.clear)
            NSColor.black.setFill(); NSColor.black.setStroke()
            if stroke { path.stroke() } else { path.fill() }
            context.restoreGState()
        }
        let spacing = HistoryColumnLayout.laneSpacing
        for segment in row.segments {
            let start = NSPoint(x: inset + spacing / 2 + CGFloat(segment.fromLane) * spacing, y: height * segment.fromY)
            let end = NSPoint(x: inset + spacing / 2 + CGFloat(segment.toLane) * spacing, y: height * segment.toY)
            let path = NSBezierPath()
            path.move(to: start)
            path.curve(to: end, controlPoint1: .init(x: start.x, y: (start.y + end.y) / 2), controlPoint2: .init(x: end.x, y: (start.y + end.y) / 2))
            let style = styles.lineStyle(for: segment)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = style.lineWidth + 2
            erase(path, stroke: true)
            path.lineWidth = style.lineWidth
            path.lineCapStyle = .round
            path.setLineDash(style.dashPattern.map { CGFloat($0) }, count: style.dashPattern.count,
                phase: CGFloat(style.dashPhase(rowIndex: rowIndex, fromY: segment.fromY, rowHeight: Double(height))))
            let tint = selected && style.color != .orange && style.color != .green ? NSColor.white.withAlphaComponent(style.color == .blue ? 1 : 0.65) : NSColor(style.color.color)
            tint.setStroke(); path.stroke()
        }
        let node = styles.nodeStyle(for: row.hash)
        let diameter = HistoryColumnLayout.nodeDiameter(for: node.kind)
        let point = NSRect(x: inset + spacing / 2 - diameter / 2 + CGFloat(row.nodeLane) * spacing, y: height / 2 - diameter / 2, width: diameter, height: diameter)
        erase(NSBezierPath(ovalIn: point.insetBy(dx: -2, dy: -2)))
        let tint = selected && node.color != .orange && node.color != .green ? NSColor.white.withAlphaComponent(node.color == .blue ? 1 : 0.65) : NSColor(node.color.color)
        tint.setFill(); tint.setStroke()
        switch node.kind {
        case .ordinary: NSBezierPath(ovalIn: point).fill()
        case .merge:
            NSBezierPath(ovalIn: point).fill()
            erase(NSBezierPath(ovalIn: point.insetBy(dx: 1.5, dy: 1.5)))
            tint.setFill(); NSBezierPath(ovalIn: point.insetBy(dx: 2.8, dy: 2.8)).fill()
        case .remoteOnly:
            let circle = NSBezierPath(ovalIn: point); circle.lineWidth = 1.2; circle.stroke()
        }
        if node.isHead {
            let inset: CGFloat = node.kind == .merge ? -1 : -2
            let ring = NSBezierPath(ovalIn: point.insetBy(dx: inset, dy: inset)); ring.lineWidth = 1.2; ring.stroke()
        }
    }
}
