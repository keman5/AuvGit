import AppKit
import SwiftUI
import GitCore

struct NativeBranchTable: NSViewRepresentable {
    let branches: [GitBranch]
    let stashes: [GitStash]
    let repositoryPath: String?
    var repositoryIdentity: ObjectIdentifier? = nil
    let currentBranch: String
    let isBusy: Bool
    @Binding var localExpanded: Bool
    @Binding var remoteExpanded: Bool
    @Binding var stashesExpanded: Bool
    @Binding var selection: String?
    let onAction: (SidebarAction, String) -> Void
    let onRenameStash: (String) -> Void
    let onShortcut: (NSEvent) -> Bool

    struct Row: Equatable {
        let id: String
        let title: String
        let symbol: String
        var depth = 0
        var parentFolders: [String] = []
        var current = false
        var expanded: Bool? = nil
        var isGroup: Bool { expanded != nil }
        var target: String { String(id.dropFirst(id.firstIndex(of: ":").map { id.distance(from: id.startIndex, to: $0) + 1 } ?? 0)) }
    }
    var rows: [Row] { visibleRows(treeRows(), collapsed: []) }
    private func treeRows() -> [Row] {
        var result: [Row] = []
        for remote in [false, true] {
            let group = remote ? "remote" : "local"
            result.append(Row(id: "group:" + group, title: interactionText(remote ? "Remote Branches" : "Local Branches"), symbol: "", expanded: remote ? remoteExpanded : localExpanded))
            var folders = Set<String>()
            for branch in branches.filter({ $0.isRemote == remote }).sorted(by: { $0.name < $1.name }) {
                let parts = branch.name.split(separator: "/").map(String.init)
                var parents: [String] = []
                for index in 0..<max(0, parts.count - 1) {
                    let id = "folder:" + group + ":" + parts.prefix(index + 1).joined(separator: "/")
                    if folders.insert(id).inserted {
                        result.append(Row(id: id, title: parts[index], symbol: "folder", depth: index + 1, parentFolders: parents, expanded: true))
                    }
                    parents.append(id)
                }
                result.append(Row(id: (remote ? "remote:" : "branch:") + branch.name, title: parts.last ?? branch.name,
                    symbol: remote ? "network" : "arrow.triangle.branch", depth: parts.count, parentFolders: parents, current: branch.isCurrent))
            }
        }
        result.append(Row(id: "group:stash", title: interactionText("Stashes"), symbol: "", expanded: stashesExpanded))
        result += stashes.map { Row(id: "stash:" + $0.ref, title: $0.subject, symbol: "archivebox", depth: 1) }
        return result
    }
    private func visibleRows(_ tree: [Row], collapsed: Set<String>) -> [Row] {
        var groupExpanded = true
        return tree.compactMap { row in
            if row.id.hasPrefix("group:") { groupExpanded = row.expanded == true; return row }
            guard groupExpanded, row.parentFolders.allSatisfy({ !collapsed.contains($0) }) else { return nil }
            var value = row
            if row.isGroup { value.expanded = !collapsed.contains(row.id) }
            return value
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let table = Table()
        table.coordinator = context.coordinator
        table.headerView = nil; table.backgroundColor = .clear
        table.rowHeight = 24; table.usesAutomaticRowHeights = false; table.intercellSpacing = .zero
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("branch")); column.width = 250; table.addTableColumn(column)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.open)
        table.setAccessibilityLabel(interactionText("Branches"))
        scroll.documentView = table; context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Table: NSTableView {
        weak var coordinator: Coordinator?
        override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(row: row(at: convert(event.locationInWindow, from: nil))) }
        override func keyDown(with event: NSEvent) {
            guard window?.attachedSheet == nil else { super.keyDown(with: event); return }
            if coordinator?.parent.onShortcut(event) == true { return }
            if [123, 124].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               coordinator?.setExpanded(row: selectedRow, expanded: event.keyCode == 124) == true { return }
            if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                coordinator?.activate(row: selectedRow); return
            }
            super.keyDown(with: event)
        }
    }
    final class Cell: NSTableCellView {
        let disclosure = NSButton()
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        let check = NSImageView()
        var group = false
        var depth = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            disclosure.isBordered = false; disclosure.bezelStyle = .inline
            disclosure.imagePosition = .imageLeading; disclosure.alignment = .left
            disclosure.font = .systemFont(ofSize: 11, weight: .semibold)
            label.maximumNumberOfLines = 1
            icon.setAccessibilityElement(false); check.setAccessibilityElement(false)
            [disclosure, icon, label, check].forEach { addSubview($0) }; textField = label
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let indent = CGFloat(max(0, depth - 1)) * 14
            disclosure.frame = NSRect(x: 12 + CGFloat(depth) * 14, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 20 - CGFloat(depth) * 14), height: 20)
            icon.frame = NSRect(x: 28 + indent, y: (bounds.height - 14) / 2, width: 14, height: 14)
            let textHeight = ceil(label.cell?.cellSize.height ?? label.intrinsicContentSize.height)
            label.frame = NSRect(x: 48 + indent, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 56 - indent - (check.isHidden ? 0 : 18)), height: textHeight)
            check.frame = NSRect(x: bounds.width - 21, y: (bounds.height - 11) / 2, width: 11, height: 11)
        }
        func configure(_ row: Row, coordinator: Coordinator) {
            depth = row.depth
            group = row.isGroup; disclosure.isHidden = !group; icon.isHidden = group; label.isHidden = group
            check.isHidden = !row.current
            if let expanded = row.expanded {
                disclosure.title = row.title
                disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
                disclosure.contentTintColor = .secondaryLabelColor
                disclosure.setAccessibilityLabel(row.title)
                disclosure.setAccessibilityValue(sidebarRefinementText(expanded ? "Expanded" : "Collapsed"))
                disclosure.target = coordinator; disclosure.action = #selector(Coordinator.toggle(_:))
                disclosure.identifier = .init(row.id)
            } else {
                label.stringValue = row.title; label.font = .systemFont(ofSize: 12, weight: row.current ? .semibold : .regular)
                label.lineBreakMode = row.id.hasPrefix("stash:") ? .byTruncatingTail : .byTruncatingMiddle
                icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
                check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                check.contentTintColor = .controlAccentColor
            }
            setAccessibilityElement(!group); setAccessibilityRole(.staticText); setAccessibilityLabel(row.title)
            toolTip = row.isGroup ? row.title : row.target; needsLayout = true
        }
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor; icon.contentTintColor = label.textColor }
        }
    }
    final class RowView: NSTableRowView {
        var current = false
        override func drawBackground(in dirtyRect: NSRect) {
            if current { NSColor(RayGitStyle.blue).withAlphaComponent(0.12).setFill(); NSBezierPath(rect: bounds).fill() }
        }
    }
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeBranchTable
        var rows: [Row] = []
        var treeRows: [Row] = []
        var collapsedFolders: Set<String> = []
        private var displayedCollapsedFolders: Set<String> = []
        weak var table: NSTableView?
        var updating = false
        init(_ parent: NativeBranchTable) { self.parent = parent }
        func update(_ value: NativeBranchTable) {
            let repositoryChanged = parent.repositoryPath != value.repositoryPath
            let rebuild = treeRows.isEmpty || repositoryChanged || parent.branches != value.branches || parent.stashes != value.stashes
                || treeRows.first(where: { $0.id == "group:local" })?.expanded != value.localExpanded
                || treeRows.first(where: { $0.id == "group:remote" })?.expanded != value.remoteExpanded
                || treeRows.first(where: { $0.id == "group:stash" })?.expanded != value.stashesExpanded
            let currentChanged = repositoryChanged || parent.currentBranch != value.currentBranch
            parent = value
            if repositoryChanged { collapsedFolders = [] }
            if rebuild { treeRows = value.treeRows() }
            if currentChanged, let current = treeRows.first(where: { $0.current }) { collapsedFolders.subtract(current.parentFolders) }
            let newRows = rebuild || displayedCollapsedFolders != collapsedFolders ? value.visibleRows(treeRows, collapsed: collapsedFolders) : rows
            displayedCollapsedFolders = collapsedFolders
            guard let table else { rows = newRows; return }
            updating = true; defer { updating = false }
            let directoryID = table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) && rows[table.selectedRow].id.hasPrefix("folder:") ? rows[table.selectedRow].id : nil
            if rows != newRows { rows = newRows; table.reloadData() }
            let index = rows.firstIndex { !$0.isGroup && $0.id == parent.selection || parent.selection == nil && $0.id == directoryID }
            let selected = index.map { IndexSet(integer: $0) } ?? []
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && !rows[row].id.hasPrefix("group:") }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("branchCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell(frame: .zero)
            cell.identifier = id; cell.configure(rows[row], coordinator: self); return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = RowView(); view.current = rows[row].current; return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = rows.indices.contains(table.selectedRow) && !rows[table.selectedRow].isGroup ? rows[table.selectedRow].id : nil
        }
        @objc func toggle(_ button: NSButton) {
            switch button.identifier?.rawValue {
            case "group:local": parent.localExpanded.toggle()
            case "group:remote": parent.remoteExpanded.toggle()
            case "group:stash": parent.stashesExpanded.toggle()
            case let id? where id.hasPrefix("folder:"):
                if !collapsedFolders.insert(id).inserted { collapsedFolders.remove(id) }
                update(parent)
            default: return
            }
        }
        @discardableResult
        func setExpanded(row: Int, expanded: Bool) -> Bool {
            guard rows.indices.contains(row), let current = rows[row].expanded else { return false }
            if current != expanded {
                let button = NSButton(); button.identifier = .init(rows[row].id); toggle(button)
            }
            return true
        }
        @objc func open() { if let table { activate(row: table.clickedRow) } }
        func activate(row: Int) {
            guard rows.indices.contains(row) else { return }
            if let expanded = rows[row].expanded { setExpanded(row: row, expanded: !expanded); return }
            guard !parent.isBusy else { return }
            let value = rows[row]
            if value.id.hasPrefix("branch:") { parent.onAction(.checkout, value.target) }
            else if value.id.hasPrefix("remote:") { parent.onAction(.history, "refs/remotes/" + value.target) }
            else { parent.onAction(.stashShow, value.target) }
        }
        struct MenuAction {
            let repositoryPath: String?
            let repositoryIdentity: ObjectIdentifier?
            let row: Row
            let action: SidebarAction?
            let renameStash: Bool
        }
        func menu(row: Int) -> NSMenu? {
            guard rows.indices.contains(row), !rows[row].isGroup else { return nil }
            let value = rows[row]; let target = value.target
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ action: SidebarAction?, enabled: Bool = true, rename: Bool = false) {
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = enabled
                item.representedObject = MenuAction(repositoryPath: parent.repositoryPath, repositoryIdentity: parent.repositoryIdentity, row: value, action: action, renameStash: rename)
                menu.addItem(item)
            }
            if value.id.hasPrefix("stash:") {
                add(interactionText("Show Changes"), .stashShow)
                add(interactionText("Apply Stash…"), .stashApply, enabled: !parent.isBusy)
                add(shortcutText("Rename Stash"), nil, enabled: !parent.isBusy, rename: true)
                add(interactionText("Drop Stash…"), .stashDrop, enabled: !parent.isBusy)
            } else {
                let remote = value.id.hasPrefix("remote:")
                if !remote { add(interactionText("Check Out…"), .checkout, enabled: !parent.isBusy) }
                add(interactionText("Log"), .history, enabled: !parent.isBusy)
                if remote { add(sidebarRefinementText("Create Local Branch…"), .createLocalBranch, enabled: !parent.isBusy) }
                add(sidebarRefinementText("Merge into Current Branch"), .merge, enabled: !parent.isBusy && (remote || target != parent.currentBranch))
                add(sidebarRefinementText("Stop Tracking Remote Branch"), .stopTracking, enabled: !parent.isBusy)
                if !remote {
                    add(sidebarRefinementText("Set Tracking Branch…"), .setTracking, enabled: !parent.isBusy)
                    menu.addItem(.separator())
                    add(interactionText("Rename Branch…"), .rename, enabled: !parent.isBusy)
                    add(interactionText("Delete Branch…"), .delete, enabled: !parent.isBusy && !value.current)
                }
                menu.addItem(.separator()); add(interactionText("Copy Name"), .copy)
            }
            return menu
        }
        @objc func performMenuAction(_ item: NSMenuItem) {
            guard item.isEnabled, let payload = item.representedObject as? MenuAction,
                  payload.repositoryPath == parent.repositoryPath, payload.repositoryIdentity == parent.repositoryIdentity,
                  rows.contains(where: { $0.id == payload.row.id }) else { return }
            if payload.renameStash { guard !parent.isBusy else { return }; parent.onRenameStash(payload.row.target); return }
            guard let action = payload.action else { return }
            if parent.isBusy && action != .copy && !(action == .stashShow) { return }
            let value = payload.row
            if action == .delete && parent.branches.contains(where: { $0.name == value.target && $0.isCurrent }) { return }
            let remote = value.id.hasPrefix("remote:")
            let target = action == .history || action == .merge ? (remote ? "refs/remotes/" : "refs/heads/") + value.target
                : action == .stopTracking && remote ? "refs/remotes/" + value.target : value.target
            parent.onAction(action, target)
        }
    }
}
