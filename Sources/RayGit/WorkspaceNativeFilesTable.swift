import AppKit
import SwiftUI
import GitCore
import RayGitLocalization

/// Native row reuse avoids SwiftUI building an identity graph for every workspace file.
struct WorkspaceNativeFilesTable: NSViewRepresentable {
    let rows: [WorkspaceFileRow]
    let files: [GitFile]
    let repository: GitRepository?
    @Binding var selection: Set<String>
    let isBusy: Bool
    @Binding var sortOrder: [WorkspaceFilePreparation.Sort]
    var visibleColumns: Set<String> = ["filename", "status", "directory"]
    var onVisibleColumnsChange: (Set<String>) -> Void = { _ in }
    let onAction: (FileAction, Set<String>) -> Void
    let onCompare: (Set<String>) -> Void
    var fileFocus: WorkspaceFileFocus?
    var isReady = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FileScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = FileTable()
        table.coordinator = context.coordinator
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.autosaveName = "RayGit.Workspace.NativeFiles.v1"
        table.autosaveTableColumns = true
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.compare(_:))
        for definition in Coordinator.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id))
            column.title = context.coordinator.title(definition.id)
            column.width = definition.width
            column.minWidth = definition.minimum
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            if definition.id == "status" {
                column.width = context.coordinator.statusWidth
                column.resizingMask = .userResizingMask
            }
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.id, ascending: true)
            table.addTableColumn(column)
        }
        table.headerView?.frame.size.height = 23
        table.headerView?.menu = context.coordinator.columnMenu()
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        if let fileFocus { fileFocus.register(scroll, toolbar: false) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
        if let fileFocus { fileFocus.register(scroll, toolbar: false) }
    }

    final class FileScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let table = documentView as? NSTableView,
                  abs(table.frame.width - contentSize.width) > 1,
                  table.tableColumns.filter({ !$0.isHidden }).reduce(CGFloat.zero, { $0 + $1.minWidth + table.intercellSpacing.width }) <= contentSize.width else { return }
            table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height))
            table.sizeToFit()
        }
    }

    final class FileTable: NSTableView {
        weak var coordinator: Coordinator?
        var isTrackingMouse = false
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            if let range = Range(rows(in: visibleRect)), !range.isEmpty {
                reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
            }
        }
        override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(at: convert(event.locationInWindow, from: nil)) }
        override func mouseDown(with event: NSEvent) {
            guard coordinator?.parent.isReady == true else { return }
            let generation = coordinator?.mouseGeneration
            isTrackingMouse = true
            defer {
                isTrackingMouse = false
                if let generation { coordinator?.finishMouseTracking(generation: generation) }
            }
            super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            guard coordinator?.parent.isReady == true else { return }
            super.keyDown(with: event)
        }
        override func selectAll(_ sender: Any?) {
            guard coordinator?.parent.isReady == true else { return }
            super.selectAll(sender)
        }
    }

    final class Cell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        let icon = NSImageView()
        var badgeColor: NSColor? { didSet { needsDisplay = true; needsLayout = true } }
        var foregroundColor: NSColor = .labelColor { didSet { applyForeground() } }
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { applyForeground(); needsDisplay = true }
        }
        private func applyForeground() {
            label.textColor = backgroundStyle == .emphasized ? .selectedControlTextColor : foregroundColor
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            addSubview(label); addSubview(icon)
            textField = label
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let inset: CGFloat = icon.isHidden ? 3 : 23
            icon.frame = NSRect(x: 3, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let badge = badgeColor != nil
            let width = max(0, bounds.width - inset - 3)
            let textWidth = badge ? ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) : width
            let textHeight = ceil(label.cell?.cellSize.height ?? label.intrinsicContentSize.height)
            label.frame = NSRect(x: inset + (badge ? 6 : 0), y: (bounds.height - textHeight) / 2, width: badge ? min(max(0, width - 12), textWidth) : width, height: textHeight)
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let badgeColor else { return }
            let selected = backgroundStyle == .emphasized
            (selected ? NSColor.selectedControlTextColor : badgeColor).withAlphaComponent(selected ? 0.18 : 0.1).setFill()
            NSBezierPath(roundedRect: label.frame.insetBy(dx: -6, dy: -1), xRadius: 4, yRadius: 4).fill()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Column {
            let id: String
            let sort: WorkspaceFilePreparation.Sort.Column
            let width: CGFloat
            let minimum: CGFloat
        }
        static let columns: [Column] = [
            .init(id: "filename", sort: .name, width: 220, minimum: 120),
            .init(id: "status", sort: .status, width: 150, minimum: 60),
            .init(id: "workspace", sort: .worktree, width: 85, minimum: 65),
            .init(id: "index", sort: .index, width: 85, minimum: 65),
            .init(id: "directory", sort: .directory, width: 180, minimum: 80)
        ]
        var parent: WorkspaceNativeFilesTable
        weak var table: FileTable?
        private var rows: [WorkspaceFileRow] = []
        private var pathIndices: [String: Int] = [:]
        private var updating = false
        private var generation = UUID()
        var mouseGeneration: UUID { generation }
        private var icons: [String: NSImage] = [:]
        private var statusWidths: [String: CGFloat] = [:]
        private var columnLanguage = L10n.language
        private var menuActions: [Int: (FileAction, Set<String>, UUID)] = [:]
        init(_ parent: WorkspaceNativeFilesTable) { self.parent = parent }
        var statusWidth: CGFloat {
            let language = L10n.language
            if let width = statusWidths[language.rawValue] { return width }
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            let text = { L10n.text($0, table: "Files", language: language) }
            let titles = ["modified", "added", "deleted", "renamed", "copied", "type"].map { text("stagedStatus") + " · " + text($0) }
                + [text("conflict"), text("untracked"), L10n.text("Ignored · read-only", table: "CompactWorkspace", language: language)]
            let width = ceil(titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 70) + 32
            statusWidths[language.rawValue] = width
            return width
        }
        func title(_ id: String) -> String {
            switch id {
            case "filename": return L10n.text("name", table: "Files")
            case "status": return designWorkspaceText("Status")
            case "workspace": return L10n.text("workspace", table: "Files")
            case "index": return L10n.text("index", table: "Files")
            default: return L10n.text("directory", table: "Files")
            }
        }
        func update(_ value: WorkspaceNativeFilesTable) {
            guard let table else { return }
            let changed = parent.repository?.url != value.repository?.url || !rows.elementsEqual(value.rows, by: { $0.path == $1.path && $0.file == $1.file })
            let languageChanged = columnLanguage != L10n.language
            columnLanguage = L10n.language
            parent = value
            updating = true
            defer { updating = false }
            if changed {
                generation = UUID()
                rows = value.rows
                pathIndices = Dictionary(rows.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
                table.reloadData()
            }
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                let name = title(id)
                if column.title != name { column.title = name }
                if id == "status", languageChanged, column.width < statusWidth { column.width = statusWidth }
                let hidden = id != "filename" && !value.visibleColumns.contains(id)
                if column.isHidden != hidden { column.isHidden = hidden }
            }
            if table.headerView?.menu == nil { table.headerView?.menu = columnMenu() }
            for item in table.headerView?.menu?.items ?? [] where Self.columns.indices.contains(item.tag) {
                let id = Self.columns[item.tag].id
                let name = title(id)
                let state: NSControl.StateValue = value.visibleColumns.contains(id) || id == "filename" ? .on : .off
                if item.title != name { item.title = name }
                if item.state != state { item.state = state }
            }
            let descriptors = value.sortOrder.compactMap { order -> NSSortDescriptor? in
                guard let column = Self.columns.first(where: { $0.sort == order.column }) else { return nil }
                return NSSortDescriptor(key: column.id, ascending: order.ascending)
            }
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            let indices = IndexSet(value.selection.compactMap { pathIndices[$0] }.sorted())
            // Focus invalidation can reach SwiftUI while AppKit is still tracking the click.
            if (!table.isTrackingMouse || changed), table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
        }
        func finishMouseTracking(generation expected: UUID) {
            guard let table else { return }
            let selected = paths(table.selectedRowIndexes)
            if generation == expected, parent.isReady, parent.selection != selected { parent.selection = selected }
            update(parent)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell(frame: .zero)
            cell.identifier = id
            let value = rows[row]
            cell.icon.isHidden = id.rawValue != "filename"
            cell.label.font = .systemFont(ofSize: id.rawValue == "status" ? 10 : 12)
            cell.foregroundColor = .labelColor
            cell.badgeColor = nil
            switch id.rawValue {
            case "filename":
                cell.label.stringValue = value.name
                let dark = tableView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let scale = tableView.window?.backingScaleFactor ?? 2
                let status = value.file.map { $0.indexStatus + "|" + $0.worktreeStatus } ?? "ignored"
                let key = "\(dark)|\(scale)|\(status)"
                if icons[key] == nil {
                    let renderer = ImageRenderer(content: WorkspaceStatusIcon(file: value.file).frame(width: 24, height: 23).environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = scale
                    icons[key] = renderer.nsImage
                }
                cell.icon.image = icons[key]
            case "directory": cell.label.stringValue = value.directory.isEmpty ? "—" : value.directory; cell.foregroundColor = .secondaryLabelColor
            case "status":
                if let file = value.file {
                    let status = WorkspaceFileStatus(file)
                    cell.label.stringValue = status.keys.map { L10n.text($0, table: "Files") }.joined(separator: " · ")
                    cell.foregroundColor = color(status.kind)
                    cell.label.font = .systemFont(ofSize: 10, weight: .medium)
                    cell.badgeColor = cell.foregroundColor
                } else {
                    cell.label.stringValue = L10n.text("Ignored · read-only", table: "CompactWorkspace")
                    cell.foregroundColor = .secondaryLabelColor
                }
            default:
                let code = id.rawValue == "index" ? value.indexKey : value.worktreeKey
                let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][code]
                cell.label.stringValue = key.map { L10n.text($0, table: "Files") } ?? code
                cell.foregroundColor = color(key ?? "none")
                if code != " " { cell.label.font = .systemFont(ofSize: 10, weight: .medium); cell.badgeColor = cell.foregroundColor }
            }
            cell.toolTip = cell.label.stringValue
            return cell
        }
        private func color(_ key: String) -> NSColor {
            switch key {
            case "deleted": return .systemRed
            case "untracked": return .systemBlue
            case "added", "stagedStatus": return .systemGreen
            case "conflict", "modified", "renamed", "copied", "type": return .systemOrange
            default: return .secondaryLabelColor
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, parent.isReady, let table else { return }
            parent.selection = paths(table.selectedRowIndexes)
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, table === tableView, !tableView.sortDescriptors.isEmpty else { return }
            let orders: [WorkspaceFilePreparation.Sort] = tableView.sortDescriptors.compactMap { descriptor in
                guard let column = Self.columns.first(where: { $0.id == descriptor.key }) else { return nil }
                return .init(column: column.sort, ascending: descriptor.ascending)
            }
            if parent.sortOrder != orders { parent.sortOrder = orders }
        }
        private func paths(_ indices: IndexSet) -> Set<String> { Set(indices.compactMap { rows.indices.contains($0) ? rows[$0].path : nil }) }
        @objc func compare(_ sender: Any?) {
            if let table { activate(row: table.clickedRow) }
        }
        func activate(row: Int) {
            guard parent.isReady, !parent.isBusy, let table, rows.indices.contains(row) else { return }
            let path = rows[row].path
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            parent.selection = [path]
            parent.onCompare([path])
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, column) in Self.columns.enumerated() {
                let item = NSMenuItem(title: title(column.id), action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.tag = index
                item.state = parent.visibleColumns.contains(column.id) || column.id == "filename" ? .on : .off
                item.isEnabled = column.id != "filename"
                menu.addItem(item)
            }
            return menu
        }
        @objc private func toggleColumn(_ item: NSMenuItem) {
            guard Self.columns.indices.contains(item.tag) else { return }
            let id = Self.columns[item.tag].id
            guard id != "filename" else { return }
            var visible = parent.visibleColumns
            if visible.contains(id) { visible.remove(id) } else { visible.insert(id) }
            parent.onVisibleColumnsChange(visible)
        }
        func menu(at point: NSPoint) -> NSMenu? {
            guard parent.isReady, let table else { return nil }
            let row = table.row(at: point)
            guard rows.indices.contains(row) else { return nil }
            let paths = table.selectedRowIndexes.contains(row) ? self.paths(table.selectedRowIndexes) : [rows[row].path]
            let existing = Set(paths.filter { path in parent.repository.map { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(path).path) } ?? false })
            let eligibility = WorkspaceContextEligibility(paths: paths, files: parent.files, existing: existing)
            let ignored = Set(rows.lazy.filter(\.isIgnored).map(\.path))
            let writable = ignored.isDisjoint(with: paths)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menuActions.removeAll()
            func item(_ key: String, _ action: FileAction, _ enabled: Bool = true) {
                let entry = NSMenuItem(title: fileContextText(key), action: #selector(performMenu(_:)), keyEquivalent: "")
                entry.target = self; entry.tag = menu.items.count
                entry.isEnabled = enabled && !parent.isBusy && parent.repository != nil
                menuActions[entry.tag] = (action, paths, generation)
                menu.addItem(entry)
            }
            item("compare", .compare, paths.count == 1 && writable)
            item("history", .history, writable && eligibility.canHistory(allowCleanFile: false))
            menu.addItem(.separator())
            item("stage", .stage, eligibility.canGit(.stage))
            item("unstage", .unstage, eligibility.canGit(.unstage))
            item("discard", .discard, eligibility.canGit(.discard))
            menu.addItem(.separator())
            item("rename", .rename, paths.count == 1 && eligibility.allExisting && writable)
            item("ignore", .ignore, eligibility.canIgnore)
            item("trash", .trash, eligibility.allExisting && writable)
            menu.addItem(.separator())
            item("copyPath", .copyPath)
            menu.addItem(.separator())
            item("open", .open, eligibility.allExisting)
            item("reveal", .reveal)
            return menu
        }
        @objc private func performMenu(_ item: NSMenuItem) {
            guard item.isEnabled, parent.isReady, !parent.isBusy, let (action, paths, id) = menuActions[item.tag], id == generation else { return }
            parent.onAction(action, paths)
        }
    }
}
