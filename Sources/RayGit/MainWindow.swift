import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

struct MainWindow: View {
    @ObservedObject var store: RepositoryStore
    @AppStorage(L10n.preferenceKey) private var languageCode = "system"
    @State private var namePrompt: NamePrompt?
    @State private var promptValue = ""
    @FocusState private var commitFocused: Bool
    struct NamePrompt: Identifiable {
        let id = UUID()
        let title: String
        let action: (String) -> Void
    }
    @State private var showActivity = false
    @State private var showTools = false
    @State private var fileTree = false
    @State private var showCreate = false
    @State private var showNetwork = false
    @State private var showTags = false
    @State private var confirmation: PendingAction?
    @Environment(\.scenePhase) private var scenePhase
    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: () -> Void
    }
    private var windowContent: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                    Spacer(); Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(mainText("dismissError")).accessibilityLabel(mainText("dismissError"))
                }.padding(10).background(Color.orange.opacity(0.10))
                Divider()
            }
            if !store.openRepositories.isEmpty { repositoryTabs; Divider() }
            if store.repository != nil { actionBar; Divider() }
            HSplitView {
                sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                if store.repository != nil { workspace.frame(minWidth: 880) }
                else { welcome.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Divider()
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.mini) }
                else { Circle().fill(store.error == nil ? Color.green : .orange).frame(width: 6, height: 6) }
                Text(store.status).lineLimit(1)
                Spacer()
                if !store.branch.isEmpty { Label(store.branch, systemImage: "arrow.triangle.branch") }
                Button { showActivity = true } label: { Image(systemName: "terminal") }.buttonStyle(.plain).help(mainText("activity"))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(store.repositoryURL?.lastPathComponent ?? "RayGit")
    }
    private var toolbarContent: some View {
        windowContent.toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { showCreate = true } label: { Label(workflowText("Create Repository"), systemImage: "plus") }.disabled(store.isBusy)
                Button { showTags = true } label: { Label(workflowText("Tag Management"), systemImage: "tag") }.disabled(store.repository == nil || store.isBusy)
                Button { showNetwork = true } label: { Label(workflowText("Network"), systemImage: "network") }.disabled(store.repository == nil || store.isBusy)
                Button { showTools = true } label: { Label(workflowText("Repository Tools"), systemImage: "wrench.and.screwdriver") }.disabled(store.repository == nil || store.isBusy)
                Button { store.chooseRepository() } label: { Label(mainText("open"), systemImage: "folder.badge.plus") }.help(mainText("openHelp")).disabled(store.isBusy)
                Button { Task { await store.refresh() } } label: { Label(mainText("refresh"), systemImage: "arrow.clockwise") }.help(mainText("refreshHelp")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem {
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button { languageCode = language.rawValue } label: {
                            HStack {
                                Text(language.rawValue == "system" ? mainText("systemLanguage") : language.nativeName)
                                if languageCode == language.rawValue { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: { Label(mainText("language"), systemImage: "globe") }.labelStyle(.titleAndIcon)
            }

        }
    }
    private var observedContent: some View {
        toolbarContent.onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { event in
            if let url = event.object as? URL, url == store.repositoryURL { Task { await store.refresh() } }
        }
        .onChange(of: store.amend) { _, value in fillAmendMessage(value) }
        .onChange(of: store.selectedPaths) { _, _ in if let file = store.selectedFile { store.stagedDiff = file.isStaged && !file.isUnstaged }; Task { await store.loadDiff() } }
        .onChange(of: store.stagedDiff) { _, _ in Task { await store.loadDiff() } }
        .onChange(of: store.ignoreWhitespace) { _, _ in Task { await store.loadDiff() } }
        .onChange(of: store.mode) { _, _ in Task { await store.loadDiff() } }
        .onChange(of: store.selectedCommit) { _, _ in Task { await store.loadCommitFiles() } }
        .onChange(of: store.selectedCommitPath) { _, _ in Task { await store.loadDiff() } }
        .onChange(of: store.historySearch) { _, _ in store.scheduleSearch() }
        .onChange(of: store.historyAuthor) { _, _ in store.scheduleSearch() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
    }
    var body: some View {
        observedContent.alert(item: $confirmation) { action in Alert(title: Text(action.title), message: Text(action.message), primaryButton: .default(Text(mainText("continue")), action: action.action), secondaryButton: .cancel(Text(mainText("cancel")))) }
        .sheet(item: $namePrompt) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Text(prompt.title).font(.headline)
                TextField(interactionText("Name"), text: $promptValue).textFieldStyle(.roundedBorder).onSubmit { submitName(prompt) }
                HStack { Spacer(); Button(mainText("cancel")) { namePrompt = nil }; Button(mainText("continue")) { submitName(prompt) }.buttonStyle(.borderedProminent).disabled(promptValue.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 460)
        }
        .sheet(isPresented: $showTags) { TagManagementView(store: store) }
        .sheet(isPresented: $showNetwork) { NetworkOperationsView(store: store) }
        .sheet(isPresented: $showTools) { RepositoryTools(store: store) }
        .sheet(isPresented: $showCreate) { CreateRepositorySheet(store: store) }
        .sheet(isPresented: $showActivity) {
            VStack(alignment: .leading) {
                HStack { Text(mainText("activity")).font(.headline); Spacer(); Button(mainText("close")) { showActivity = false } }
                ScrollView { Text(store.activity.isEmpty ? mainText("noActivity") : store.activity.joined(separator: "\n\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(width: 650, height: 400)
        }
    }
    private var repositoryTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(store.openRepositories, id: \.self) { path in
                    Button { Task { await store.open(URL(fileURLWithPath: path)) } } label: {
                        HStack { Image(systemName: "externaldrive"); Text(URL(fileURLWithPath: path).lastPathComponent) }
                    }.buttonStyle(.bordered).tint(path == store.repositoryURL?.path ? .accentColor : .secondary).disabled(store.isBusy)
                    Button { store.closeRepositoryTab(path) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(store.isBusy)
                }
            }.padding(6)
        }
    }
    private func mainText(_ key: String, _ args: CVarArg...) -> String { L10n.text(key, table: "Main", arguments: args) }
    func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let root = store.repositoryURL
        confirmation = PendingAction(title: title, message: message) { guard store.repositoryURL == root else { return }; action() }
    }
    var sidebar: some View { RepositorySidebar(store: store, onAction: sidebarAction) }
    var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 58, weight: .light)).foregroundStyle(Color.accentColor)
            Text("RayGit").font(.largeTitle.bold())
            Text(mainText("welcomeSubtitle")).font(.title3).foregroundStyle(.secondary)
            Button(mainText("openLocal")) { store.chooseRepository() }.buttonStyle(.borderedProminent).controlSize(.large)
            Text(mainText("shortcuts")).font(.caption).foregroundStyle(.tertiary)
        }
    }
    var workspace: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(mainText("view"), selection: $store.mode) { Text(mainText("workspaceCount", store.files.count)).tag("workspace"); Text(mainText("history")).tag("history") }.pickerStyle(.segmented).frame(width: 350)
                Spacer()
                Text(store.repositoryURL?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }.padding(10)
            if store.historyPath != nil || store.historyRef != nil {
                HStack { Label(store.historyPath ?? store.historyRef ?? "", systemImage: "line.3.horizontal.decrease.circle").lineLimit(1); Spacer(); Button(interactionText("Show All History")) { store.showHistory(path: nil, ref: nil) } }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if store.mode == "workspace" {
                VSplitView {
                    filesPane.frame(minHeight: 150, idealHeight: 210)
                    diffPane.frame(minHeight: 200, idealHeight: 270)
                    HSplitView {
                        historyPane(compact: true).frame(minWidth: 400)
                        commitPane.frame(minWidth: 290, idealWidth: 340, maxWidth: 450)
                    }.frame(minHeight: 210, idealHeight: 240)
                }
            } else {
                VSplitView {
                    historyPane(compact: false).frame(minHeight: 230, idealHeight: 360)
                    HSplitView {
                        List(selection: $store.selectedCommitPath) {
                            Section(mainText("changedFiles", store.commitFiles.count)) {
                                ForEach(store.commitFiles) { file in HStack(spacing: 7) { Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(statusColor(file.status)); Text(file.path).font(.system(size: 12)).lineLimit(2) }.tag(file.path) }
                            }
                        }.contextMenu(forSelectionType: String.self) { paths in
                            if let path = paths.first { Button(interactionText("Show Changes")) { compareCommitFile(path) }; Button(interactionText("Copy Relative Path")) { copyText(path) } }
                        } primaryAction: { paths in if let path = paths.first { compareCommitFile(path) } }
                        .frame(minWidth: 180, idealWidth: 235, maxWidth: 350)
                        diffPane.frame(minWidth: 400, minHeight: 230)
                    }
                }
            }
        }
    }
    var filesPane: some View {
        VStack(spacing: 0) {
            Picker(workflowText("Files view"), selection: $fileTree) { Text(workflowText("Status list")).tag(false); Text(workflowText("Directory tree")).tag(true) }.pickerStyle(.segmented).frame(width: 260).padding(6)
            if fileTree, let repository = store.repository { WorkspaceTree(repository: repository, openFile: { path in ComparePresenter.show(title: path, repository: repository, target: .worktree(path: path, untracked: store.files.first(where: { $0.path == path })?.isUntracked ?? false)) }, isBusy: store.isBusy, setBusy: { store.isBusy = $0 }).id(repository.url) }
            else { WorkspaceFilesPane(files: store.files, selection: $store.selectedPaths, filter: $store.fileFilter, isBusy: store.isBusy, onAction: fileAction) }
        }
    }
    var diffPane: some View {
        VStack(spacing: 0) {
            HStack {
                if store.mode == "workspace" { Picker(mainText("diffScope"), selection: $store.stagedDiff) { Text(mainText("workspace")).tag(false); Text(mainText("staged")).tag(true) }.pickerStyle(.segmented).frame(width: 240) }
                Spacer()
                if store.mode == "workspace", store.selectedPaths.count == 1 { Button(compareText("Edit / Three-way Compare")) { fileAction(.compare, store.selectedPaths) }.disabled(store.isBusy) }
                Toggle(mainText("ignoreWhitespace"), isOn: $store.ignoreWhitespace).toggleStyle(.checkbox).font(.caption)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            DiffPane(text: store.diffText, title: store.diffTitle, isLoading: store.loadingDiff)
        }
    }
    var commitPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(mainText("commit"), systemImage: "checkmark.circle").font(.headline)
            Text(mainText("stagedCount", store.stagedCount)).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.commitMessage).focused($commitFocused).font(.system(size: 13)).scrollContentBackground(.hidden).padding(7).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(alignment: .topLeading) { if store.commitMessage.isEmpty { Text(mainText("commitPlaceholder")).foregroundStyle(.tertiary).font(.system(size: 13)).padding(12).allowsHitTesting(false) } }.frame(minHeight: 65)
            Toggle(mainText("amend"), isOn: $store.amend).font(.caption)
            HStack { Button("Signed-off-by", action: addSignoff); Button(workflowText("commitTemplate"), action: loadTemplate) }.font(.caption)
            if store.amend { Text(mainText("amendWarning")).font(.caption).foregroundStyle(.orange) }
            Button { if store.amend { confirm(mainText("amend"), mainText("amendMessage")) { store.commit() } } else { store.commit() } } label: { Text(store.amend ? mainText("amendCommit") : mainText("commitStaged")).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(store.isBusy || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!store.amend && store.stagedCount == 0) || store.files.contains(where: \.isConflict))
            Text(mainText("commitNote")).font(.caption2).foregroundStyle(.secondary)

        }.padding(14)
    }
    private func jumpToCommit(_ value: String) {
        guard let repo = store.repository, !value.isEmpty else { return }
        Task { do { let hash = try await repo.workflowRevision(value); if let commit = try await repo.log(limit: 1, ref: hash).first, store.repositoryURL == repo.url { CommitDetailPresenter.show(commit: commit, repository: repo) } } catch { store.report(error) } }
    }
    private func fillAmendMessage(_ value: Bool) {
        guard value, store.commitMessage.isEmpty, let repo = store.repository else { return }
        Task { do { let message = try await repo.workflowRead(["log", "-1", "--format=%B"]); if store.repositoryURL == repo.url && store.amend { store.commitMessage = message } } catch { store.report(error) } }
    }
    private func addSignoff() {
        guard let repo = store.repository else { return }
        Task { do {
            let name = try await repo.workflowRead(["config", "user.name"]).trimmingCharacters(in: .newlines)
            let email = try await repo.workflowRead(["config", "user.email"]).trimmingCharacters(in: .newlines)
            if store.repositoryURL == repo.url { store.commitMessage += "\n\nSigned-off-by: " + name + " <" + email + ">" }
        } catch { store.report(error) } }
    }
    private func loadTemplate() {
        guard let repo = store.repository else { return }
        Task { do {
            let path = try await repo.workflowRead(["config", "--path", "commit.template"]).trimmingCharacters(in: .newlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.url.appendingPathComponent(path)
            let message = try String(contentsOf: url, encoding: .utf8)
            if store.repositoryURL == repo.url { store.commitMessage = message }
        } catch { store.report(error) } }
    }
    func statusName(_ status: String) -> String { [" ": "—", "?": mainText("untracked"), "M": mainText("modified"), "A": mainText("added"), "D": mainText("deleted"), "R": mainText("renamed"), "C": mainText("copied"), "U": mainText("conflict"), "T": mainText("type") ][status] ?? status }
    func statusColor(_ status: String) -> Color { switch status { case "A", "?": return .green; case "D": return .red; case "M", "R", "U": return .orange; default: return .secondary } }
}

extension MainWindow {
    var actionBar: some View {
        HStack(spacing: 6) {
            actionButton(mainText("fetch"), icon: "arrow.down.to.line", enabled: !store.isBusy) { store.operation("Fetch") { try await $0.fetch() } }
            actionButton(mainText("pull"), icon: "arrow.down.circle", enabled: !store.isBusy) { confirm(mainText("pullTitle"), mainText("pullMessage")) { store.operation("Pull") { try await $0.pull() } } }
            actionButton(mainText("push"), icon: "arrow.up.circle", enabled: !store.isBusy) { confirm(mainText("pushTitle"), mainText("pushMessage")) { store.operation("Push") { try await $0.push() } } }
            Divider().frame(height: 36)
            actionButton(mainText("commit"), icon: "checkmark.square", enabled: !store.isBusy) { store.mode = "workspace"; commitFocused = true }
            Spacer(minLength: 8)
            actionButton(mainText("stage"), icon: "arrow.right.doc.on.clipboard", enabled: !store.isBusy && selectedFiles.contains { $0.isUnstaged && !$0.isConflict }) { fileAction(.stage, store.selectedPaths) }
            actionButton(mainText("unstage"), icon: "arrow.uturn.backward", enabled: !store.isBusy && selectedFiles.contains { $0.isStaged && !$0.isConflict }) { fileAction(.unstage, store.selectedPaths) }
            actionButton(interactionText("Discard…"), icon: "arrow.uturn.backward.square", enabled: !store.isBusy && !selectedFiles.isEmpty && selectedFiles.allSatisfy { !$0.isUntracked && !$0.isConflict && $0.isUnstaged }) { fileAction(.discard, store.selectedPaths) }
            Divider().frame(height: 36)
            actionButton(mainText("stash"), icon: "archivebox", enabled: !store.isBusy && !store.files.isEmpty) { confirm(mainText("stashTitle"), mainText("stashMessage")) { store.operation("贮藏") { try await $0.stash(message: "RayGit stash") } } }
            actionButton(mainText("newBranch"), icon: "arrow.triangle.branch", enabled: !store.isBusy) { askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } } }
        }.padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }
    private var selectedFiles: [GitFile] { store.files.filter { store.selectedPaths.contains($0.path) } }
    private func actionButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 22, weight: .regular)); Text(title).font(.system(size: 11)) }.frame(minWidth: 54).padding(.horizontal, 5).padding(.vertical, 3) }.buttonStyle(.plain).disabled(!enabled).help(title).accessibilityLabel(title)
    }
    private func historyPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if compact { HStack { Text(interactionText("Log")).font(.system(size: 12, weight: .semibold)); Spacer(); Button { store.mode = "history" } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(interactionText("Expand History")) }.padding(.horizontal, 10).frame(height: 28).background(.bar) }
            HistoryPane(commits: store.commits, selection: $store.selectedCommit, search: $store.historySearch, isLoading: store.loadingHistory, hasMore: store.hasMore, onLoadMore: { Task { await store.loadHistory(reset: false) } }, isBusy: store.isBusy, onAction: historyAction, compact: compact, onJump: jumpToCommit, authorFilter: $store.historyAuthor)
        }
    }
    private func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func askName(_ title: String, initial: String = "", action: @escaping (String) -> Void) {
        let root = store.repositoryURL
        promptValue = initial
        namePrompt = NamePrompt(title: title) { value in guard store.repositoryURL == root, !store.isBusy else { return }; action(value) }
    }
    private func submitName(_ prompt: NamePrompt) { let value = promptValue.trimmingCharacters(in: .whitespaces); guard !value.isEmpty else { return }; namePrompt = nil; prompt.action(value) }
    private func compareCommitFile(_ path: String) {
        guard let repository = store.repository, let hash = store.selectedCommit else { return }
        ComparePresenter.show(title: "\(String(hash.prefix(8))) / \(path)", repository: repository, target: .commit(hash: hash, path: path))
    }
    private func fileAction(_ action: FileAction, _ paths: Set<String>) {
        guard let repository = store.repository, let root = store.repositoryURL else { return }
        let files = store.files.filter { paths.contains($0.path) }
        let ordered = files.map(\.path).sorted()
        switch action {
        case .compare:
            guard let file = files.first, files.count == 1 else { return }
            let staged = paths == store.selectedPaths ? (store.stagedDiff && file.isStaged) : (file.isStaged && !file.isUnstaged)
            ComparePresenter.show(title: file.path, repository: repository, target: staged ? .staged(path: file.path) : .worktree(path: file.path, untracked: file.isUntracked))
        case .open:
            for path in ordered { NSWorkspace.shared.open(root.appendingPathComponent(path)) }
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(ordered.map { root.appendingPathComponent($0) })
        case .history: if let path = ordered.first { store.showHistory(path: path, ref: nil) }
        case .stage, .stageAll:
            let targets = files.filter { $0.isUnstaged && !$0.isConflict }.map(\.path)
            guard !targets.isEmpty else { return }
            store.operation("暂存") { try await $0.stage(paths: targets) }
        case .unstage, .unstageAll:
            let targets = files.filter { $0.isStaged && !$0.isConflict }.map(\.path)
            guard !targets.isEmpty else { return }
            store.operation("取消暂存") { try await $0.unstage(paths: targets) }
        case .discard:
            guard !files.isEmpty, files.allSatisfy({ !$0.isUntracked && !$0.isConflict && $0.isUnstaged }) else { return }
            confirm(interactionText("Discard Working Tree Changes"), interactionText("Discard Message") + "\n\n" + ordered.joined(separator: "\n")) { store.operation(interactionText("Discard…")) { try await $0.discardWorktree(paths: ordered) } }
        case .copyName: copyText(ordered.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n"))
        case .copyPath: copyText(ordered.map { root.appendingPathComponent($0).path }.joined(separator: "\n"))
        case .copyRelativePath: copyText(ordered.joined(separator: "\n"))
        }
    }
    private func historyAction(_ action: HistoryAction, _ commit: GitCommit) {
        guard let repository = store.repository else { return }
        if action.isMutation && store.isBusy { return }
        if (action == .cherryPick || action == .revert) && commit.parents.count > 1 { return }
        switch action {
        case .show: CommitDetailPresenter.show(commit: commit, repository: repository)
        case .copyHash: copyText(commit.hash)
        case .copyMessage: copyText(commit.body.isEmpty ? commit.subject : commit.body)
        case .createBranch: askName(interactionText("Create Branch at %@", commit.shortHash)) { name in store.operation(interactionText("Create Branch")) { try await $0.createBranch(name: name, startPoint: commit.hash) } }
        case .createTag: askName(interactionText("Create Tag at %@", commit.shortHash)) { name in store.operation(interactionText("Create Tag")) { try await $0.createTag(name: name, commit: commit.hash) } }
        case .checkout: confirm(interactionText("Check Out Commit"), interactionText("Detached Message", commit.shortHash)) { store.operation(interactionText("Check Out Commit")) { try await $0.checkoutCommit(hash: commit.hash) } }
        case .cherryPick: confirm(interactionText("Cherry-Pick Commit"), interactionText("Cherry-Pick Message", commit.shortHash)) { store.operation(interactionText("Cherry-Pick Commit")) { try await $0.cherryPick(hash: commit.hash) } }
        case .revert: confirm(interactionText("Revert Commit"), interactionText("Revert Message", commit.shortHash)) { store.operation(interactionText("Revert Commit")) { try await $0.revert(hash: commit.hash) } }
        }
    }
    private func sidebarAction(_ action: SidebarAction, _ value: String) {
        switch action {
        case .openRepository: Task { await store.open(URL(fileURLWithPath: value)) }
        case .revealRepository: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)])
        case .removeRecent: store.recentPaths.removeAll { $0 == value }; UserDefaults.standard.set(store.recentPaths, forKey: "recentRepositories")
        case .copy: copyText(value)
        case .history: store.showHistory(path: nil, ref: value)
        case .checkout:
            guard !store.isBusy, !store.branches.contains(where: { $0.name == value && $0.isCurrent }) else { return }
            confirm(mainText("checkoutTitle", value), mainText("checkoutMessage")) { store.operation("切换分支") { try await $0.checkout(branch: value) } }
        case .rename: askName(interactionText("Rename Branch…"), initial: value) { name in store.operation(interactionText("Rename Branch…")) { try await $0.renameBranch(oldName: value, newName: name) } }
        case .delete: confirm(interactionText("Delete Branch…"), interactionText("Delete Branch Message", value)) { store.operation(interactionText("Delete Branch…")) { try await $0.deleteBranch(name: value) } }
        case .stashShow: if let repository = store.repository { ComparePresenter.show(title: value, repository: repository, stash: value) }
        case .stashApply: confirm(mainText("applyTitle", value), mainText("applyMessage")) { store.operation("应用贮藏") { try await $0.applyStash(ref: value) } }
        case .stashDrop: confirm(interactionText("Drop Stash…"), interactionText("Drop Stash Message", value)) { store.operation(interactionText("Drop Stash…")) { try await $0.dropStash(ref: value) } }
        }
    }
}
