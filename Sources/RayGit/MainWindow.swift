import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

struct MainWindow: View {
    @ObservedObject var store: RepositoryStore
    @StateObject private var terminals = TerminalSessions()
    @AppStorage("preferences.filterCase") private var preferenceFilterCase = "insensitive"
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
    @State private var mergeAction: MergeActionPrompt?
    @State private var mainlineParent = 1
    private struct MergeActionPrompt: Identifiable {
        let id = UUID()
        let action: HistoryAction
        let commit: GitCommit
        let repositoryURL: URL
    }
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
            VSplitView {
                HSplitView {
                    sidebar.frame(minWidth: 190, idealWidth: 230, maxWidth: 260)
                    if store.repository != nil { workspace.frame(minWidth: 640) }
                    else { welcome.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(minHeight: terminals.visible ? 464 : 450)
                if terminals.visible, let directory = store.repositoryURL {
                    TerminalPane(terminals: terminals, store: store, directory: directory)
                        .frame(minHeight: 160, idealHeight: 240)
                        .id(TerminalConfiguration.identity(for: directory))
                }
            }
            Divider()
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.mini) }
                else { Circle().fill(store.error == nil ? Color.green : .orange).frame(width: 6, height: 6) }
                Text(store.status).lineLimit(1)
                Spacer()
                if !store.branch.isEmpty { Label(store.branch, systemImage: "arrow.triangle.branch") }
                Button { terminals.toggle(for: store.repositoryURL, store: store) } label: { Image(systemName: "terminal") }.buttonStyle(.plain).help(terminalText("toggle")).accessibilityLabel(terminalText("toggle")).disabled(store.repository == nil)
                Button { showActivity = true } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.plain).help(mainText("activity"))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .controlSize(.small)
        .frame(minHeight: terminals.visible ? 750 : 680)
        .navigationTitle(store.repositoryURL?.lastPathComponent ?? "RayGit")
        .background(TerminalShortcutMonitor { terminals.toggle(for: store.repositoryURL, store: store) }.frame(width: 0, height: 0))
    }
    private var toolbarContent: some View {
        // Recreate localized descendants without recreating MainWindow's session owner.
        windowContent.id(languageCode)
            .background(TitlebarToolbarSupport().frame(width: 0, height: 0))
            .modifier(ToolbarWindowTitleRemoval())
            // Version the customization identity: the old AppKit-injected identifiers
            // cannot be restored into SwiftUI's item storage. Keep other preferences intact.
            .toolbar(id: "RayGit.mainToolbar.swiftUI.v2") {
            ToolbarItem(id: "open", placement: .automatic) {
                Button { store.chooseRepository() } label: { Label(mainText("open"), systemImage: "folder.badge.plus") }
                    .help(mainText("openHelp")).disabled(store.isBusy)
            }
            ToolbarItem(id: "create", placement: .automatic) {
                Button { showCreate = true } label: { Label(workflowText("Create Repository"), systemImage: "plus") }
                    .help(workflowText("Create Repository")).disabled(store.isBusy)
            }
            ToolbarItem(id: "refresh", placement: .automatic) {
                Button { Task { await store.refresh() } } label: { Label(mainText("refresh"), systemImage: "arrow.clockwise") }
                    .help(mainText("refreshHelp")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "repositoryTitle", placement: .automatic) {
                Text(store.repositoryURL?.lastPathComponent ?? "RayGit")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .customizationBehavior(.disabled)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(id: "verticalSeparator") {
                Divider().frame(height: 18)
                    .help(mainText("toolbarSeparator"))
            }
            .defaultCustomization(.hidden)
            ToolbarItem(id: "tools") {
                Menu {
                    Button { showTags = true } label: { Label(workflowText("Tag Management"), systemImage: "tag") }
                    Button { showNetwork = true } label: { Label(workflowText("Network"), systemImage: "network") }
                    Button { showTools = true } label: { Label(workflowText("Repository Tools"), systemImage: "wrench.and.screwdriver") }
                } label: { Label(workflowText("Repository Tools"), systemImage: "wrench.and.screwdriver") }
                    .help(workflowText("Repository Tools")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "fetch") {
                Button { store.operation("Fetch") { try await $0.fetch() } } label: { Label(mainText("fetch"), systemImage: "arrow.down.to.line") }
                    .help(mainText("fetch")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "pull") {
                Button { confirm(mainText("pullTitle"), mainText("pullMessage")) { store.operation("Pull") { try await $0.pull() } } } label: { Label(mainText("pull"), systemImage: "arrow.down.circle") }
                    .help(mainText("pull")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "push") {
                Button { confirm(mainText("pushTitle"), mainText("pushMessage")) { store.operation("Push") { try await $0.push() } } } label: { Label(mainText("push"), systemImage: "arrow.up.circle") }
                    .help(mainText("push")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "commit") {
                Button { store.mode = "workspace"; commitFocused = true } label: { Label(mainText("commit"), systemImage: "checkmark.square") }
                    .help(mainText("commit")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "stash") {
                Button { confirm(mainText("stashTitle"), mainText("stashMessage")) { store.operation("贮藏") { try await $0.stash(message: "RayGit stash") } } } label: { Label(mainText("stash"), systemImage: "archivebox") }
                    .help(mainText("stash")).disabled(store.repository == nil || store.isBusy || store.files.isEmpty)
            }
            ToolbarItem(id: "newBranch") {
                Button { askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } } } label: { Label(mainText("newBranch"), systemImage: "arrow.triangle.branch") }
                    .help(mainText("newBranch")).disabled(store.repository == nil || store.isBusy)
            }
            ToolbarItem(id: "language") {
                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button { languageCode = language.rawValue } label: {
                            HStack {
                                Text(language.rawValue == "system" ? mainText("systemLanguage") : language.nativeName)
                                if languageCode == language.rawValue { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: { Label(mainText("language"), systemImage: "globe") }.labelStyle(.iconOnly).help(mainText("language"))
            }

        }
    }
    private var observedContent: some View {
        toolbarContent.onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { event in
            if let url = event.object as? URL, url == store.repositoryURL { Task { await store.refresh() } }
        }
        .onChange(of: preferenceFilterCase) { _, _ in store.objectWillChange.send() }
        .onChange(of: store.amend) { _, value in fillAmendMessage(value) }
        .onChange(of: store.selectedPaths) { _, _ in guard !store.isRestoringViewState else { return }; if let file = store.selectedFile { store.stagedDiff = file.isStaged && !file.isUnstaged }; Task { await store.loadDiff() } }
        .onChange(of: store.stagedDiff) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.ignoreWhitespace) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.mode) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.selectedCommit) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadCommitFiles() } }
        .onChange(of: store.selectedCommitPath) { _, _ in guard !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.historySearch) { _, _ in guard !store.isRestoringViewState else { return }; store.scheduleSearch() }
        .onChange(of: store.historyAuthor) { _, _ in guard !store.isRestoringViewState else { return }; store.scheduleSearch() }
        .onChange(of: store.repositoryURL) { _, directory in
            if let directory, terminals.visible { terminals.show(for: directory, store: store) }
            else if directory == nil { terminals.hide() }
        }
        .onChange(of: store.openRepositories) { _, paths in terminals.retainRepositories(paths) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refreshIfChanged() } } }
    }
    var body: some View {
        observedContent.alert(item: $confirmation) { action in Alert(title: Text(action.title), message: Text(action.message), primaryButton: .default(Text(mainText("continue")), action: action.action), secondaryButton: .cancel(Text(mainText("cancel")))) }
        .sheet(item: $namePrompt) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Text(prompt.title).font(.headline)
                TextField(interactionText("Name"), text: $promptValue).textFieldStyle(.roundedBorder).onSubmit { submitName(prompt) }
                HStack { Spacer(); Button(mainText("cancel")) { namePrompt = nil }; Button(mainText("continue")) { submitName(prompt) }.buttonStyle(.borderedProminent).disabled(promptValue.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(20).frame(width: 420)
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
        .sheet(item: $mergeAction) { prompt in
            VStack(alignment: .leading, spacing: 16) {
                Text(interactionText(prompt.action == .cherryPick ? "Cherry-Pick Commit" : "Revert Commit")).font(.headline)
                Text(prompt.commit.subject).lineLimit(3)
                Text(L10n.text("explanation", table: "MergeActions")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("parent", table: "MergeActions"), selection: $mainlineParent) {
                    ForEach(Array(prompt.commit.parents.enumerated()), id: \.offset) { index, hash in
                        Text(L10n.text("parentChoice", table: "MergeActions", arguments: [index + 1, String(hash.prefix(12))])).tag(index + 1)
                    }
                }
                HStack {
                    Spacer()
                    Button(mainText("cancel")) { mergeAction = nil }
                    Button(mainText("continue")) {
                        guard store.repositoryURL == prompt.repositoryURL, !store.isBusy, prompt.commit.parents.indices.contains(mainlineParent - 1) else { mergeAction = nil; return }
                        let selected = mainlineParent
                        mergeAction = nil
                        store.operation(interactionText(prompt.action == .cherryPick ? "Cherry-Pick Commit" : "Revert Commit")) { repository in
                            if prompt.action == .cherryPick { try await repository.cherryPick(hash: prompt.commit.hash, mainline: selected) }
                            else { try await repository.revert(hash: prompt.commit.hash, mainline: selected) }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(width: 520)
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
            HStack(spacing: 12) {
                Picker(mainText("view"), selection: $store.mode) { Text(mainText("workspaceCount", store.files.count)).tag("workspace"); Text(mainText("history")).tag("history") }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(mainText("view")).fixedSize(horizontal: true, vertical: false).controlSize(.small)
                Spacer()
                Text(store.repositoryURL?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if store.historyPath != nil || store.historyRef != nil {
                HStack { Label(store.historyPath ?? store.historyRef ?? "", systemImage: "line.3.horizontal.decrease.circle").lineLimit(1); Spacer(); Button(interactionText("Show All History")) { store.showHistory(path: nil, ref: nil) } }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if store.mode == "workspace" {
                WorkspacePaneSplit(
                    compact: terminals.visible,
                    files: filesPane,
                    diff: diffPane,
                    footer: HSplitView {
                        historyPane(compact: true).frame(minWidth: 300)
                        commitPane.frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
                    }
                ).frame(minHeight: terminals.visible ? 422 : 432, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)

            } else {
                VSplitView {
                    historyPane(compact: false).frame(minHeight: terminals.visible ? 160 : 230, idealHeight: terminals.visible ? 220 : 360)
                    HSplitView {
                        List(selection: $store.selectedCommitPath) {
                            Section(mainText("changedFiles", store.commitFiles.count)) {
                                ForEach(store.commitFiles) { file in HStack(spacing: 7) { Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(statusColor(file.status)); Text(file.path).font(.system(size: 12)).lineLimit(2) }.tag(file.path) }
                            }
                        }.contextMenu(forSelectionType: String.self) { paths in
                            if let path = paths.first { Button(interactionText("Show Changes")) { compareCommitFile(path) }; Button(interactionText("Copy Relative Path")) { copyText(path) } }
                        } primaryAction: { paths in if let path = paths.first { compareCommitFile(path) } }
                        .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
                        diffPane.frame(minWidth: 360, minHeight: terminals.visible ? 160 : 210)
                    }
                }
            }
        }
    }
    var filesPane: some View {
        WorkspaceFilesPane(files: store.files, selection: $store.selectedPaths, filter: $store.fileFilter, treeMode: $fileTree, isBusy: store.isBusy, onAction: fileAction, treeContent: workspaceTreeContent)
    }
    private var workspaceTreeContent: some View {
        Group {
            if let repository = store.repository {
                WorkspaceTree(repository: repository, openFile: { path in
                    ComparePresenter.show(title: path, repository: repository, target: .worktree(path: path, untracked: store.files.first(where: { $0.path == path })?.isUntracked ?? false))
                }, primaryAction: { path in
                    guard !store.isBusy else { return }
                    if RayGitPreferences.doubleClick == "stage", let file = store.files.first(where: { $0.path == path }), !file.isConflict {
                        fileAction(file.isUnstaged ? .stage : .unstage, [path])
                    } else { fileAction(.compare, [path]) }
                }, isBusy: store.isBusy, setBusy: { store.isBusy = $0 })
                .id(repository.url.path + store.filesGeneration.uuidString)
            }
        }
    }
    var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if store.mode == "workspace" { Picker(mainText("diffScope"), selection: $store.stagedDiff) { Text(mainText("workspace")).tag(false); Text(mainText("staged")).tag(true) }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(mainText("diffScope")).fixedSize(horizontal: true, vertical: false) }
                Spacer()
                if store.mode == "workspace", store.selectedPaths.count == 1 { Button(compareText("Edit / Three-way Compare")) { fileAction(.compare, store.selectedPaths) }.disabled(store.isBusy) }
                Toggle(mainText("ignoreWhitespace"), isOn: $store.ignoreWhitespace).toggleStyle(.checkbox).font(.caption)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            DiffPane(text: store.diffText, title: store.diffTitle, isLoading: store.loadingDiff)
        }
    }
    var commitPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if terminals.visible {
                ScrollView(.vertical) { commitForm }
            } else { commitForm }
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(mainText("commitNote"))
                    .accessibilityLabel(mainText("commitNote"))
                Spacer()
                Button {
                    if store.amend { confirm(mainText("amend"), mainText("amendMessage")) { store.commit() } }
                    else { store.commit() }
                } label: { Text(store.amend ? mainText("amendCommit") : mainText("commitStaged")) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!store.amend && store.stagedCount == 0) || store.files.contains(where: \.isConflict))
            }
        }.controlSize(.small).padding(12)
    }
    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(mainText("commit"), systemImage: "checkmark.circle").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(mainText("stagedCount", store.stagedCount)).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $store.commitMessage)
                .focused($commitFocused).font(.system(size: 13))
                .scrollContentBackground(.hidden).padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if store.commitMessage.isEmpty {
                        Text(mainText("commitPlaceholder")).foregroundStyle(.tertiary).font(.system(size: 13))
                            .padding(9).allowsHitTesting(false)
                    }
                }.frame(minHeight: 68)
            HStack(spacing: 8) {
                Toggle(mainText("amend"), isOn: $store.amend).toggleStyle(.checkbox).font(.caption)
                Spacer(minLength: 0)
                Menu {
                    Button("Signed-off-by", action: addSignoff)
                    Button(workflowText("commitTemplate"), action: loadTemplate)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(workflowText("commitTemplate"))
                    .disabled(store.isBusy)
            }
            if store.amend { Text(mainText("amendWarning")).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func jumpToCommit(_ value: String) {
        guard let repo = store.repository, !value.isEmpty else { return }
        Task { do { let hash = try await repo.workflowRevision(value); if let commit = try await repo.log(limit: 1, ref: hash).first, store.repositoryURL == repo.url { CommitDetailPresenter.show(commit: commit, repository: repo) } } catch { store.report(error) } }
    }
    private func fillAmendMessage(_ value: Bool) {
        guard value, !store.isRestoringViewState, store.commitMessage.isEmpty, let repo = store.repository else { return }
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
    private func historyPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if compact { HStack { Text(interactionText("Log")).font(.system(size: 12, weight: .semibold)); HistorySearchControl(search: $store.historySearch).frame(maxWidth: .infinity); Button { store.mode = "history" } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(interactionText("Expand History")) }.padding(.horizontal, 12).frame(height: 32).background(.bar) }
            HistoryPane(commits: store.commits, selection: $store.selectedCommit, search: $store.historySearch, isLoading: store.loadingHistory, hasMore: store.hasMore, onLoadMore: { Task { await store.loadHistory(reset: false) } }, isBusy: store.isBusy, onAction: historyAction, compact: compact, showsSearch: !compact, onJump: jumpToCommit, authorFilter: $store.historyAuthor)
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
        if (action == .cherryPick || action == .revert) && commit.parents.count > 1 {
            mainlineParent = 1
            mergeAction = MergeActionPrompt(action: action, commit: commit, repositoryURL: repository.url)
            return
        }
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

/// Own this split directly so SwiftUI's equal distribution cannot overwrite its dividers.
private struct WorkspacePaneSplit<Files: View, Diff: View, Footer: View>: NSViewRepresentable {
    let compact: Bool
    let files: Files
    let diff: Diff
    let footer: Footer

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WorkspaceSplitView {
        let split = WorkspaceSplitView(compact: compact)
        context.coordinator.hosts.forEach { split.addArrangedSubview($0) }
        return split
    }
    func updateNSView(_ split: WorkspaceSplitView, context: Context) {
        context.coordinator.update(self)
        split.compact = compact
    }
    final class Coordinator {
        let fileHost: NSHostingView<AnyView>
        let diffHost: NSHostingView<AnyView>
        let footerHost: NSHostingView<AnyView>
        var hosts: [NSView] { [fileHost, diffHost, footerHost] }
        init(_ model: WorkspacePaneSplit) {
            fileHost = NSHostingView(rootView: AnyView(model.files.controlSize(.small)))
            diffHost = NSHostingView(rootView: AnyView(model.diff.controlSize(.small)))
            footerHost = NSHostingView(rootView: AnyView(model.footer.controlSize(.small)))
            // Pane sizes belong to the split; SwiftUI content may expand inside each one.
            fileHost.sizingOptions = []; diffHost.sizingOptions = []; footerHost.sizingOptions = []
        }
        func update(_ model: WorkspacePaneSplit) {
            fileHost.rootView = AnyView(model.files.controlSize(.small))
            diffHost.rootView = AnyView(model.diff.controlSize(.small))
            footerHost.rootView = AnyView(model.footer.controlSize(.small))
        }
    }
}

private final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    var compact: Bool {
        didSet { if compact != oldValue, initialized { distribute(fileHeight: subviews[0].frame.height, footerHeight: subviews[2].frame.height) } }
    }
    private var initialized = false
    private var fileMinimum: CGFloat { compact ? 100 : 120 }
    private var diffMinimum: CGFloat { compact ? 160 : 150 }
    private let footerMinimum: CGFloat = 160
    override var isFlipped: Bool { true }

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if !initialized { initializeDistribution() }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 3 else { return }
        if !initialized { initializeDistribution() }
        else { distribute(fileHeight: subviews[0].frame.height, footerHeight: subviews[2].frame.height) }
    }
    private func initializeDistribution() {
        guard subviews.count == 3, bounds.height >= fileMinimum + diffMinimum + footerMinimum + 2 * dividerThickness else { return }
        initialized = true
        distribute(fileHeight: compact ? 100 : 150, footerHeight: compact ? 160 : 180)
    }
    private func distribute(fileHeight: CGFloat, footerHeight: CGFloat) {
        guard subviews.count == 3 else { return }
        let available = max(0, bounds.height - 2 * dividerThickness)
        var file = max(fileMinimum, fileHeight)
        var footer = max(footerMinimum, footerHeight)
        var overflow = max(0, file + footer + diffMinimum - available)
        let fileReduction = min(overflow, file - fileMinimum)
        file -= fileReduction; overflow -= fileReduction
        footer -= min(overflow, footer - footerMinimum)
        let diff = max(0, available - file - footer)
        let heights = [file, diff, footer]
        var y: CGFloat = 0
        for (view, height) in zip(subviews, heights) {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            view.needsLayout = true
            y += height + dividerThickness
        }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? fileMinimum : subviews[0].frame.maxY + dividerThickness + diffMinimum
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? subviews[2].frame.minY - dividerThickness - diffMinimum : bounds.height - dividerThickness - footerMinimum
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// Remove SwiftUI's expanding default title; the title is a normal toolbar item.
private struct ToolbarWindowTitleRemoval: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
