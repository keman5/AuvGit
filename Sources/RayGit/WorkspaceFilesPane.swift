import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

enum FileAction {
    case compare, open, reveal, history, stage, unstage, discard
    case copyName, copyPath, copyRelativePath, stageAll, unstageAll, rename, ignore, trash
}
struct FilePaneShortcutRequest {
    let id = UUID()
    let command: ShortcutCommand
}

struct WorkspaceFilesPane<TreeContent: View>: View {
    let files: [GitFile]
    @AppStorage("preferences.filterCase") private var filterCase = "insensitive"
    @Binding var selection: Set<String>
    @Binding var filter: String
    @Binding var treeMode: Bool
    let isBusy: Bool
    let onAction: (FileAction, Set<String>) -> Void
    let treeContent: (Set<String>?) -> TreeContent
    var repository: GitRepository? = nil
    var fileFocus: WorkspaceFileFocus? = nil
    var shortcutRequest: FilePaneShortcutRequest? = nil
    @State private var filterFocusRequest: UUID?

    @AppStorage("workspace.columns.v1") private var columnCustomization = TableColumnCustomization<Row>()
    @State private var sortOrder = [KeyPathComparator(\Row.path, comparator: .localizedStandard)]
    @State private var category = WorkspaceStatusFilter.all
    @AppStorage("workspace.showHiddenFiles") private var showHidden = true
    @State private var showIgnored = false
    @State private var ignoredPaths: [String] = []
    @State private var loadingIgnored = false
    @State private var ignoredRequestID = UUID()
    @State private var ignoredError: String?
    private struct Row: Identifiable {
        let path: String
        let file: GitFile?
        var id: String { path }
        var isIgnored: Bool { file == nil }
        let name: String
        let directory: String
        init(path: String, file: GitFile?) {
            self.path = path; self.file = file
            name = (path as NSString).lastPathComponent
            directory = (path as NSString).deletingLastPathComponent
        }
        var statusKey: String {
            guard let file else { return "!" }
            return file.isConflict ? "U" : file.isUntracked ? "?" : file.indexStatus != " " ? file.indexStatus : file.worktreeStatus
        }
        var worktreeKey: String { file?.worktreeStatus ?? " " }
        var indexKey: String { file?.indexStatus ?? " " }
    }
    @State private var visibleFiles: [Row] = []
    @State private var statusCounts: [WorkspaceStatusFilter: Int] = [:]
    private func rebuildVisibleFiles() {
        statusCounts = Dictionary(uniqueKeysWithValues: WorkspaceStatusFilter.allCases.map { item in
            (item, files.lazy.filter { item.includes($0) && (showHidden || !WorkspaceStatusFilter.isHiddenPath($0.path)) }.count)
        })
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func visible(_ path: String) -> Bool {
            (showHidden || !WorkspaceStatusFilter.isHiddenPath(path)) && (query.isEmpty || RayGitPreferences.matches(path, query: query, caseMode: filterCase))
        }
        var rows = files.filter { category.includes($0) && visible($0.path) }.map { Row(path: $0.path, file: $0) }
        if showIgnored, category == .all {
            let existing = Set(files.map(\.path))
            rows += ignoredPaths.filter { !existing.contains($0) && visible($0) }.map { Row(path: $0, file: nil) }
        }
        visibleFiles = rows.sorted { lhs, rhs in
            for comparator in sortOrder {
                let comparison = comparator.compare(lhs, rhs)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
    private var treeVisiblePaths: Set<String>? {
        if category == .all && showHidden && filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return Set(visibleFiles.map(\.path))
    }
    private func compactText(_ key: String) -> String { L10n.text(key, table: "CompactWorkspace") }
    private func text(_ key: String) -> String { L10n.text(key, table: "Files") }
    private func selected(_ paths: Set<String>) -> [GitFile] { files.filter { paths.contains($0.path) } }
    private func eligible(_ action: FileAction, _ paths: Set<String>) -> Set<String> {
        if [.stage, .unstage, .discard, .stageAll, .unstageAll].contains(action) {
            return WorkspaceFileActionTargets.paths(for: action, files: files, selection: paths)
        }
        return Set(selected(paths).filter { file in
            switch action {
            case .compare: return true
            case .open: return file.worktreeStatus != "D" && !(file.indexStatus == "D" && !file.isUnstaged)
            case .history: return !file.isUntracked && file.indexStatus != "A"
            case .stage, .stageAll: return file.isUnstaged && !file.isConflict
            case .unstage, .unstageAll: return file.isStaged && !file.isConflict
            case .discard: return !file.isUntracked && !file.isConflict && file.isUnstaged
            default: return true
            }
        }.map(\.path))
    }
    private func performCompare(_ paths: Set<String>) {
        guard !isBusy, paths.count == 1 else { return }
        if paths.allSatisfy({ ignoredPaths.contains($0) }) { reveal(paths); return }
        guard eligible(.compare, paths).count == 1 else { return }
        if RayGitPreferences.doubleClick == "stage", let file = selected(paths).first, !file.isConflict {
            onAction(file.isUnstaged ? .stage : .unstage, paths)
        } else { onAction(.compare, paths) }
    }
    private func actionButton(_ key: String, _ action: FileAction, _ paths: Set<String>, single: Bool = false) -> some View {
        let targets = eligible(action, paths)
        return Button(text(key)) { onAction(action, targets) }
            .disabled(isBusy || targets.isEmpty || (single && paths.count != 1))
    }

    private var content: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { statusControls; Spacer(minLength: 4); fileControls }
                VStack(spacing: 8) { HStack { statusControls; Spacer() }; HStack { fileControls; Spacer() } }
            }.controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).padding(.horizontal, 10).padding(.vertical, 6).rayGitChrome()
            Divider()
            if treeMode { treeContent(treeVisiblePaths).background { if let fileFocus { WorkspaceFileFocusRegion(focus: fileFocus).allowsHitTesting(false).accessibilityHidden(true) } } }
            else if visibleFiles.isEmpty {
                RayGitEmptyState(title: text(files.isEmpty ? "clean" : "noFiles"), systemImage: files.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } else { fileTable }
        }
    }
    private var filteredContent: some View {
        content
        .onAppear { rebuildVisibleFiles(); if treeMode && showIgnored { treeMode = false } }
        .onChange(of: shortcutRequest?.id) { _, _ in performShortcut() }
        .onChange(of: files) { _, _ in rebuildVisibleFiles(); if showIgnored { Task { await loadIgnored() } } }
        .onChange(of: filter) { _, _ in rebuildVisibleFiles() }
        .onChange(of: filterCase) { _, _ in rebuildVisibleFiles() }
        .onChange(of: category) { _, _ in rebuildVisibleFiles() }
        .onChange(of: showHidden) { _, _ in rebuildVisibleFiles() }
    }
    var body: some View {
        filteredContent
        .onChange(of: ignoredPaths) { _, _ in rebuildVisibleFiles() }
        .onChange(of: sortOrder) { _, _ in rebuildVisibleFiles() }
        .task(id: (repository?.url.path ?? "") + "|\(showIgnored)") { await loadIgnored() }
        .onChange(of: showIgnored) { _, value in rebuildVisibleFiles(); if value { treeMode = false } }
        .onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { notification in
            refreshIgnored(notification)
        }
    }
    private func refreshIgnored(_ notification: Notification) {
        if let root = notification.object as? URL, root == repository?.url, showIgnored { Task { await loadIgnored() } }
    }
    private func performShortcut() {
        switch shortcutRequest?.command {
        case .filterFiles: filterFocusRequest = UUID()
        case .showUnversionedFiles: category = category == .untracked ? .all : .untracked
        case .showIgnoredFiles: showIgnored.toggle(); category = .all; treeMode = false
        default: break
        }
    }
    private var statusControls: some View {
        HStack(spacing: 7) {
            if let ignoredError { FloatingNotice(message: ignoredError, guidance: noticeText("Ignored files could not be loaded. Toggle Show ignored files off and on to retry. Check the repository status below; this command only reads files and does not stage ignored files."), command: "git status --short --ignored") }
            ForEach(WorkspaceStatusFilter.allCases.filter { $0 != .renamed }, id: \.self) { item in
                let count = statusCounts[item, default: 0]
                Button { category = item } label: {
                    WorkspaceStatusIcon(filter: item).scaleEffect(0.74).frame(width: 24, height: 23).contentShape(Rectangle()).opacity(category == item ? 1 : 0.58)
                }.buttonStyle(.plain).help(categoryTitle(item) + " · " + String(count))
                    .accessibilityLabel(categoryTitle(item)).accessibilityValue(String(count))
                    .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Divider().frame(height: 17)
            Button { showHidden.toggle() } label: {
                Image(systemName: "eye").font(.system(size: 13)).frame(width: 24, height: 23).contentShape(Rectangle()).foregroundStyle(showHidden ? RayGitStyle.blue : Color.secondary)
            }.buttonStyle(.plain).help(compactText("Show hidden files")).accessibilityLabel(compactText("Show hidden files")).accessibilityValue(showHidden ? compactText("On") : compactText("Off"))
            Button { showIgnored.toggle(); category = .all; treeMode = false } label: {
                if loadingIgnored { ProgressView().controlSize(.mini).frame(width: 24, height: 23) }
                else { WorkspaceStatusIcon(kind: .ignored).scaleEffect(0.74).frame(width: 24, height: 23).contentShape(Rectangle()).opacity(showIgnored ? 1 : 0.58) }
            }.buttonStyle(.plain).disabled(repository == nil)
                .help(compactText("Show ignored files (read-only)")).accessibilityLabel(compactText("Show ignored files (read-only)")).accessibilityValue(showIgnored ? compactText("On") : compactText("Off"))
        }
    }
    private func categoryTitle(_ item: WorkspaceStatusFilter) -> String { compactText(item.rawValue) }
    private var fileControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                HistorySearchField(text: $filter, placeholder: text("filter"), accessibilityLabel: text("filter"), rounded: false, focusRequest: filterFocusRequest)
                    .frame(height: 20)
            }.padding(.horizontal, 9).frame(height: 24).rayGitInputSurface().frame(width: 170)
            Button {
                if treeMode { treeMode = false }
                else { showIgnored = false; treeMode = true }
            } label: { Image(systemName: treeMode ? "folder" : "list.bullet") }
                .help(workflowText("Files view")).accessibilityLabel(workflowText("Files view"))
            Menu {
                actionButton("stage", .stage, selection)
                actionButton("unstage", .unstage, selection)
                actionButton("compare", .compare, selection, single: true)
                actionButton("history", .history, selection, single: true)
                actionButton("discard", .discard, selection)
                Divider()
                actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help(text("allActions")).accessibilityLabel(text("allActions"))
        }
    }
    private var fileTable: some View {
            Table(visibleFiles, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                TableColumn(text("name"), value: \.name) { file in
                    HStack(spacing: 6) {
                        WorkspaceStatusIcon(file: file.file).scaleEffect(0.65).frame(width: 16, height: 16)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                    }
                }.width(min: 120, ideal: 220).customizationID("filename").disabledCustomizationBehavior(.visibility)
                TableColumn(designWorkspaceText("Status"), value: \.statusKey) { file in
                    if let value = file.file { fileStatus(value) }
                    else { Text(compactText("Ignored · read-only")).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.width(min: 70, ideal: 90).customizationID("status")
                TableColumn(text("workspace"), value: \.worktreeKey) { file in status(file.file?.worktreeStatus ?? " ", selected: selection.contains(file.path)) }.width(min: 65, ideal: 85).customizationID("workspace").defaultVisibility(.hidden)
                TableColumn(text("index"), value: \.indexKey) { file in status(file.file?.indexStatus ?? " ", selected: selection.contains(file.path)) }.width(min: 65, ideal: 85).customizationID("index").defaultVisibility(.hidden)
                TableColumn(text("directory"), value: \.directory) { file in
                    let directory = file.directory
                    Text(directory.isEmpty ? "—" : directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 80, ideal: 180).customizationID("directory")
            }
            .font(.system(size: 12)).environment(\.defaultMinListRowHeight, 22)
            .tint(Color(red: 0.20, green: 0.53, blue: 0.94))
            .background(WorkspaceTableDensity().allowsHitTesting(false).accessibilityHidden(true))
            .background { if let fileFocus { WorkspaceFileFocusRegion(focus: fileFocus).allowsHitTesting(false).accessibilityHidden(true) } }
            .contextMenu(forSelectionType: String.self) { paths in
                WorkspaceContextMenu(paths: paths, files: files, repository: repository, isBusy: isBusy, readOnlyPaths: Set(ignoredPaths), onAction: onAction)
            } primaryAction: { paths in performCompare(paths) }
    }

    private func openIgnored(_ paths: Set<String>) {
        guard let repository else { return }
        for path in paths.sorted() { NSWorkspace.shared.open(repository.url.appendingPathComponent(path)) }
    }
    private func reveal(_ paths: Set<String>) { if let repository { NSWorkspace.shared.activateFileViewerSelecting(paths.sorted().map { repository.url.appendingPathComponent($0) }) } }
    private func loadIgnored() async {
        let requestID = UUID()
        ignoredRequestID = requestID
        guard showIgnored, let repository else { ignoredPaths = []; ignoredError = nil; loadingIgnored = false; return }
        loadingIgnored = true
        defer { if ignoredRequestID == requestID { loadingIgnored = false } }
        do {
            let paths = try await repository.ignoredWorkspacePaths()
            guard !Task.isCancelled, ignoredRequestID == requestID else { return }
            ignoredPaths = paths; ignoredError = nil
        } catch { if !Task.isCancelled, ignoredRequestID == requestID { ignoredError = compactText("Ignored files could not be loaded") } }
    }
    private func fileStatus(_ file: GitFile) -> some View {
        let presentation = WorkspaceFileStatus(file)
        let title = presentation.keys.map(text).joined(separator: " · ")
        return RayGitBadge(title, tint: presentation.kind == "conflict" ? .orange : presentation.kind == "deleted" ? .red : presentation.kind == "untracked" ? .blue : presentation.kind == "added" || presentation.kind == "stagedStatus" ? .green : .orange).help(title)
    }
    private func status(_ value: String, selected: Bool) -> some View {
        let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][value]
        let color: Color = value == "?" ? .blue : value == "A" ? .green : value == "D" ? .red : ["M", "R", "U"].contains(value) ? .orange : .secondary
        return Group {
            if value == " " { Text(text("none")).foregroundStyle(.tertiary).font(.system(size: 11)) }
            else { RayGitBadge(key.map(text) ?? value, tint: color) }
        }
    }
}

/// Apply native table metrics once the SwiftUI table is attached; the list-row
/// environment alone does not control NSTableView's header or intercell gap.
private struct WorkspaceTableDensity: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure() }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private weak var configuredTable: NSTableView?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func layout() { super.layout(); configure() }
        func configure() {
            if let table = configuredTable { apply(to: table); return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let table = Self.table(in: view) {
                        self.configuredTable = table
                        self.apply(to: table)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
        private func apply(to table: NSTableView) {
            // SwiftUI installs automatic sizing from hosting-cell fitting heights.
            // A rowHeight alone is ignored while that mode is enabled.
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
            if table.rowSizeStyle != .custom { table.rowSizeStyle = .custom }
            if table.rowHeight != 22 { table.rowHeight = 22 }
            if table.intercellSpacing.height != 0 { table.intercellSpacing.height = 0 }
            if let header = table.headerView, header.frame.height != 23 {
                var frame = header.frame; frame.size.height = 23; header.frame = frame
            }
        }
        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = table(in: child) { return table } }
            return nil
        }
    }
}
