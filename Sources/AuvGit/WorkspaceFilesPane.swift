import SwiftUI
import AppKit
import GitCore
import AuvGitLocalization

enum FileAction {
    case compare, resolveOurs, resolveTheirs, resolveBoth, recreateConflict, open, reveal, history, stage, unstage, discard
    case copyName, copyFiles, copyPath, copyRelativePath, stageAll, unstageAll, rename, ignore, trash
}
struct FilePaneShortcutRequest {
    let id = UUID()
    let command: ShortcutCommand
}

struct WorkspaceFilesPane<TreeContent: View>: View {
    let files: [GitFile]
    var recreatableConflicts: Set<String> = []
    var statusFailure: String? = nil
    var automaticallySelectedPath: String? = nil
    var initialSelectionReady = false
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
    @State private var sortOrder: [WorkspaceFilePreparation.Sort] = []
    @State private var category = WorkspaceStatusFilter.all
    @AppStorage("workspace.showHiddenFiles") private var showHidden = true
    @State private var showIgnored = false
    @State private var ignoredPaths: [String] = []
    @State private var ignoredRepository: String?
    @State private var loadingIgnored = false
    @State private var ignoredRequestID = UUID()
    @State private var ignoredError: String?
    private typealias Row = WorkspaceFileRow
    @State private var visibleFiles: [Row] = []
    @State private var visiblePaths: Set<String> = []
    @State private var statusCounts: [WorkspaceStatusFilter: Int] = [:]
    @State private var initialSelectionRepository: String?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationID = UUID()
    @State private var displayedPreparation: WorkspaceFilePreparation?
    @State private var displayedRepository: String?
    @State private var preparing = true

    private var preparationRequest: WorkspaceFilePreparation {
        return WorkspaceFilePreparation(repository: repository?.url.path, files: files, ignoredPaths: ignoredRepository == repository?.url.path ? ignoredPaths : [], filter: filter, filterCase: filterCase, category: category, showHidden: showHidden, showIgnored: showIgnored, sort: sortOrder)
    }
    private func rebuildVisibleFiles() {
        let request = preparationRequest
        if !preparing, displayedPreparation == request { applyInitialSelection(); return }
        preparationTask?.cancel()
        let id = UUID()
        preparationID = id
        if let result = WorkspaceFilePreparationCache.shared.cached(request) {
            displayedPreparation = request
            visibleFiles = result.rows
            visiblePaths = result.paths
            statusCounts = result.counts
            displayedRepository = repository?.url.path
            preparing = false
            applyInitialSelection()
            return
        }
        preparing = true
        preparationTask = Task { @MainActor in
            // Coalesce the file, repository and preference changes from one view update.
            await Task.yield()
            guard !Task.isCancelled, preparationID == id else { return }
            let request = preparationRequest
            let worker = Task.detached(priority: .userInitiated) { try WorkspaceFilePreparationCache.shared.prepare(request) }
            let result = await withTaskCancellationHandler {
                try? await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, preparationID == id, request.repository == repository?.url.path, let result else { return }
            displayedPreparation = request
            visibleFiles = result.rows
            visiblePaths = result.paths
            statusCounts = result.counts
            displayedRepository = request.repository
            preparing = false
            applyInitialSelection()
        }
    }
    private func applyInitialSelection() {
        guard !preparing, displayedRepository == repository?.url.path else { return }
        if let repositoryPath = repository?.url.path, initialSelectionRepository != repositoryPath, initialSelectionReady {
            initialSelectionRepository = repositoryPath
            if let first = visibleFiles.first,
               selection == automaticallySelectedPath.map({ Set([$0]) }) || selection.isDisjoint(with: visiblePaths) {
                selection = [first.path]
            }
        }
    }
    private var treeVisiblePaths: Set<String>? {
        if category == .all && showHidden && filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if displayedRepository != repository?.url.path {
            return WorkspaceFilePreparationCache.shared.cached(preparationRequest)?.paths ?? []
        }
        return visiblePaths
    }
    private func compactText(_ key: String) -> String { L10n.text(key, table: "CompactWorkspace") }
    private func text(_ key: String) -> String { L10n.text(key, table: "Files") }
    private func eligible(_ action: FileAction, _ paths: Set<String>) -> Set<String> {
        if [.stage, .unstage, .discard, .stageAll, .unstageAll].contains(action) {
            return WorkspaceFileActionTargets.paths(for: action, files: files, selection: paths)
        }
        if paths.count == 1, let path = paths.first {
            guard let file = files.first(where: { $0.path == path }), fileEligible(action, file) else { return [] }
            return [path]
        }
        return Set(files.lazy.filter { paths.contains($0.path) && fileEligible(action, $0) }.map(\.path))
    }
    private func fileEligible(_ action: FileAction, _ file: GitFile) -> Bool {
        switch action {
        case .compare: return true
        case .open: return file.worktreeStatus != "D" && !(file.indexStatus == "D" && !file.isUnstaged)
        case .history: return !file.isUntracked && file.indexStatus != "A"
        case .stage, .stageAll: return file.isUnstaged && !file.isConflict
        case .unstage, .unstageAll: return file.isStaged && !file.isConflict
        case .discard: return file.isUnstaged || file.isConflict
        default: return true
        }
    }
    private func performCompare(_ paths: Set<String>) {
        guard !preparing, displayedRepository == repository?.url.path, !isBusy, paths.count == 1 else { return }
        if paths.allSatisfy({ ignoredPaths.contains($0) }) { reveal(paths); return }
        guard eligible(.compare, paths).count == 1 else { return }
        if AuvGitPreferences.doubleClick == "stage", let file = files.first(where: { paths.contains($0.path) }), !file.isConflict {
            onAction(file.isUnstaged ? .stage : .unstage, paths)
        } else { onAction(.compare, paths) }
    }
    private func actionButton(_ key: String, _ action: FileAction, _ paths: Set<String>, single: Bool = false) -> some View {
        let includesAll = [.stage, .unstage, .discard, .stageAll, .unstageAll].contains(action) && paths.isEmpty
        let enabled = !isBusy && !preparing && displayedRepository == repository?.url.path && (!single || paths.count == 1) && files.contains {
            (includesAll || paths.contains($0.path)) && fileEligible(action, $0)
        }
        return Button(text(key)) {
            if !preparing, displayedRepository == repository?.url.path, !isBusy {
                onAction(action, eligible(action, paths))
            }
        }.disabled(preparing || displayedRepository != repository?.url.path || !enabled)
    }

    private var content: some View {
        // Resolve an exact hit during rendering, before onChange publishes the new state.
        let cached = displayedRepository == repository?.url.path ? nil : WorkspaceFilePreparationCache.shared.cached(preparationRequest)
        let rows = cached?.rows ?? visibleFiles
        let statuses = statusControls
        let controls = fileControls
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { statuses; Spacer(minLength: 4); controls }
                VStack(spacing: 8) { HStack { statuses; Spacer() }; HStack { controls; Spacer() } }
            }.controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).padding(.horizontal, 10).padding(.vertical, 3).auvGitChrome()
            Divider()
            if treeMode && statusFailure == nil { treeContent(treeVisiblePaths).disabled(preparing).background { if let fileFocus { WorkspaceFileFocusRegion(focus: fileFocus).allowsHitTesting(false).accessibilityHidden(true) } } }
            else {
                fileTable(rows, ready: cached != nil || (!preparing && displayedRepository == repository?.url.path))
                    .overlay {
                        if rows.isEmpty && !preparing && displayedRepository == repository?.url.path {
                            AuvGitEmptyState(title: statusFailure ?? text(files.isEmpty ? "clean" : "noFiles"), systemImage: statusFailure != nil ? "exclamationmark.triangle" : files.isEmpty ? "checkmark.circle" : "magnifyingglass")
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }
    private var filteredContent: some View {
        content
        .onAppear { rebuildVisibleFiles(); if treeMode && showIgnored { treeMode = false } }
        .onChange(of: shortcutRequest?.id) { _, _ in performShortcut() }
        .onChange(of: files) { _, _ in rebuildVisibleFiles(); if showIgnored { Task { await loadIgnored() } } }
        .onChange(of: repository?.url.path) { _, _ in initialSelectionRepository = nil; rebuildVisibleFiles() }
        .onChange(of: initialSelectionReady) { _, _ in applyInitialSelection() }
        .onChange(of: filter) { _, _ in rebuildVisibleFiles() }
        .onChange(of: filterCase) { _, _ in rebuildVisibleFiles() }
        .onChange(of: category) { _, _ in rebuildVisibleFiles() }
        .onChange(of: showHidden) { _, _ in rebuildVisibleFiles() }
    }
    var body: some View {
        filteredContent
        .onDisappear { preparationTask?.cancel() }
        .onChange(of: ignoredPaths) { _, _ in rebuildVisibleFiles() }
        .onChange(of: sortOrder) { _, _ in rebuildVisibleFiles() }
        .task(id: (repository?.url.path ?? "") + "|\(showIgnored)") { await loadIgnored() }
        .onChange(of: showIgnored) { _, value in rebuildVisibleFiles(); if value { treeMode = false } }
        .onReceive(NotificationCenter.default.publisher(for: .auvGitWorktreeChanged)) { notification in
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
                Image(systemName: "eye").font(.system(size: 13)).frame(width: 24, height: 23).contentShape(Rectangle()).foregroundStyle(showHidden ? AuvGitStyle.blue : Color.secondary)
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
            }.padding(.horizontal, 9).frame(height: 24).auvGitInputSurface().frame(width: 170)
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
                actionButton("stageAll", .stageAll, [])
                actionButton("unstageAll", .unstageAll, [])
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help(text("allActions")).accessibilityLabel(text("allActions"))
        }
    }
    private var visibleColumns: Set<String> {
        Set(["filename", "status", "workspace", "index", "directory"].filter { id in
            if id == "filename" { return true }
            switch columnCustomization[visibility: id] {
            case .visible: return true
            case .hidden: return false
            default: return id != "workspace" && id != "index"
            }
        })
    }
    private func fileTable(_ rows: [Row], ready: Bool) -> some View {
        WorkspaceNativeFilesTable(rows: rows, files: files, repository: repository, selection: Binding(get: { selection }, set: { paths in
            guard !preparing, displayedRepository == repository?.url.path else { return }
            selection = paths
        }), isBusy: isBusy, sortOrder: $sortOrder, visibleColumns: visibleColumns, onVisibleColumnsChange: { columns in
            for id in ["filename", "status", "workspace", "index", "directory"] {
                columnCustomization[visibility: id] = columns.contains(id) ? .visible : .hidden
            }
        }, onAction: { action, paths in
            guard !preparing, displayedRepository == repository?.url.path else { return }
            onAction(action, paths)
        }, onCompare: performCompare, fileFocus: fileFocus, isReady: ready, recreatableConflicts: recreatableConflicts)
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
            guard !Task.isCancelled, ignoredRequestID == requestID, repository.url == self.repository?.url else { return }
            ignoredPaths = paths; ignoredRepository = repository.url.path; ignoredError = nil
        } catch { if !Task.isCancelled, ignoredRequestID == requestID, repository.url == self.repository?.url { ignoredError = compactText("Ignored files could not be loaded") } }
    }

}

/// Apply native table metrics once the SwiftUI table is attached; the list-row
/// environment alone does not control NSTableView's header or intercell gap.
