import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

enum FileAction {
    case compare, open, reveal, history, stage, unstage, discard
    case copyName, copyPath, copyRelativePath, stageAll, unstageAll
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
        var name: String { (path as NSString).lastPathComponent }
        var directory: String { (path as NSString).deletingLastPathComponent }
        var statusKey: String {
            guard let file else { return "!" }
            return file.isConflict ? "U" : file.isUntracked ? "?" : file.indexStatus != " " ? file.indexStatus : file.worktreeStatus
        }
        var worktreeKey: String { file?.worktreeStatus ?? " " }
        var indexKey: String { file?.indexStatus ?? " " }
    }
    private var visibleFiles: [Row] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func visible(_ path: String) -> Bool {
            (showHidden || !WorkspaceStatusFilter.isHiddenPath(path)) && (query.isEmpty || RayGitPreferences.matches(path, query: query, caseMode: filterCase))
        }
        var rows = files.filter { category.includes($0) && visible($0.path) }.map { Row(path: $0.path, file: $0) }
        if showIgnored, category == .all {
            let existing = Set(files.map(\.path))
            rows += ignoredPaths.filter { !existing.contains($0) && visible($0) }.map { Row(path: $0, file: nil) }
        }
        return rows.sorted { lhs, rhs in
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

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { statusControls; Spacer(minLength: 4); fileControls }
                VStack(spacing: 8) { HStack { statusControls; Spacer() }; HStack { fileControls; Spacer() } }
            }.controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).padding(.horizontal, 10).padding(.vertical, 6).rayGitChrome()
            Divider()
            if let ignoredError { Text(ignoredError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).textSelection(.enabled) }
            if treeMode { treeContent(treeVisiblePaths) }
            else if visibleFiles.isEmpty {
                RayGitEmptyState(title: text(files.isEmpty ? "clean" : "noFiles"), systemImage: files.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } else { fileTable }
        }
        .onAppear { if treeMode && showIgnored { treeMode = false } }
        .task(id: (repository?.url.path ?? "") + "|\(showIgnored)|\(files.hashValue)") { await loadIgnored() }
        .onChange(of: showIgnored) { _, value in if value { treeMode = false } }
        .onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { notification in
            if let root = notification.object as? URL, root == repository?.url, showIgnored { Task { await loadIgnored() } }
        }
    }
    private var statusControls: some View {
        HStack(spacing: 7) {
            ForEach(WorkspaceStatusFilter.allCases.filter { $0 != .renamed }, id: \.self) { item in
                let count = files.filter { item.includes($0) && (showHidden || !WorkspaceStatusFilter.isHiddenPath($0.path)) }.count
                Button { category = item } label: {
                    WorkspaceStatusIcon(filter: item).opacity(category == item ? 1 : 0.58)
                }.buttonStyle(.plain).help(categoryTitle(item) + " · " + String(count))
                    .accessibilityLabel(categoryTitle(item)).accessibilityValue(String(count))
                    .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Divider().frame(height: 17)
            Button { showHidden.toggle() } label: {
                Image(systemName: "eye").font(.system(size: 18)).foregroundStyle(showHidden ? RayGitStyle.blue : Color.secondary)
            }.buttonStyle(.plain).help(compactText("Show hidden files")).accessibilityLabel(compactText("Show hidden files")).accessibilityValue(showHidden ? compactText("On") : compactText("Off"))
            Button { showIgnored.toggle(); category = .all; treeMode = false } label: {
                if loadingIgnored { ProgressView().controlSize(.mini).frame(width: 24, height: 23) }
                else { WorkspaceStatusIcon(kind: .ignored).opacity(showIgnored ? 1 : 0.58) }
            }.buttonStyle(.plain).disabled(repository == nil)
                .help(compactText("Show ignored files (read-only)")).accessibilityLabel(compactText("Show ignored files (read-only)")).accessibilityValue(showIgnored ? compactText("On") : compactText("Off"))
        }
    }
    private func categoryTitle(_ item: WorkspaceStatusFilter) -> String { compactText(item.rawValue) }
    private var fileControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(text("filter"), text: $filter).textFieldStyle(.plain)
            }.padding(.horizontal, 9).frame(height: 28).rayGitInputSurface().frame(width: 170)
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
                        WorkspaceStatusIcon(file: file.file)
                        Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }.width(min: 120, ideal: 220).customizationID("filename").disabledCustomizationBehavior(.visibility)
                TableColumn(designWorkspaceText("Status"), value: \.statusKey) { file in
                    if let value = file.file { status(value.isConflict ? "U" : value.isUntracked ? "?" : value.indexStatus != " " ? value.indexStatus : value.worktreeStatus, selected: selection.contains(file.path)) }
                    else { Text(compactText("Ignored · read-only")).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.width(min: 70, ideal: 90).customizationID("status")
                TableColumn(text("workspace"), value: \.worktreeKey) { file in status(file.file?.worktreeStatus ?? " ", selected: selection.contains(file.path)) }.width(min: 65, ideal: 85).customizationID("workspace").defaultVisibility(.hidden)
                TableColumn(text("index"), value: \.indexKey) { file in status(file.file?.indexStatus ?? " ", selected: selection.contains(file.path)) }.width(min: 65, ideal: 85).customizationID("index").defaultVisibility(.hidden)
                TableColumn(text("directory"), value: \.directory) { file in
                    let directory = (file.path as NSString).deletingLastPathComponent
                    Text(directory.isEmpty ? "—" : directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 80, ideal: 180).customizationID("directory")
            }
            .font(.system(size: 12)).environment(\.defaultMinListRowHeight, 28)
            .contextMenu(forSelectionType: String.self) { paths in
                if paths.isEmpty {
                    actionButton("stageAll", .stageAll, Set(files.map(\.path)))
                    actionButton("unstageAll", .unstageAll, Set(files.map(\.path)))
                } else if paths.allSatisfy({ ignoredPaths.contains($0) }) {
                    Button(text("reveal")) { reveal(paths) }
                    copyButtons(paths)
                } else {
                    actionButton("open", .open, paths)
                    actionButton("reveal", .reveal, paths)
                    Divider()
                    actionButton("compare", .compare, paths, single: true)
                    actionButton("history", .history, paths, single: true)
                    Divider()
                    actionButton("stage", .stage, paths)
                    actionButton("unstage", .unstage, paths)
                    actionButton("discard", .discard, paths)
                    Divider()
                    copyButtons(paths)
                }
            } primaryAction: { paths in performCompare(paths) }
    }

    @ViewBuilder private func copyButtons(_ paths: Set<String>) -> some View {
        Button(text("copyName")) { copy(paths.sorted().map { ($0 as NSString).lastPathComponent }) }
        Button(text("copyPath")) { if let repository { copy(paths.sorted().map { repository.url.appendingPathComponent($0).path }) } }.disabled(repository == nil)
        Button(text("copyRelativePath")) { copy(paths.sorted()) }
    }
    private func copy(_ paths: [String]) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string) }
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
    private func status(_ value: String, selected: Bool) -> some View {
        let key = [" ": "none", "?": "untracked", "M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type"][value]
        let color: Color = value == "A" || value == "?" ? .green : value == "D" ? .red : ["M", "R", "U"].contains(value) ? .orange : .secondary
        return Group {
            if selected { Text(key.map(text) ?? value).foregroundStyle(Color.white).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            else if value == " " { Text(text("none")).foregroundStyle(.tertiary).font(.system(size: 11)) }
            else { RayGitBadge(key.map(text) ?? value, tint: color) }
        }
    }
}
