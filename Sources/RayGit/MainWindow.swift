import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

struct MainWindow: View {
    @ObservedObject var store: RepositoryStore
    var usesBorderlessToolbar = false
    var shellToolbarModel: BorderlessToolbarModel? = nil
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
    @State private var showWorkspaceSearch = false
    @State private var showAISettings = false
    @StateObject private var aiCommit = AICommitController()
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
    @Environment(\.colorScheme) private var toolbarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: () -> Void
    }
    private var windowContent: some View {
        VStack(spacing: 0) {
            if usesBorderlessToolbar, let model = shellToolbarModel {
                BorderlessToolbarView(model: model, commands: shellCommands) { command, text in
                    shellCommandControl(command, showsText: text)
                }
            }
            VSplitView {
                HSplitView {
                    sidebar.frame(minWidth: 190, idealWidth: 225, maxWidth: 245)
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
                Button { showActivity = true } label: {
                    Text(store.error ?? store.status).lineLimit(1)
                }.buttonStyle(.plain).help(refinementText("Open operation log"))
                Spacer()
                if !store.branch.isEmpty { Label(store.branch, systemImage: "arrow.triangle.branch").font(.system(size: 11, weight: .medium)) }
                Button { terminals.toggle(for: store.repositoryURL, store: store) } label: { Image(systemName: "terminal").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(terminalText("toggle")).accessibilityLabel(terminalText("toggle")).disabled(store.repository == nil)
                Button { showActivity = true } label: { Image(systemName: "list.bullet.rectangle").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(mainText("activity"))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30).rayGitChrome()
        }
        .background(RayGitStyle.canvas)
        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6))
        .frame(minHeight: terminals.visible ? 750 : 680)
        .navigationTitle(store.repositoryURL?.lastPathComponent ?? "RayGit")
        .background(TerminalShortcutMonitor { terminals.toggle(for: store.repositoryURL, store: store) }.frame(width: 0, height: 0))
        .background {
            Button {
                if let stash = store.stashes.first { sidebarAction(.stashApply, stash.ref) }
            } label: { Text(interactionText("Apply Stash…")) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.repository == nil || store.isBusy || store.stashes.isEmpty)
                .hidden().frame(width: 0, height: 0)
        }
    }
    private var toolbarContent: some View {
        // Recreate localized descendants without recreating MainWindow's session owner.
        windowContent.id(languageCode)
            .background(TitlebarToolbarSupport(shellContent: { model in NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: model)) }, hidesNativeToolbar: usesBorderlessToolbar, shellWindowTitle: usesBorderlessToolbar ? (store.repositoryURL?.lastPathComponent ?? "RayGit") : nil).frame(width: 0, height: 0))
            .modifier(ToolbarWindowTitleRemoval())
            // Version the customization identity: the old AppKit-injected identifiers
            // cannot be restored into SwiftUI's item storage. Keep other preferences intact.
            .toolbar(id: "RayGit.mainToolbar.design.v7") {
                ToolbarItem(id: "pull") {
                    Button { performToolbarCommand("pull") } label: { toolbarLabel(mainText("pull"), systemImage: "arrow.down.to.line") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("pull")).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "push") {
                    Button { performToolbarCommand("push") } label: { toolbarLabel(mainText("push"), systemImage: "arrow.up.to.line") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("push")).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(id: "stage") {
                    Button { performToolbarCommand("stage") } label: { toolbarLabel(mainText("stage"), systemImage: "plus.circle") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Stage selected files, or all eligible files when none are selected")).disabled(!toolbarCanStage)
                }.compactMainToolbarItem()
                ToolbarItem(id: "unstage") {
                    Button { performToolbarCommand("unstage") } label: { toolbarLabel(mainText("unstage"), systemImage: "minus.circle") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Unstage selected files, or all eligible files when none are selected")).disabled(!toolbarCanUnstage)
                }.compactMainToolbarItem()
                ToolbarItem(id: "discard") {
                    Button { performToolbarCommand("discard") } label: { toolbarLabel(refinementText("Discard"), systemImage: "arrow.uturn.backward") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Discard selected tracked changes, or all eligible tracked changes when none are selected")).disabled(!toolbarCanDiscard)
                }.compactMainToolbarItem()
                ToolbarItem(id: "stash") {
                    Button { performToolbarCommand("stash") } label: { toolbarLabel(mainText("stash"), systemImage: "archivebox") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("stash")).disabled(store.repository == nil || store.isBusy || store.files.isEmpty)
                }.compactMainToolbarItem()
                ToolbarItem(id: "applyStash") {
                    Menu {
                        ForEach(store.stashes) { stash in
                            Button(stashMenuTitle(stash)) { sidebarAction(.stashApply, stash.ref) }
                        }
                    } label: { toolbarLabel(refinementText("Apply"), systemImage: "archivebox.fill") } primaryAction: {
                        if let stash = store.stashes.first { sidebarAction(.stashApply, stash.ref) }
                    }
                    .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(interactionText("Apply Stash…"))
                    .disabled(store.repository == nil || store.isBusy || store.stashes.isEmpty)
                }.compactMainToolbarItem()
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(id: "refresh") {
                    Button { performToolbarCommand("refresh") } label: { toolbarLabel(mainText("refresh"), systemImage: "arrow.clockwise") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("refreshHelp")).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "create") {
                    Button { performToolbarCommand("create") } label: { toolbarLabel(refinementText("Create"), systemImage: "folder.badge.plus") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(workflowText("Create Repository")).disabled(store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "open") {
                    Button { store.chooseRepository() } label: { toolbarLabel(mainText("open"), systemImage: "folder.badge.plus") }
                        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("openHelp")).disabled(store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "fetch") {
                    Button { store.operation("Fetch") { try await $0.fetch() } } label: { toolbarLabel(mainText("fetch"), systemImage: "arrow.down.to.line") }
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "commit") {
                    Button { store.mode = "workspace"; commitFocused = true } label: { toolbarLabel(mainText("commit"), systemImage: "checkmark.square") }
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "newBranch") {
                    Button { askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } } } label: { toolbarLabel(mainText("newBranch"), systemImage: "arrow.triangle.branch") }
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "network") {
                    Button { showNetwork = true } label: { toolbarLabel(workflowText("Network"), systemImage: "point.3.connected.trianglepath.dotted") }
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "tags") {
                    Button { showTags = true } label: { toolbarLabel(workflowText("Tag Management"), systemImage: "tag") }
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "search") {
                    Button { showWorkspaceSearch = true } label: { toolbarLabel(designWorkspaceText("Search files, commits, branches…"), systemImage: "magnifyingglass") }
                        .keyboardShortcut("k").disabled(store.repository == nil)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "tools") {
                    Menu {
                        Button(workflowText("Repository Tools")) { showTools = true }
                        Button(workflowText("Network")) { showNetwork = true }
                        Button(workflowText("Tag Management")) { showTags = true }
                        Button(designWorkspaceText("Search files, commits, branches…")) { showWorkspaceSearch = true }
                        Divider()
                        Button(mainText("open")) { store.chooseRepository() }
                        ForEach(store.recentPaths, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) { Task { await store.open(URL(fileURLWithPath: path)) } }
                        }
                        Divider()
                        Button(aiCommitText("Settings")) { showAISettings = true }
                    } label: { toolbarLabel(refinementText("More"), systemImage: "ellipsis").frame(minHeight: 24).contentShape(Rectangle()) }
                        .menuIndicator(.hidden).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("More")).disabled(store.isBusy)
                }.compactMainToolbarItem()
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
                } label: { toolbarLabel(mainText("language"), systemImage: "globe") }.controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("language"))
            }.compactMainToolbarItem().defaultCustomization(.hidden)

            }
    }
    private func refinementText(_ key: String) -> String { L10n.text(key, table: "MainRefinement") }
    private var shellCommands: [ShellToolbarCommand] {
        let values: [(String, String, String, Bool)] = [
            ("pull", mainText("pull"), "arrow.down.to.line", toolbarReady),
            ("push", mainText("push"), "arrow.up.to.line", toolbarReady),
            ("stage", mainText("stage"), "plus.circle", toolbarCanStage),
            ("unstage", mainText("unstage"), "minus.circle", toolbarCanUnstage),
            ("discard", refinementText("Discard"), "arrow.uturn.backward", toolbarCanDiscard),
            ("stash", mainText("stash"), "archivebox", toolbarReady && !store.files.isEmpty),
            ("applyStash", refinementText("Apply"), "archivebox.fill", toolbarReady && !store.stashes.isEmpty),
            ("refresh", mainText("refresh"), "arrow.clockwise", toolbarReady),
            ("create", refinementText("Create"), "folder.badge.plus", !store.isBusy),
            ("tools", refinementText("More"), "ellipsis", !store.isBusy),
            ("open", mainText("open"), "folder.badge.plus", !store.isBusy),
            ("fetch", mainText("fetch"), "arrow.down.to.line", toolbarReady),
            ("commit", mainText("commit"), "checkmark.square", toolbarReady),
            ("newBranch", mainText("newBranch"), "arrow.triangle.branch", toolbarReady),
            ("network", workflowText("Network"), "point.3.connected.trianglepath.dotted", toolbarReady),
            ("tags", workflowText("Tag Management"), "tag", toolbarReady),
            ("search", designWorkspaceText("Search files, commits, branches…"), "magnifyingglass", store.repository != nil),
            ("language", mainText("language"), "globe", true)
        ]
        return values.map { id, title, symbol, enabled in ShellToolbarCommand(id: id, title: title, symbol: symbol, enabled: enabled, action: { performToolbarCommand(id) }) }
    }
    @ViewBuilder private func shellCommandControl(_ command: ShellToolbarCommand, showsText: Bool) -> some View {
        if command.id == "applyStash" {
            Menu { ForEach(store.stashes) { stash in Button(stashMenuTitle(stash)) { sidebarAction(.stashApply, stash.ref) } } }
                label: { shellCommandLabel(command, showsText: showsText) }
                primaryAction: { command.action() }
        } else if command.id == "tools" {
            Menu {
                Button(workflowText("Repository Tools")) { showTools = true }
                Button(workflowText("Network")) { showNetwork = true }
                Button(workflowText("Tag Management")) { showTags = true }
                Button(designWorkspaceText("Search files, commits, branches…")) { showWorkspaceSearch = true }
                Divider()
                Button(mainText("open")) { store.chooseRepository() }
                ForEach(store.recentPaths, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { Task { await store.open(URL(fileURLWithPath: path)) } } }
                Divider()
                Button(aiCommitText("Settings")) { showAISettings = true }
            } label: { shellCommandLabel(command, showsText: showsText) }
                .menuIndicator(.hidden)
        } else if command.id == "language" {
            Menu { ForEach(AppLanguage.allCases) { language in Button(language.nativeName) { languageCode = language.rawValue } } }
                label: { shellCommandLabel(command, showsText: showsText) }
        } else { Button(action: command.action) { shellCommandLabel(command, showsText: showsText) }.buttonStyle(.plain).accessibilityLabel(command.title) }
    }
    private func shellCommandLabel(_ command: ShellToolbarCommand, showsText: Bool) -> some View {
        HStack(spacing: 3) {
            Image(nsImage: RepositoryOperationIcon.toolbarImage(symbol: command.symbol, colorScheme: toolbarColorScheme)).frame(width: 24, height: 23).accessibilityHidden(true)
            if showsText { Text(command.title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
        }.frame(minWidth: 32).frame(width: showsText ? nil : 32, height: 28).contentShape(Rectangle())
    }
    private func performToolbarCommand(_ id: String) {
        switch id {
        case "pull": confirm(mainText("pullTitle"), mainText("pullMessage")) { store.operation("Pull") { try await $0.pull() } }
        case "push": confirm(mainText("pushTitle"), mainText("pushMessage")) { store.operation("Push") { try await $0.push() } }
        case "stage": fileAction(.stage, store.selectedPaths)
        case "unstage": fileAction(.unstage, store.selectedPaths)
        case "discard": fileAction(.discard, store.selectedPaths)
        case "stash": confirm(mainText("stashTitle"), mainText("stashMessage")) { store.operation("贮藏") { try await $0.stash(message: "RayGit stash") } }
        case "applyStash": if let stash = store.stashes.first { sidebarAction(.stashApply, stash.ref) }
        case "refresh": Task { await store.refresh() }
        case "create": showCreate = true
        case "open": store.chooseRepository()
        case "fetch": store.operation("Fetch") { try await $0.fetch() }
        case "commit": store.mode = "workspace"; commitFocused = true
        case "newBranch": askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } }
        case "network": showNetwork = true
        case "tags": showTags = true
        case "search": showWorkspaceSearch = true
        default: break
        }
    }
    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        Label { Text(title) } icon: { Image(nsImage: RepositoryOperationIcon.toolbarImage(symbol: systemImage, colorScheme: toolbarColorScheme)) }
            .font(.system(size: 11, weight: .medium))
    }
    private func stashMenuTitle(_ stash: GitStash) -> String {
        let value = stash.ref + " · " + stash.subject.replacingOccurrences(of: "\n", with: " ")
        return value.count > 65 ? String(value.prefix(64)) + "…" : value
    }
    private func toolbarTargets(_ action: FileAction) -> Set<String> {
        WorkspaceFileActionTargets.paths(for: action, files: store.files, selection: store.selectedPaths)
    }
    private var toolbarReady: Bool { store.repository != nil && !store.isBusy }
    private var toolbarCanStage: Bool { toolbarReady && !toolbarTargets(.stage).isEmpty }
    private var toolbarCanUnstage: Bool { toolbarReady && !toolbarTargets(.unstage).isEmpty }
    private var toolbarCanDiscard: Bool { toolbarReady && !toolbarTargets(.discard).isEmpty }
    private var handlesStoreEvents: Bool { usesBorderlessToolbar || !EightPointWindowShell.usesBorderlessMode }

    private var observedContent: some View {
        toolbarContent.onReceive(NotificationCenter.default.publisher(for: .rayGitWorktreeChanged)) { event in
            guard handlesStoreEvents else { return }
            if let url = event.object as? URL, url == store.repositoryURL { Task { await store.refresh() } }
        }
        .onChange(of: preferenceFilterCase) { _, _ in if handlesStoreEvents { store.objectWillChange.send() } }
        .onChange(of: store.amend) { _, value in if handlesStoreEvents { fillAmendMessage(value) } }
        .onChange(of: store.selectedPaths) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; if let file = store.selectedFile { store.stagedDiff = file.isStaged && !file.isUnstaged }; Task { await store.loadDiff() } }
        .onChange(of: store.stagedDiff) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.ignoreWhitespace) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.mode) { _, mode in
            guard handlesStoreEvents, !store.isRestoringViewState else { return }
            if mode == "history" {
                if let repo = store.repository { LogPresenter.show(repository: repo, search: store.historySearch, selectedCommit: store.selectedCommit, applyFilter: true) }
                store.mode = "workspace"
            }
            Task { await store.loadDiff() }
        }
        .onChange(of: store.selectedCommit) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; Task { await store.loadCommitFiles() } }
        .onChange(of: store.selectedCommitPath) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; Task { await store.loadDiff() } }
        .onChange(of: store.historySearch) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; store.scheduleSearch() }
        .onChange(of: store.historyAuthor) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; store.scheduleSearch() }
        .onChange(of: store.repositoryURL) { _, directory in
            guard handlesStoreEvents else { return }
            aiCommit.cancel()
            if let directory, terminals.visible { terminals.show(for: directory, store: store) }
            else if directory == nil { terminals.hide() }
        }
        .onChange(of: store.openRepositories) { _, paths in if handlesStoreEvents { terminals.retainRepositories(paths) } }
        .onChange(of: scenePhase) { _, phase in if handlesStoreEvents, phase == .active { Task { await store.refreshIfChanged() } } }
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
        .sheet(isPresented: $showWorkspaceSearch) { WorkspaceSearchSheet(store: store) }
        .sheet(isPresented: $showAISettings) { AICommitSettingsSheet() }
        .sheet(isPresented: $showTags) { TagManagementView(store: store) }
        .sheet(isPresented: $showNetwork) { NetworkOperationsView(store: store) }
        .sheet(isPresented: $showTools) { RepositoryTools(store: store) }
        .sheet(isPresented: $showCreate) { CreateRepositorySheet(store: store) }
        .sheet(isPresented: $showActivity) { OperationLogView(store: store) }
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
        WorkspacePaneSplit(
            compact: terminals.visible,
            files: filesPane,
            diff: diffPane,
            footer: HSplitView {
                historyPane(compact: true).frame(minWidth: 300)
                commitPane.frame(minWidth: 320, idealWidth: 400, maxWidth: 540)
            }
        ).frame(minHeight: terminals.visible ? 422 : 432, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
    }
    var filesPane: some View {
        WorkspaceFilesPane(files: store.files, selection: $store.selectedPaths, filter: $store.fileFilter, treeMode: $fileTree, isBusy: store.isBusy, onAction: fileAction, treeContent: { paths in workspaceTreeContent(paths) }, repository: store.repository)
    }
    private func workspaceTreeContent(_ paths: Set<String>?) -> some View {
        Group {
            if let repository = store.repository {
                WorkspaceTree(repository: repository, openFile: { path in
                    ComparePresenter.show(title: path, repository: repository, target: .worktree(path: path, untracked: store.files.first(where: { $0.path == path })?.isUntracked ?? false))
                }, visiblePaths: paths, primaryAction: { path in
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
            if let snapshot = store.conflictPreview {
                WorkspaceConflictPreview(snapshot: snapshot, onOpenEditorSearch: { options, replacement in
                    guard let repository = store.repository else { return }
                    ComparePresenter.show(title: (snapshot.path as NSString).lastPathComponent, repository: repository,
                        target: .worktree(path: snapshot.path, untracked: false), searchOptions: options, replacement: replacement)
                }, onOpenEditorLine: { pane, line in
                    guard let repository = store.repository else { return }
                    ComparePresenter.show(title: (snapshot.path as NSString).lastPathComponent, repository: repository,
                        target: .worktree(path: snapshot.path, untracked: false), initialLine: line, initialPaneID: pane)
                })
            } else {
                DiffPane(text: store.diffText, title: store.diffTitle, isLoading: store.loadingDiff, extraMenuItems: AnyView(workspaceDiffMenuItems), preview: store.staticPreview,
                    leftRevisionTitle: store.diffLeftRevisionTitle, rightRevisionTitle: store.diffRightRevisionTitle,
                    onOpenEditableComparison: editableDiffSearch)
            }
        }
    }
    private var editableDiffSearch: ((ComparisonSearchOptions, String) -> Void)? {
        guard store.mode == "workspace", let repository = store.repository, let file = store.selectedFile,
              file.worktreeStatus != "D", !store.isBusy else { return nil }
        return { options, replacement in
            ComparePresenter.show(title: (file.path as NSString).lastPathComponent, repository: repository,
                target: .worktree(path: file.path, untracked: file.isUntracked), searchOptions: options, replacement: replacement)
        }
    }
    @ViewBuilder private var workspaceDiffMenuItems: some View {
        Picker(mainText("diffScope"), selection: $store.stagedDiff) {
            Text(mainText("workspace")).tag(false)
            Text(mainText("staged")).tag(true)
        }
        if store.selectedPaths.count == 1 {
            Button(compareText("Edit / Three-way Compare")) { fileAction(.compare, store.selectedPaths) }.disabled(store.isBusy)
        }
        Toggle(mainText("ignoreWhitespace"), isOn: $store.ignoreWhitespace)
    }
    var commitPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if terminals.visible {
                ScrollView(.vertical) { commitForm }
            } else { commitForm }
            HStack {
                Toggle(mainText("amend"), isOn: $store.amend).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button {
                    if store.amend { confirm(mainText("amend"), mainText("amendMessage")) { store.commit() } }
                    else { store.commit() }
                } label: { Text(mainText("commit")) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!store.amend && store.stagedCount == 0) || store.files.contains(where: \.isConflict))
            }
        }.controlSize(.small).padding(12).background(RayGitStyle.chrome)
    }
    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(mainText("commit"), systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if aiCommit.isLoading { ProgressView().controlSize(.small); Button { aiCommit.cancel() } label: { Image(systemName: "xmark.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }.help(aiCommitText("Cancel")) }
                else {
                    Button { if AICommitConfiguration.isConfigured { aiCommit.generate(store: store) } else { showAISettings = true } } label: { Image(systemName: "sparkles").foregroundStyle(RayGitStyle.blue).frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(aiCommitText("Generate commit message")).accessibilityLabel(aiCommitText("Generate commit message"))
                        .disabled(store.isBusy || store.stagedCount == 0)
                }
                Menu {
                    Button("Signed-off-by", action: addSignoff)
                    Button(workflowText("commitTemplate")) { if let repository = store.repository { chooseTemplate(for: repository.url, configure: true) } }
                    Button(refinementText("Load configured template"), action: loadTemplate)
                } label: { Label(refinementText("More"), systemImage: "ellipsis").frame(minHeight: 24).contentShape(Rectangle()) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .help(refinementText("Commit options")).disabled(store.isBusy)
            }
            CommitMessageEditor(text: $store.commitMessage, focused: Binding(get: { commitFocused }, set: { commitFocused = $0 }), placeholder: mainText("commitPlaceholder"))
                .rayGitInputSurface().frame(minHeight: 80)
            if let error = aiCommit.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
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
            guard !path.isEmpty else { chooseTemplate(for: repo.url); return }
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : repo.url.appendingPathComponent(expanded)
            let message = try String(contentsOf: url, encoding: .utf8)
            if store.repositoryURL == repo.url { store.commitMessage = message }
        } catch let error as GitError where error.exitCode == 1 {
            if store.repositoryURL == repo.url { chooseTemplate(for: repo.url) }
        } catch { store.report(error) } }
    }
    private func chooseTemplate(for repositoryURL: URL, configure: Bool = false) {
        guard store.repositoryURL == repositoryURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = refinementText("Choose a commit message template")
        panel.begin { response in
            guard response == .OK, let url = panel.url, store.repositoryURL == repositoryURL else { return }
            do {
                let message = try String(contentsOf: url, encoding: .utf8)
                if configure {
                    store.operation(workflowText("commitTemplate")) { repository in
                        _ = try await repository.workflowRead(["config", "--local", "commit.template", url.path])
                        if store.repositoryURL == repositoryURL { store.commitMessage = message }
                    }
                } else { store.commitMessage = message }
            } catch { store.report(error) }
        }
    }
    func statusName(_ status: String) -> String { [" ": "—", "?": mainText("untracked"), "M": mainText("modified"), "A": mainText("added"), "D": mainText("deleted"), "R": mainText("renamed"), "C": mainText("copied"), "U": mainText("conflict"), "T": mainText("type") ][status] ?? status }
    func statusColor(_ status: String) -> Color { switch status { case "A", "?": return .green; case "D": return .red; case "M", "R", "U": return .orange; default: return .secondary } }
}

extension MainWindow {
    private func historyPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if compact { HStack { Label(interactionText("Log"), systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)); HistorySearchControl(search: $store.historySearch).frame(maxWidth: .infinity); HistoryDisplayMenu(); Button { if let repo = store.repository { LogPresenter.show(repository: repo) } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(interactionText("Expand History")) }.padding(.horizontal, 12).frame(height: 36).rayGitChrome() }
            HistoryPane(commits: store.commits, selection: $store.selectedCommit, search: $store.historySearch, isLoading: store.loadingHistory, hasMore: store.hasMore, onLoadMore: { Task { await store.loadHistory(reset: false) } }, isBusy: store.isBusy, onAction: historyAction, compact: compact, showsSearch: !compact, remoteBranchNames: Set(store.branches.filter(\.isRemote).map(\.name)), navigationGeneration: store.historyNavigationGeneration, onJump: jumpToCommit, authorFilter: $store.historyAuthor)
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
            let eligible = WorkspaceFileActionTargets.paths(for: .stage, files: store.files, selection: paths)
            let targets = store.files.filter { eligible.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            guard !targets.isEmpty else { return }
            store.operation("暂存") { try await $0.stage(paths: targets) }
        case .unstage, .unstageAll:
            let eligible = WorkspaceFileActionTargets.paths(for: .unstage, files: store.files, selection: paths)
            let targets = store.files.filter { eligible.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            guard !targets.isEmpty else { return }
            store.operation("取消暂存") { try await $0.unstage(paths: targets) }
        case .discard:
            let targets = WorkspaceFileActionTargets.paths(for: .discard, files: store.files, selection: paths).sorted()
            guard !targets.isEmpty else { return }
            confirm(interactionText("Discard Working Tree Changes"), interactionText("Discard Message") + "\n\n" + targets.joined(separator: "\n")) { store.operation(interactionText("Discard…")) { try await $0.discardWorktree(paths: targets) } }
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
        case .viewLog: LogPresenter.show(repository: repository, selectedCommit: commit.hash, applyFilter: true)
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
        case .stashShow: store.showStashHistory(ref: value)
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
        distribute(fileHeight: 300, footerHeight: compact ? 160 : 180)
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

/// Remove SwiftUI's expanding default title so the toolbar controls its own spaces.
private struct ToolbarWindowTitleRemoval: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private extension CustomizableToolbarContent {
    @ToolbarContentBuilder
    func compactMainToolbarItem() -> some CustomizableToolbarContent {
        if #available(macOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
