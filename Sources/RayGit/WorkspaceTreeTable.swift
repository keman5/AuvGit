import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

/// Flattened tree rows use native cell reuse rather than a SwiftUI identity graph.
struct WorkspaceTreeTable: NSViewRepresentable {
    let rows: [WorkspaceTreeRow]
    @Binding var expanded: Set<String>
    var selection: Binding<Set<String>>
    let repository: GitRepository
    let files: [GitFile]
    let isBusy: Bool
    let openFile: (String) -> Void
    let onAction: (FileAction, Set<String>) -> Void
    var recreatableConflicts: Set<String> = []
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = TreeTable()
        table.coordinator = context.coordinator
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.rowHeight = 22; table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("treeName"))
        column.title = L10n.text("name", table: "Files")
        column.minWidth = 80; column.width = 500
        table.addTableColumn(column)
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.open(_:))
        table.headerView?.frame.size.height = 23
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class TreeTable: NSTableView {
        weak var coordinator: Coordinator?
        var isTrackingMouse = false
        override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(at: convert(event.locationInWindow, from: nil)) }
        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func mouseDown(with event: NSEvent) {
            guard coordinator?.enabled == true else { return }
            let generation = coordinator?.mouseGeneration
            isTrackingMouse = true
            defer {
                isTrackingMouse = false
                if let generation { coordinator?.finishMouseTracking(generation: generation) }
            }
            super.mouseDown(with: event)
        }
        override func selectAll(_ sender: Any?) {
            guard coordinator?.enabled == true else { return }
            super.selectAll(sender)
        }
        override func keyDown(with event: NSEvent) {
            guard coordinator?.enabled == true else { return }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               coordinator?.arrow(event.keyCode) == true { return }
            super.keyDown(with: event)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            if let range = Range(rows(in: visibleRect)), !range.isEmpty {
                reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integer: 0))
            }
        }
    }
    final class Cell: NSTableCellView, NativeSelectionCellStyling {
        let disclosure = NSButton()
        let icon = NSImageView()
        var nativeSelection: Bool? { didSet { applyForeground() } }
        var normalIcon: NSImage? { didSet { applyForeground() } }
        var selectedIcon: NSImage? { didSet { applyForeground() } }
        let label = NSTextField(labelWithString: "")
        var depth = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            disclosure.isBordered = false; disclosure.bezelStyle = .inline
            disclosure.imagePosition = .imageOnly
            label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            icon.setAccessibilityElement(false)
            addSubview(disclosure); addSubview(icon); addSubview(label)
            textField = label
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let left = CGFloat(depth) * 16 + 3
            disclosure.frame = NSRect(x: left, y: (bounds.height - 20) / 2, width: 14, height: 20)
            icon.frame = NSRect(x: left + 19, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let textHeight = ceil(label.cell?.cellSize.height ?? label.intrinsicContentSize.height)
            label.frame = NSRect(x: left + 40, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - left - 43), height: textHeight)
        }
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { applyForeground() }
        }
        private func applyForeground() {
            let selected = nativeSelection ?? (backgroundStyle == .emphasized)
            label.textColor = selected ? .white : .labelColor
            icon.image = selected ? selectedIcon ?? normalIcon : normalIcon
            icon.contentTintColor = selected ? .white : .secondaryLabelColor
            disclosure.contentTintColor = selected ? .white : .secondaryLabelColor
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: WorkspaceTreeTable
        weak var table: TreeTable?
        var enabled: Bool { !parent.isBusy && parent.isEnabled }
        private var rows: [WorkspaceTreeRow] = []
        private var indices: [String: Int] = [:]
        private var filesByPath: [String: GitFile] = [:]
        private var updating = false
        private var generation = UUID()
        var mouseGeneration: UUID { generation }
        private var icons: [String: NSImage] = [:]
        private var menuActions: [Int: (FileAction, Set<String>, UUID)] = [:]
        init(_ parent: WorkspaceTreeTable) { self.parent = parent }
        func update(_ value: WorkspaceTreeTable) {
            guard let table else { return }
            let changed = parent.repository.url != value.repository.url || !rows.elementsEqual(value.rows, by: { $0.path == $1.path && $0.depth == $1.depth && $0.isDirectory == $1.isDirectory })
            let changedStatus = parent.files != value.files
            let changedExpansion = parent.expanded != value.expanded
            let changedEnabled = enabled != (!value.isBusy && value.isEnabled)
            parent = value
            updating = true
            defer { updating = false }
            if changedStatus || filesByPath.isEmpty {
                filesByPath = Dictionary(value.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            }
            if changed || changedStatus { generation = UUID() }
            if changed {
                rows = value.rows
                indices = Dictionary(rows.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
            }
            if changed || changedStatus || changedExpansion { table.reloadData() }
            else if changedEnabled, let range = Range(table.rows(in: table.visibleRect)), !range.isEmpty {
                table.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integer: 0))
            }
            let selected = IndexSet(value.selection.wrappedValue.compactMap { indices[$0] }.sorted())
            if (!table.isTrackingMouse || changed), table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func finishMouseTracking(generation expected: UUID) {
            guard let table else { return }
            let selected = paths(table.selectedRowIndexes)
            if generation == expected, enabled, parent.selection.wrappedValue != selected { parent.selection.wrappedValue = selected }
            update(parent)
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NativeSelectionRowView() }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("treeCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell(frame: .zero)
            cell.identifier = id
            cell.nativeSelection = tableView.isRowSelected(row)
            let value = rows[row]
            cell.selectedIcon = nil
            cell.depth = value.depth; cell.needsLayout = true
            cell.label.stringValue = value.name; cell.toolTip = value.path
            cell.disclosure.isHidden = !value.isDirectory
            if value.isDirectory {
                cell.disclosure.isEnabled = enabled
                cell.disclosure.image = NSImage(systemSymbolName: parent.expanded.contains(value.path) ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
                cell.disclosure.target = self; cell.disclosure.action = #selector(disclose(_:)); cell.disclosure.identifier = .init(value.path)
                cell.disclosure.setAccessibilityLabel(value.name)
                cell.disclosure.setAccessibilityValue(L10n.text(parent.expanded.contains(value.path) ? "Expanded" : "Collapsed", table: "SidebarRefinement"))
            }
            if value.isDirectory { cell.normalIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
            else if let file = filesByPath[value.path] {
                let dark = tableView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let scale = tableView.window?.backingScaleFactor ?? 2
                let key = "\(dark)|\(scale)|\(file.indexStatus)|\(file.worktreeStatus)"
                if icons[key] == nil {
                    let renderer = ImageRenderer(content: WorkspaceStatusIcon(file: file).frame(width: 24, height: 23).environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = scale; icons[key] = renderer.nsImage
                }
                cell.normalIcon = icons[key]
                let selectedKey = key + "|selected"
                if icons[selectedKey] == nil {
                    var selectedIcon = WorkspaceStatusIcon(file: file)
                    selectedIcon.selected = true
                    let renderer = ImageRenderer(content: selectedIcon.frame(width: 24, height: 23).environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = scale; icons[selectedKey] = renderer.nsImage
                }
                cell.selectedIcon = icons[selectedKey]
            } else { cell.normalIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, enabled, let table else { return }
            parent.selection.wrappedValue = paths(table.selectedRowIndexes)
        }
        private func paths(_ selected: IndexSet) -> Set<String> { Set(selected.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }) }
        private func toggle(_ path: String) {
            guard enabled, let index = indices[path], rows[index].isDirectory else { return }
            if !parent.expanded.insert(path).inserted { parent.expanded.remove(path) }
        }
        @objc private func disclose(_ button: NSButton) { if let path = button.identifier?.rawValue { toggle(path) } }
        @objc func open(_ sender: Any?) {
            if let table { activate(row: table.clickedRow) }
        }
        func activate(row index: Int) {
            guard enabled, let table, rows.indices.contains(index) else { return }
            let row = rows[index]
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            parent.selection.wrappedValue = [row.path]
            if row.isDirectory { toggle(row.path) } else { parent.openFile(row.path) }
        }
        func arrow(_ key: UInt16) -> Bool {
            guard enabled, [123, 124].contains(key), let table, table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else { return false }
            let index = table.selectedRow; let row = rows[index]
            if key == 124 {
                if row.isDirectory, !parent.expanded.contains(row.path) { toggle(row.path) }
                else if row.isDirectory, rows.indices.contains(index + 1), rows[index + 1].depth > row.depth { table.selectRowIndexes(IndexSet(integer: index + 1), byExtendingSelection: false) }
            } else if row.isDirectory, parent.expanded.contains(row.path) { toggle(row.path) }
            else if let parentIndex = rows[..<index].lastIndex(where: { $0.depth < row.depth && $0.isDirectory }) { table.selectRowIndexes(IndexSet(integer: parentIndex), byExtendingSelection: false) }
            return true
        }
        func menu(at point: NSPoint) -> NSMenu? {
            guard enabled, let table else { return nil }
            let row = table.row(at: point)
            guard rows.indices.contains(row) else { return nil }
            let paths = table.selectedRowIndexes.contains(row) ? self.paths(table.selectedRowIndexes) : [rows[row].path]
            let directories = Set(paths.filter { indices[$0].map { rows[$0].isDirectory } ?? false })
            let existing = Set(paths.filter { FileManager.default.fileExists(atPath: parent.repository.url.appendingPathComponent($0).path) })
            let eligibility = WorkspaceContextEligibility(paths: paths, files: parent.files, existing: existing, recreatableConflicts: parent.recreatableConflicts)
            let menu = NSMenu(); menu.autoenablesItems = false
            menuActions.removeAll()
            func item(_ key: String, _ action: FileAction, _ allowed: Bool = true) {
                let entry = NSMenuItem(title: fileContextText(key), action: #selector(performMenu(_:)), keyEquivalent: "")
                entry.target = self; entry.tag = menuActions.count; entry.isEnabled = allowed && enabled
                menuActions[entry.tag] = (action, paths, generation); menu.addItem(entry)
            }
            item("compare", .compare, paths.count == 1 && directories.isEmpty)
            if eligibility.canResolveConflicts && directories.isEmpty {
                let submenu = NSMenu(); submenu.autoenablesItems = false
                for (key, action) in [("resolveOurs", FileAction.resolveOurs), ("resolveTheirs", .resolveTheirs), ("resolveBoth", .resolveBoth)] {
                    item(key, action)
                    let option = menu.items.last!; menu.removeItem(option); submenu.addItem(option)
                }
                let entry = NSMenuItem(title: fileContextText("resolveConflict"), action: nil, keyEquivalent: "")
                entry.submenu = submenu; menu.addItem(entry)
            }
            if eligibility.canRecreateConflict { item("recreateConflict", .recreateConflict) }
            item("history", .history, directories.isEmpty && eligibility.canHistory(allowCleanFile: true))
            menu.addItem(.separator())
            item("stage", .stage, eligibility.canGit(.stage)); item("unstage", .unstage, eligibility.canGit(.unstage)); item("discard", .discard, eligibility.canGit(.discard))
            menu.addItem(.separator())
            item("rename", .rename, paths.count == 1 && eligibility.allExisting); item("ignore", .ignore, eligibility.canIgnore); item("trash", .trash, eligibility.allExisting)
            menu.addItem(.separator()); item("copyPath", .copyPath)
            menu.addItem(.separator()); item("open", .open, eligibility.allExisting); item("reveal", .reveal)
            return menu
        }
        @objc private func performMenu(_ item: NSMenuItem) {
            guard enabled, let (action, paths, id) = menuActions[item.tag], id == generation else { return }
            parent.onAction(action, paths)
        }
    }
}
