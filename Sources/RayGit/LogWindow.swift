import AppKit
import SwiftUI
import Combine
import GitCore
import RayGitLocalization

func logText(_ key: String) -> String { L10n.text(key, table: "LogWindow") }
extension Notification.Name { static let rayGitReuseCommitMessage = Notification.Name("RayGitReuseCommitMessage") }

@MainActor
enum LogPresenter {
    private static var controllers: [URL: LogWindowController] = [:]
    static var hasWindows: Bool { !controllers.isEmpty }
    static var isLogWindowActive: Bool { controllers.values.contains { $0.window === NSApp.keyWindow } }
    static func refreshCurrentWindow() -> Bool {
        guard let current = controllers.values.first(where: { $0.window === NSApp.keyWindow }) else { return false }
        Task { await current.store.refresh() }
        return true
    }
    static func showForCurrentWindow(fallback: GitRepository?) {
        if let current = controllers.values.first(where: { $0.window === NSApp.keyWindow }) {
            if let repository = current.store.repository { show(repository: repository) }
        } else if let fallback { show(repository: fallback) }
    }
    static func show(repository: GitRepository, path: String? = nil, ref: String? = nil, search: String? = nil, selectedCommit: String? = nil, stashCommit: String? = nil, stashRef: String? = nil, applyFilter: Bool = false) {
        let key = repository.url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = controllers[key] {
            existing.apply(path: path, ref: ref, search: search, selectedCommit: selectedCommit, stashCommit: stashCommit, stashRef: stashRef)
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LogWindowController(repository: repository) { controllers.removeValue(forKey: key) }
        controllers[key] = controller
        controller.apply(path: path, ref: ref, search: search, selectedCommit: selectedCommit, stashCommit: stashCommit, stashRef: stashRef)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class LogWindowController: NSWindowController, NSWindowDelegate {
    let store = RepositoryStore(persistsSession: false, usesCheckedHistoryScope: true)
    private let closed: () -> Void
    private var ready = false
    private var requested: (path: String?, ref: String?, search: String?, selection: String?, stashCommit: String?, stashRef: String?) = (nil, nil, nil, nil, nil, nil)
    private var requestVersion = UUID()
    private var opening: Task<Void, Never>?
    init(repository: GitRepository, closed: @escaping () -> Void) {
        self.closed = closed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = repository.url.lastPathComponent + " — " + logText("Log")
        window.minSize = NSSize(width: 1040, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LogWindowContent(store: store).nativeFocusRoot().background(WindowFrameStyle()))
        WindowFrameAppearance.clip(window)
        super.init(window: window)
        window.delegate = self; window.center()
        opening = Task { [weak self] in
            guard let self else { return }
            await store.open(repository.url)
            guard !Task.isCancelled else { return }
            ready = true
            await loadRequested()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowDidBecomeKey(_ notification: Notification) {
        RepositoryStore.checkRemoteUpdatesForActivePanel()
        Task { await store.refreshIfChanged() }
    }
    func apply(path: String?, ref: String?, search: String?, selectedCommit: String?, stashCommit: String?, stashRef: String?) {
        requested = (path, ref, search, selectedCommit, stashCommit, stashRef)
        requestVersion = UUID()
        if ready { Task { await loadRequested() } }
    }
    private func loadRequested() async {
        let request = requested, version = requestVersion
        store.isRestoringViewState = true
        defer { if version == requestVersion { store.isRestoringViewState = false } }
        store.mode = "history"
        store.configureCheckedHistoryRefs()
        var reference = HistoryReference.canonical(request.ref, branches: store.branches)
        if reference == nil, let selection = request.selection, request.stashCommit == nil,
           let repository = store.repository {
            reference = HistoryBranchScope.preferred(containing: (try? await repository.branchesContaining(commit: selection)) ?? [], branches: store.branches) ?? selection
            guard version == requestVersion else { return }
        }
        let branchRefs = Set(store.branches.map(HistoryBranchScope.branchRef))
        if let reference, branchRefs.contains(reference) {
            // An explicit branch/commit context must be visible when reusing a Log window.
            let scope = HistoryBranchScope.preservingStashes(in: store.checkedHistoryRefs ?? HistoryBranchScope.defaultRefs(branches: store.branches, branch: store.branch), forBranch: reference)
            store.checkedHistoryRefs = scope
            if let root = store.repositoryURL { HistoryBranchScope.save(scope, repository: root) }
        }
        store.historyPath = request.path
        store.historyRef = HistoryBranchScope.presentationReference(requested: reference, previous: store.historyRef, availableBranches: branchRefs)
        store.historyPinnedCommit = request.stashCommit == nil && reference == request.selection ? request.selection : nil
        store.historySearch = request.search ?? ""; store.historyAuthor = ""
        store.historyStashHash = request.stashCommit; store.historyStashRef = request.stashRef
        store.selectedCommit = request.selection; store.selectedCommitPath = nil
        store.commitFiles = []
        await store.loadHistory(reset: true)
        guard version == requestVersion else { return }
        if let selection = request.selection {
            while !store.commits.contains(where: { $0.hash == selection }), store.hasMore {
                let count = store.commits.count
                await store.loadHistory(reset: false)
                guard version == requestVersion else { return }
                if store.commits.count == count { break }
            }
        }
        if !store.commits.contains(where: { $0.hash == store.selectedCommit }) { store.selectedCommit = store.commits.first?.hash }
        store.historyNavigationGeneration = UUID()
        await store.loadCommitFiles()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !store.isBusy }
    func windowWillClose(_ notification: Notification) { opening?.cancel(); store.closeTransientSession(); closed() }
}

private struct LogWindowContent: View {
    @ObservedObject var store: RepositoryStore
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @State private var resetRequest: HistoryResetRequest?
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @State private var refSearch = ""
    @State private var highlightedReference: String?
    @State private var tags: [ManagedTag] = []
    @State private var showOperationLog = false
    @State private var mutation: Mutation?
    @State private var rebaseCommit: GitCommit?
    @State private var name = ""
    @State private var parent = 1
    private struct Mutation: Identifiable {
        let id = UUID()
        let action: HistoryAction
        let commit: GitCommit
    }
    private var commit: GitCommit? { store.commits.first { $0.hash == store.selectedCommit } }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                referenceSidebar.frame(minWidth: 185, idealWidth: 220, maxWidth: 300)
                VSplitView {
                    HSplitView {
                        HistoryPane(commits: store.commits, selection: $store.selectedCommit, search: $store.historySearch,
                            isLoading: store.loadingHistory, hasMore: store.hasMore,
                            onLoadMore: { Task { await store.loadHistory(reset: false) } }, isBusy: store.isBusy,
                            onAction: historyAction, onShowChanges: { if let path = store.selectedCommitPath { compare(path) } }, showsDetails: false, remoteBranchNames: Set(store.branches.filter(\.isRemote).map(\.name)), currentBranch: store.branches.first { $0.isCurrent && !$0.isRemote }, localUnpushedCommitHashes: store.localUnpushedCommitHashes, navigationGeneration: store.historyNavigationGeneration, onJump: jump, authorFilter: $store.historyAuthor)
                            .frame(minWidth: 520, minHeight: 270, idealHeight: 470)
                        VSplitView {
                            commitMetadata.frame(minWidth: 270, minHeight: 145, idealHeight: 230)
                            changedFiles.frame(minWidth: 270, minHeight: 130, idealHeight: 220)
                        }.frame(minWidth: 270, idealWidth: 330, maxWidth: 480)
                    }.frame(minHeight: 300, idealHeight: 500)
                    DiffPane(text: store.diffText, title: store.diffTitle, isLoading: store.loadingDiff, preview: store.staticPreview, leftRevisionTitle: store.diffLeftRevisionTitle, rightRevisionTitle: store.diffRightRevisionTitle)
                        .frame(minHeight: 180, idealHeight: 290)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if store.isBusy || store.loadingHistory { ProgressView().controlSize(.mini) }
                if store.error != nil {
                    Button { showOperationLog = true } label: {
                        Label(store.displayStatus, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(1).truncationMode(.tail).foregroundStyle(Color.orange).frame(height: 24)
                    }.buttonStyle(.plain).help(sidebarRefinementText("operationLog"))
                        .accessibilityLabel(sidebarRefinementText("operationLog") + ": " + store.displayStatus)
                } else {
                    Button { showOperationLog = true } label: {
                        Text(store.hasLatestOperation ? store.status : (store.repositoryURL?.path ?? "")).lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.plain).help(sidebarRefinementText("operationLog"))
                }
                Spacer()
                Text("\(store.commits.count)").monospacedDigit().fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                if !store.branch.isEmpty { Label(store.branch, systemImage: "arrow.triangle.branch") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28).rayGitChrome()
        }.background(RayGitStyle.canvas).buttonBorderShape(.roundedRectangle(radius: 6)).environment(\.locale, L10n.locale)
            .onChange(of: store.selectedCommit) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadCommitFiles() } }
            .onChange(of: store.selectedCommitPath) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
            .onChange(of: store.historySearch) { _, _ in guard !store.isRestoringViewState else { return }; store.scheduleSearch() }
            .onChange(of: store.historyAuthor) { _, _ in guard !store.isRestoringViewState else { return }; store.scheduleSearch() }
            .onChange(of: store.branches) { _, _ in Task { await loadTags() } }
            .onChange(of: store.commits) { _, _ in Task { await loadTags() } }
            .onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { event in
                if let url = event.object as? URL, url == store.repositoryURL { Task { await store.refresh(); await loadTags() } }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in Task { await store.pollForChanges() } }
            .rayGitSheet(item: $resetRequest) { HistoryResetSheet(store: store, request: $0) }
        .rayGitSheet(isPresented: $showOperationLog) { OperationLogView(store: store) }
            .rayGitSheet(item: $mutation) { request in mutationSheet(request) }
            .rayGitSheet(item: $rebaseCommit) { commit in
                RebaseWorkflowView(store: store, onClose: { rebaseCommit = nil }, initialBase: commit.hash)
                    .padding(20).frame(width: 1100, height: 850)
            }
    }
    private var referenceSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label(store.repositoryURL?.lastPathComponent ?? logText("Log"), systemImage: "folder").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { Task { await store.refresh(); await loadTags() } } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(store.isBusy)
            }.padding(12).rayGitChrome()
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); StableTextField(logText("Filter references"), text: $refSearch, rounded: false) }
                .font(.system(size: 12)).padding(8).rayGitInputSurface().padding(10)
            ScrollViewReader { proxy in
            List(selection: $highlightedReference) {
                scopeRow("HEAD", title: "HEAD", symbol: "arrow.triangle.branch")
                scopeRow(HistoryBranchScope.recyclable, title: logText("Recyclable commits"), symbol: "arrow.uturn.backward")
                Section(logText("Local branches")) { referenceRows(remote: false) }
                Section(logText("Remote branches")) { referenceRows(remote: true) }
                if !tags.isEmpty {
                    Section(logText("Tags")) {
                        ForEach(tags.filter { refSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(refSearch) }) { tag in
                            Label(tag.name, systemImage: "tag").tag("refs/tags/" + tag.name).id("refs/tags/" + tag.name).lineLimit(1)
                        }
                    }
                }
                if !store.stashes.isEmpty {
                    Section(interactionText("Stashes")) {
                        ForEach(store.stashes) { stash in scopeRow(HistoryBranchScope.stashRef(stash), title: stash.subject, symbol: "archivebox") }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).font(.system(size: 12))
                .onCopyCommand(perform: copyReference)
                .onChange(of: store.historyNavigationGeneration) { _, _ in refSearch = ""; highlightedReference = referenceSelection; proxy.scrollTo(referenceSelection, anchor: .center) }
                .onChange(of: store.branches) { _, _ in proxy.scrollTo(referenceSelection, anchor: .center) }
                .onChange(of: tags.map(\.name)) { _, _ in proxy.scrollTo(referenceSelection, anchor: .center) }
                .onAppear { highlightedReference = referenceSelection; proxy.scrollTo(referenceSelection, anchor: .center) }
            }

        }.background(RayGitStyle.sidebar)
    }
    private var referenceSelection: String { store.historyStashRef ?? HistoryReference.canonical(store.historyRef, branches: store.branches) ?? "" }
    private func copyReference() -> [NSItemProvider] {
        guard let reference = highlightedReference else { return [] }
        let branch = store.branches.first { HistoryBranchScope.branchRef($0) == reference }?.name
        let tag = tags.first { "refs/tags/" + $0.name == reference }?.name
        let stash = store.stashes.first { HistoryBranchScope.stashRef($0) == reference }?.subject
        return [NSItemProvider(object: (branch ?? tag ?? stash ?? reference) as NSString)]
    }
    private func referenceRows(remote: Bool) -> some View {
        ForEach(store.branches.filter { $0.isRemote == remote && (refSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(refSearch)) }) { branch in
            let ref = HistoryBranchScope.branchRef(branch)
            scopeRow(ref, title: branch.name, symbol: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
        }
    }
    private func scopeRow(_ ref: String, title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { HistoryBranchScope.isChecked(ref, in: store.checkedHistoryRefs ?? []) }, set: { store.setHistoryBranchChecked(ref, checked: $0) }))
                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(title)
            Label(title, systemImage: symbol).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle()).tag(ref).id(ref).help(ref)
    }
    private var commitMetadata: some View {
        VStack(alignment: .leading, spacing: 0) {
            RayGitPaneHeader(title: logText("Commit"), systemImage: "info.circle")
            if let commit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(commit.subject).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                        Text(commit.hash).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        CommitIdentityDetails(commit: commit)
                        if !commit.parents.isEmpty { Text(logText("Parents") + ": " + commit.parents.map { String($0.prefix(10)) }.joined(separator: ", ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                        Divider()
                        Text(commit.body.isEmpty ? commit.subject : commit.body).font(.system(size: 12)).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { RayGitEmptyState(title: logText("Select a commit"), systemImage: "clock.arrow.circlepath") }
        }.background(RayGitStyle.canvas)
    }
    private var changedFiles: some View {
        VStack(spacing: 0) {
            RayGitPaneHeader(title: historyActionText("files"), systemImage: "doc.on.doc", count: store.commitFiles.count)
            if store.selectedCommit == nil { RayGitEmptyState(title: logText("Select a commit"), systemImage: "doc.on.doc") }
            else if store.commitFiles.isEmpty { RayGitEmptyState(title: historyActionText("noFiles"), systemImage: "doc.on.doc") }
            else {
                List(store.commitFiles, selection: $store.selectedCommitPath) { file in
                    HStack(spacing: 7) { Text(file.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(store.selectedCommitPath == file.path ? Color.white : file.status.hasPrefix("D") ? Color.red : file.status.hasPrefix("A") ? Color.green : Color.orange); Text(file.path).font(.system(size: 12)).lineLimit(2) }
                        .foregroundStyle(store.selectedCommitPath == file.path ? Color.white : Color.primary)
                        .listRowBackground(store.selectedCommitPath == file.path ? RayGitStyle.blue : Color.clear)
                        .tag(file.path).help(file.originalPath.map { $0 + " → " + file.path } ?? file.path)
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { paths in
                        if let path = paths.first {
                            Button(interactionText("Show Changes")) { compare(path) }.configuredShortcut(.showChanges, using: shortcuts)
                            if let root = store.repositoryURL {
                                let fileURL = root.appendingPathComponent(path)
                                let exists = FileManager.default.fileExists(atPath: fileURL.path)
                                Divider()
                                Button(L10n.text("copyPath", table: "Files")) { copy(paths.sorted().map { root.appendingPathComponent($0).path }.joined(separator: "\n")) }
                                Divider()
                                Button(L10n.text("open", table: "Files")) { NSWorkspace.shared.open(fileURL) }.disabled(!exists)
                                Button(L10n.text("reveal", table: "Files")) { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }.disabled(!exists)
                            }
                        }
                    } primaryAction: { paths in if let path = paths.first { compare(path) } }
            }
        }.background(RayGitStyle.canvas)
    }
    private func loadTags() async {
        guard let repository = store.repository else { return }
        do { tags = try await repository.managedTags() } catch { store.report(error) }
    }
    private func compare(_ path: String) {
        guard let repository = store.repository, let hash = store.comparisonRevision(for: path) else { return }
        ComparePresenter.show(title: String(hash.prefix(8)) + " / " + path, repository: repository, target: .commit(hash: hash, path: path))
    }
    private func jump(_ value: String) {
        guard let repository = store.repository, !value.isEmpty else { return }
        Task {
            do {
                let hash = try await repository.workflowRevision(value)
                if let commit = try await repository.log(limit: 1, ref: hash).first {
                    if !store.commits.contains(where: { $0.hash == hash }) { store.commits.append(commit) }
                    store.selectedCommit = hash
                }
            } catch { store.report(error) }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func historyAction(_ action: HistoryAction, _ commit: GitCommit) {
        guard let repository = store.repository else { return }
        switch action {
        case .rebase: guard !store.isBusy else { return }; rebaseCommit = commit
        case .useCommitMessage:
            NotificationCenter.default.post(name: .rayGitReuseCommitMessage, object: repository.url, userInfo: ["message": commit.body.isEmpty ? commit.subject : commit.body])
        case .reset, .resetAdvanced:
            guard !store.isBusy else { return }
            resetRequest = HistoryResetRequest(commit: commit, repositoryURL: repository.url, advanced: action == .resetAdvanced)
        case .viewLog: LogPresenter.show(repository: repository, selectedCommit: commit.hash, applyFilter: true)
        case .show: CommitDetailPresenter.show(commit: commit, repository: repository)
        case .copyHash: copy(commit.hash)
        case .copyMessage: copy(commit.body.isEmpty ? commit.subject : commit.body)
        default: guard !store.isBusy else { return }; name = ""; parent = 1; mutation = Mutation(action: action, commit: commit)
        }
    }
    private func mutationSheet(_ request: Mutation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(historyActionText(request.action.rawValue)).font(.title3.weight(.semibold))
            Text(request.commit.subject).font(.system(size: 13)).lineLimit(3)
            Text(request.commit.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if request.action == .createBranch || request.action == .createTag {
                TextField(logText("Name"), text: $name).textFieldStyle(.roundedBorder)
            } else {
                Text(logText("This operation changes the repository. Review the selected commit before continuing.")).font(.caption).foregroundStyle(.secondary)
            }
            if [.cherryPick, .revert].contains(request.action), request.commit.parents.count > 1 {
                Text(L10n.text("explanation", table: "MergeActions")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("parent", table: "MergeActions"), selection: $parent) {
                    ForEach(Array(request.commit.parents.enumerated()), id: \.offset) { index, hash in
                        Text(L10n.text("parentChoice", table: "MergeActions", arguments: [index + 1, String(hash.prefix(12))])).tag(index + 1)
                    }
                }
            }
            HStack {
                DialogButton(workflowText("Cancel"), role: .cancel) { mutation = nil }
                DialogButton(workflowText("Continue"), prominent: true) { perform(request) }
                    .disabled(store.isBusy || ([.createBranch, .createTag].contains(request.action) && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(22).frame(width: 360)
    }
    private func perform(_ request: Mutation) {
        let name = name.trimmingCharacters(in: .whitespaces), mainline = request.commit.parents.count > 1 ? parent : nil
        mutation = nil
        store.operation(historyActionText(request.action.rawValue)) { repository in
            switch request.action {
            case .createBranch: try await repository.createBranch(name: name, startPoint: request.commit.hash)
            case .createTag: try await repository.createTag(name: name, commit: request.commit.hash)
            case .checkout: try await repository.checkoutCommit(hash: request.commit.hash)
            case .cherryPick: try await repository.cherryPick(hash: request.commit.hash, mainline: mainline)
            case .revert: try await repository.revert(hash: request.commit.hash, mainline: mainline)
            default: break
            }
        }
    }
}
