import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

struct MainWindow: View {
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @State private var historySearchFocusRequest: UUID?
    @State private var fileShortcutRequest: FilePaneShortcutRequest?
    @State private var rebaseCommit: GitCommit?
    @State private var shortcutWindow: NSWindow?
    @ObservedObject var store: RepositoryStore
    @State private var resetRequest: HistoryResetRequest?
    var usesBorderlessToolbar = false
    var shellToolbarModel: BorderlessToolbarModel? = nil
    @StateObject private var fileFocus = WorkspaceFileFocus()
    @StateObject private var historyFocus = WorkspaceFileFocus()
    @StateObject private var sidebarFocus = WorkspaceFileFocus()
    @State private var repositoryFocusRequest: UUID?
    @StateObject private var branchesFocus = WorkspaceFileFocus()
    @StateObject private var changesFocus = WorkspaceFileFocus()
    @StateObject private var terminals = TerminalSessions()
    @StateObject private var authentication = RemoteAuthenticationCoordinator()
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
    @State private var aiScopeRepository: GitRepository?
    @StateObject private var aiCommit = AICommitController()
    @State private var showActivity = false
    @State private var showTools = false
    @State private var fileTree = false
    @State private var showCreate = false
    @State private var createClone: Bool?
    @State private var blamePath: String?
    @State private var showNetwork = false
    @State private var showTags = false
    @State private var confirmation: PendingAction?
    @State private var trackingBranch: String?
    @State private var trackingRepository: GitRepository?
    @State private var selectedUpstream = ""
    @State private var pullPrompt: PullOperationPrompt?
    @State private var forcePushPrompt: ForcePushPrompt?
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
        var cancelled: (() -> Void)? = nil
        var informational = false
    }
    private var windowContent: some View {
        VStack(spacing: 0) {
            if usesBorderlessToolbar, let model = shellToolbarModel {
                BorderlessToolbarView(model: model, commands: shellCommands) { command, text in
                    shellCommandControl(command, showsText: text)
                }.background(WorkspaceFileFocusRegion(focus: fileFocus, toolbar: true).allowsHitTesting(false).accessibilityHidden(true))
            }
            VSplitView {
                HSplitView {
                    sidebar.frame(minWidth: 190, idealWidth: 225, maxWidth: 245)
                    if store.repository != nil || store.pendingRepositoryPath != nil { workspace.frame(minWidth: 640) }
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
                Text(L10n.text("stagedRatio", table: "Main", arguments: [store.stagedCount, store.files.count]))
                    .monospacedDigit().fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                Divider().frame(height: 14)
                Button { showActivity = true } label: {
                    Text(store.footerStatus).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(store.footerStatus).accessibilityLabel(refinementText("Open operation log") + ": " + store.footerStatus)
                if let fraction = store.visibleProgress?.fraction, store.isBusy {
                    ProgressView(value: fraction).frame(width: 90)
                    Text("\(Int(fraction * 100))%").monospacedDigit()
                }
                if !store.branch.isEmpty { Label(store.branch, systemImage: "arrow.triangle.branch").font(.system(size: 11, weight: .medium)).fixedSize(horizontal: true, vertical: false) }
                Button { terminals.toggle(for: store.repositoryURL, store: store) } label: { Image(systemName: "terminal").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(terminalText("toggle")).accessibilityLabel(terminalText("toggle")).disabled(store.repository == nil)
                Button { showActivity = true } label: { Image(systemName: "list.bullet.rectangle").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(mainText("activity"))
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30).rayGitChrome()
        }
        .background(RayGitStyle.canvas)
        .controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6))
        .frame(minHeight: terminals.visible ? 750 : 680)
        .navigationTitle(store.highlightedRepositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "RayGit")
        .background(TerminalShortcutMonitor { terminals.toggle(for: store.repositoryURL, store: store) }.frame(width: 0, height: 0))
        .background(WorkspaceKeyboardRegion(action: { workspaceShortcut($0) }, onWindow: { shortcutWindow = $0 }, menuAction: { workspaceShortcut($0, fromMenu: true) }).allowsHitTesting(false).accessibilityHidden(true))
    }
    private var toolbarContent: some View {
        // Recreate localized descendants without recreating MainWindow's session owner.
        windowContent.id(languageCode)
            .background(TitlebarToolbarSupport(shellContent: { model in NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: model).nativeFocusRoot()) }, hidesNativeToolbar: usesBorderlessToolbar, shellWindowTitle: usesBorderlessToolbar ? (store.highlightedRepositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "RayGit") : nil).frame(width: 0, height: 0))
            .modifier(ToolbarWindowTitleRemoval())
            // Version the customization identity: the old AppKit-injected identifiers
            // cannot be restored into SwiftUI's item storage. Keep other preferences intact.
            .toolbar(id: "RayGit.mainToolbar.design.v7") {
                ToolbarItem(id: "pull") {
                    Button { performToolbarCommand("pull") } label: { toolbarLabel(mainText("pull"), systemImage: "arrow.down.to.line") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("pull")).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "push") {
                    Button { performToolbarCommand("push") } label: { toolbarLabel(mainText("push"), systemImage: "arrow.up.to.line") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("push")).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(id: "stage") {
                    Button { performToolbarCommand("stage") } label: { toolbarLabel(mainText("stage"), systemImage: "plus.circle") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Stage selected files, or all eligible files when none are selected")).disabled(!toolbarCanStage)
                }.compactMainToolbarItem()
                ToolbarItem(id: "unstage") {
                    Button { performToolbarCommand("unstage") } label: { toolbarLabel(mainText("unstage"), systemImage: "minus.circle") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Unstage selected files, or all eligible files when none are selected")).disabled(!toolbarCanUnstage)
                }.compactMainToolbarItem()
                ToolbarItem(id: "discard") {
                    Button { performToolbarCommand("discard") } label: { toolbarLabel(refinementText("Discard"), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("Discard selected tracked changes, or all eligible tracked changes when none are selected")).disabled(!toolbarCanDiscard)
                }.compactMainToolbarItem()
                ToolbarItem(id: "stash") {
                    Button { performToolbarCommand("stash") } label: { toolbarLabel(mainText("stash"), systemImage: "archivebox") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("stash")).disabled(store.repository == nil || store.isBusy || store.files.isEmpty)
                }.compactMainToolbarItem()
                ToolbarItem(id: "applyStash") {
                    UnifiedToolbarSplitButton(title: interactionText("Apply Stash…"), action: { performToolbarCommand("applyStash") }) {
                        toolbarLabel(refinementText("Apply"), systemImage: "archivebox.fill")
                    } menu: {
                        ForEach(store.stashes) { stash in
                            Button { sidebarAction(.stashApply, stash.ref) } label: { Text(stashMenuTitle(stash)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                    .boundedMenu(width: 230)
                    .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(interactionText("Apply Stash…"))
                    .disabled(store.repository == nil || store.isBusy || store.stashes.isEmpty)
                }.compactMainToolbarItem()
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(id: "refresh") {
                    Button { performToolbarCommand("refresh") } label: { toolbarLabel(mainText("refresh"), systemImage: "arrow.clockwise") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(shortcutText(ShortcutCommand.refresh.title) + " " + shortcuts.binding(.refresh).displayString).disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "create") {
                    Button { performToolbarCommand("create") } label: { toolbarLabel(refinementText("Create"), systemImage: "folder.badge.plus") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(workflowText("Create Repository")).disabled(store.isBusy)
                }.compactMainToolbarItem()
                ToolbarItem(id: "open") {
                    Button { store.chooseRepository() } label: { toolbarLabel(mainText("open"), systemImage: "folder.badge.plus") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(shortcutText(ShortcutCommand.open.title) + " " + shortcuts.binding(.open).displayString).disabled(store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "fetch") {
                    Button { runToolbarNetwork(.fetch) } label: { toolbarLabel(mainText("fetch"), systemImage: "arrow.down.to.line") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "commit") {
                    Button { store.mode = "workspace"; commitFocused = true } label: { toolbarLabel(mainText("commit"), systemImage: "checkmark.square") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "newBranch") {
                    Button { askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } } } label: { toolbarLabel(mainText("newBranch"), systemImage: "arrow.triangle.branch") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "network") {
                    Button { showNetwork = true } label: { toolbarLabel(workflowText("Network"), systemImage: "point.3.connected.trianglepath.dotted") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "tags") {
                    Button { showTags = true } label: { toolbarLabel(workflowText("Tag Management"), systemImage: "tag") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil || store.isBusy)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "search") {
                    Button { showWorkspaceSearch = true } label: { toolbarLabel(designWorkspaceText("Search files, commits, branches…"), systemImage: "magnifyingglass") }
                        .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32))
                        .disabled(store.repository == nil)
                }.compactMainToolbarItem().defaultCustomization(.hidden)
                ToolbarItem(id: "tools") {
                    Menu {
                        Button(workflowText("Repository Tools")) { showTools = true }
                        Button(workflowText("Network")) { showNetwork = true }
                        Button(workflowText("Tag Management")) { showTags = true }
                        Button(designWorkspaceText("Search files, commits, branches…")) { showWorkspaceSearch = true }
                        Divider()
                        Button(refinementText("Open in Finder")) {
                            if let repository = store.repository { NSWorkspace.shared.open(repository.url) }
                        }.disabled(store.repository == nil)
                        Divider()
                        Button(aiCommitText("Settings")) { showAISettings = true }
                    } label: { toolbarLabel(refinementText("More"), systemImage: "ellipsis").frame(minHeight: 24).contentShape(Rectangle()) }
                        .menuIndicator(.hidden).menuStyle(.borderlessButton).frame(height: 28).buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(refinementText("More")).disabled(store.isBusy)
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
                } label: { toolbarLabel(mainText("language"), systemImage: "globe") }.menuStyle(.borderlessButton).frame(height: 28).buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).controlSize(.small).buttonBorderShape(.roundedRectangle(radius: 6)).help(mainText("language"))
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
            UnifiedToolbarSplitButton(title: interactionText("Apply Stash…"), action: command.action) {
                shellCommandLabel(command, showsText: showsText)
            } menu: {
                ForEach(store.stashes) { stash in Button { sidebarAction(.stashApply, stash.ref) } label: { Text(stashMenuTitle(stash)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) } }
            }.boundedMenu(width: 230)
        } else if command.id == "tools" {
            Menu {
                Button(workflowText("Repository Tools")) { showTools = true }
                Button(workflowText("Network")) { showNetwork = true }
                Button(workflowText("Tag Management")) { showTags = true }
                Button(designWorkspaceText("Search files, commits, branches…")) { showWorkspaceSearch = true }
                Divider()
                Button(refinementText("Open in Finder")) {
                    if let repository = store.repository { NSWorkspace.shared.open(repository.url) }
                }.disabled(store.repository == nil)
                Divider()
                Button(aiCommitText("Settings")) { showAISettings = true }
            } label: { shellCommandLabel(command, showsText: showsText) }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton).frame(height: 28)
        } else if command.id == "language" {
            Menu { ForEach(AppLanguage.allCases) { language in Button(language.nativeName) { languageCode = language.rawValue } } }
                label: { shellCommandLabel(command, showsText: showsText) }
                .menuStyle(.borderlessButton).frame(height: 28)
        } else { Button(action: command.action) { shellCommandLabel(command, showsText: showsText) }.buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).accessibilityLabel(command.title) }
    }
    private func shellCommandLabel(_ command: ShellToolbarCommand, showsText: Bool) -> some View {
        HStack(spacing: 3) {
            if command.id == "tools" {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                    .frame(width: 20, height: 23).accessibilityHidden(true)
            } else {
                Image(nsImage: RepositoryOperationIcon.toolbarImage(symbol: command.symbol, colorScheme: toolbarColorScheme))
                    .resizable().scaledToFit().frame(width: command.id == "create" ? 20 : 24, height: command.id == "create" ? 19 : 23)
                    .accessibilityHidden(true)
            }
            if showsText { Text(command.title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
        }.frame(minWidth: 32).frame(width: showsText ? nil : 32, height: 28).contentShape(Rectangle())
    }
    private func performToolbarCommand(_ id: String) {
        switch id {
        case "pull": store.checkNetworkPreflight(.pull) { hint in
            if let repository = store.repository { pullPrompt = PullOperationPrompt(repository: repository, hint: hint) }
        }
        case "push": prepareToolbarPush()
        case "stage": fileAction(.stage, toolbarSelection)
        case "unstage": fileAction(.unstage, toolbarSelection)
        case "discard": fileAction(.discard, toolbarSelection)
        case "stash": confirm(mainText("stashTitle"), mainText("stashMessage")) { store.operation("贮藏") { try await $0.stash(message: "RayGit stash") } }
        case "applyStash": if let stash = store.stashes.first { sidebarAction(.stashApply, stash.ref) }
        case "refresh": Task { await store.refresh() }
        case "create": createClone = nil; showCreate = true
        case "open": store.chooseRepository()
        case "fetch": runToolbarNetwork(.fetch)
        case "commit": store.mode = "workspace"; commitFocused = true
        case "newBranch": askName(mainText("createBranch")) { name in store.operation("创建分支") { try await $0.createBranch(name: name) } }
        case "network": showNetwork = true
        case "tags": showTags = true
        case "search": showWorkspaceSearch = true
        default: break
        }
    }
    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        Label { Text(title) } icon: { Image(nsImage: RepositoryOperationIcon.toolbarImage(symbol: systemImage, colorScheme: toolbarColorScheme)).resizable().scaledToFit().frame(width: systemImage == "folder.badge.plus" ? 20 : 24, height: systemImage == "folder.badge.plus" ? 19 : 23) }
            .font(.system(size: 11, weight: .medium)).frame(height: 28).contentShape(Rectangle())
    }
    private func stashMenuTitle(_ stash: GitStash) -> String {
        let value = stash.ref + " · " + stash.subject.replacingOccurrences(of: "\n", with: " ")
        return value.count > 65 ? String(value.prefix(64)) + "…" : value
    }
    private var toolbarSelection: Set<String> { fileFocus.hasFileFocus ? store.selectedPaths : [] }
    private func toolbarTargets(_ action: FileAction) -> Set<String> {
        WorkspaceFileActionTargets.paths(for: action, files: store.files, selection: toolbarSelection)
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
        .onReceive(NotificationCenter.default.publisher(for: .rayGitReuseCommitMessage)) { event in
            guard handlesStoreEvents, let url = event.object as? URL, let message = event.userInfo?["message"] as? String, !store.isBusy else { return }
            Task { @MainActor in
                if store.repositoryURL != url { await store.open(url) }
                guard store.repositoryURL == url, !store.isBusy else { return }
                store.commitMessage = message; shortcutWindow?.makeKeyAndOrderFront(nil); commitFocused = true
            }
        }
        .onChange(of: preferenceFilterCase) { _, _ in if handlesStoreEvents { store.objectWillChange.send() } }
        .onChange(of: store.amend) { _, value in if handlesStoreEvents { fillAmendMessage(value) } }
        .onChange(of: store.selectedPaths) { _, _ in guard handlesStoreEvents, !store.isRestoringViewState else { return }; if let file = store.selectedFile { let staged = file.isStaged && !file.isUnstaged; if store.stagedDiff != staged { store.stagedDiff = staged; return } }; Task { await store.loadDiff() } }
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
            authentication.cancel()
            aiCommit.cancel()
            store.workspaceCommitRequest = nil
            aiScopeRepository = nil
            if let directory, terminals.visible { terminals.show(for: directory, store: store) }
            else if directory == nil, store.pendingRepositoryPath == nil { terminals.hide() }
        }
        .onChange(of: store.pendingRepositoryPath) { _, path in
            if handlesStoreEvents, path == nil, store.repositoryURL == nil { terminals.hide() }
        }
        .onChange(of: store.openRepositories) { _, paths in if handlesStoreEvents { terminals.retainRepositories(paths) } }
        .onChange(of: scenePhase) { _, phase in if handlesStoreEvents, phase == .active { Task { await store.refreshIfChanged() } } }
    }
    var body: some View {
        observedContent.rayGitAlert(item: $confirmation) { action in
            RayGitAlert(title: action.title, message: action.message, buttons: action.informational ? [
                RayGitAlertButton(mainText("close")) { confirmation = nil }
            ] : [
                RayGitAlertButton(mainText("cancel"), role: .cancel) { confirmation = nil; action.cancelled?() },
                RayGitAlertButton(mainText("continue")) { confirmation = nil; action.action() }
            ])
        }
        .onDisappear { confirmation?.cancelled?(); confirmation = nil; authentication.cancel() }
        .rayGitSheet(item: $authentication.request) { request in
            RemoteAuthenticationSheet(request: request, error: authentication.submissionError, isSubmitting: authentication.isSubmitting, submit: { submission in
                authentication.submit(submission)
            }, cancel: { authentication.cancel() })
        }
        .rayGitSheet(item: $pullPrompt) { prompt in
            PullOperationConfirmation(hint: prompt.hint) { pullPrompt = nil } execute: { operation in
                pullPrompt = nil
                guard store.repository === prompt.repository, !store.isBusy else { return }
                runToolbarNetwork(operation)
            }
        }
        .rayGitSheet(item: $forcePushPrompt) { prompt in
            ForcePushConfirmation(preview: prompt.preview) { forcePushPrompt = nil } execute: {
                forcePushPrompt = nil
                guard store.repository === prompt.repository else { return }
                runToolbarForcePush(prompt)
            }
        }
        .rayGitSheet(isPresented: Binding(get: { trackingBranch != nil }, set: { if !$0 { trackingBranch = nil; trackingRepository = nil } }), onDismiss: { trackingRepository = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(sidebarRefinementText("Set Tracking Branch…")).font(.headline)
                Text(trackingBranch ?? "")
                Text(sidebarRefinementText("Remote Branch")).font(.caption).foregroundStyle(.secondary)
                Picker(sidebarRefinementText("Remote Branch"), selection: $selectedUpstream) {
                    ForEach(store.branches.filter(\.isRemote)) { branch in Text(branch.name).tag("refs/remotes/" + branch.name) }
                }.labelsHidden()
                HStack {
                    Button(workflowText("Cancel")) { trackingBranch = nil; trackingRepository = nil }.keyboardShortcut(.cancelAction)
                    Button(sidebarRefinementText("Set Tracking Branch…")) {
                        guard let branch = trackingBranch, let repository = trackingRepository, store.repository === repository else { trackingBranch = nil; trackingRepository = nil; return }
                        let upstream = selectedUpstream; trackingBranch = nil; trackingRepository = nil
                        store.operation(sidebarRefinementText("Set Tracking Branch…")) { try await $0.setUpstream(branch: branch, remoteBranch: upstream) }
                    }.keyboardShortcut(.defaultAction).disabled(selectedUpstream.isEmpty || store.isBusy)
                }.frame(maxWidth: .infinity)
            }.padding(24).frame(width: 360)
        }
        .rayGitSheet(item: $namePrompt) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Text(prompt.title).font(.headline)
                StableTextField(interactionText("Name"), text: $promptValue, onSubmit: { submitName(prompt) }).textFieldStyle(.roundedBorder)
                HStack { Button(mainText("cancel")) { namePrompt = nil }; Button(mainText("continue")) { submitName(prompt) }.buttonStyle(.borderedProminent).disabled(promptValue.trimmingCharacters(in: .whitespaces).isEmpty) }.frame(maxWidth: .infinity)
            }.padding(20).frame(width: 360)
        }
        .rayGitSheet(isPresented: $showWorkspaceSearch) { WorkspaceSearchSheet(store: store) }
        .rayGitSheet(item: $store.workspaceCommitRequest) { request in
            WorkspaceCommitSheet(store: store, request: request)
        }
        .rayGitSheet(isPresented: $showAISettings) { AICommitSettingsSheet() }
        .rayGitSheet(isPresented: Binding(get: { aiScopeRepository != nil }, set: { if !$0 { aiScopeRepository = nil } })) {
            AICommitScopeSheet { scope in
                guard let repository = aiScopeRepository, store.repository === repository else { aiScopeRepository = nil; return }
                aiScopeRepository = nil
                aiCommit.generate(store: store, scope: scope)
            }
        }
        .rayGitSheet(isPresented: $showTags) { TagManagementView(store: store) }
        .rayGitSheet(isPresented: $showNetwork) { NetworkOperationsView(store: store) }
        .rayGitSheet(isPresented: $showTools) { RepositoryTools(store: store) }
        .rayGitSheet(isPresented: $showCreate) { CreateRepositorySheet(store: store, initialClone: createClone) }
        .rayGitSheet(isPresented: Binding(get: { blamePath != nil }, set: { if !$0 { blamePath = nil } })) {
            if let repository = store.repository, let path = blamePath {
                VStack { StructuredHistoryView(repository: repository, blamePath: path, revision: "HEAD"); Button(workflowText("Close")) { blamePath = nil }.keyboardShortcut(.cancelAction) }.padding().frame(width: 1000, height: 700)
            }
        }
        .rayGitSheet(item: $resetRequest) { HistoryResetSheet(store: store, request: $0) }
        .rayGitSheet(item: $rebaseCommit) { commit in
            RebaseWorkflowView(store: store, onClose: { rebaseCommit = nil }, initialBase: commit.hash).padding(20).frame(width: 1100, height: 850)
        }
        .rayGitSheet(isPresented: $showActivity) { OperationLogView(store: store) }
        .rayGitSheet(item: $mergeAction) { prompt in
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
                }.frame(maxWidth: .infinity)
            }.padding(20).frame(width: 360)
        }
    }
    private func mainText(_ key: String, _ args: CVarArg...) -> String { L10n.text(key, table: "Main", arguments: args) }
    func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let root = store.repositoryURL
        confirmation = PendingAction(title: title, message: message) { guard store.repositoryURL == root else { return }; action() }
    }
    private func runToolbarNetwork(_ operation: NetworkOperation, credential suppliedCredential: NetworkCredential? = nil, saveCredential: Bool = false) {
        guard let repository = store.repository, !store.isBusy else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else { credential = await authentication.savedCredential(for: repository, operation: operation) }
            guard store.repository === repository, !store.isBusy else { return }
            let name = operation == .pull ? "Pull" : "Fetch"
            store.operation(name, onFailure: { error in
                Task { @MainActor in
                    _ = await authentication.presentIfNeeded(error: error, repository: repository, operation: operation) { retry in
                        runToolbarNetwork(operation, credential: retry.credential, saveCredential: retry.saveCredential)
                    }
                }
            }) { active in
                try await authentication.perform(with: credential) {
                    if operation == .pull { try await active.pull(credential: credential) }
                    else { try await active.fetch(credential: credential) }
                }
                await saveToolbarCredentialAfterSuccess(credential, requested: saveCredential, repository: active, operation: operation)
            }
        }
    }
    private func prepareToolbarPush() {
        guard let repository = store.repository, !store.isBusy else { return }
        store.checkNetworkPreflight(.push) { hint in
            let execute = { executeToolbarPush(repository) }
            if case let .pushBehind(preview) = hint { forcePushPrompt = ForcePushPrompt(repository: repository, preview: preview) }
            else if let hint { confirm(mainText("pushTitle"), networkPreflightMessage(hint), action: execute) }
            else { execute() }
        }
    }
    private func executeToolbarPush(_ repository: GitRepository, credential suppliedCredential: NetworkCredential? = nil, saveCredential: Bool = false) {
        guard store.repository === repository, !store.isBusy else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else { credential = await authentication.savedCredential(for: repository, operation: .push) }
            guard store.repository === repository, !store.isBusy else { return }
            store.operation("Push", onFailure: { error in
                if ForcePushRejection.isNonFastForward(error), store.repository === repository {
                    prepareRejectedPush(repository, credential: credential, saveCredential: saveCredential)
                } else {
                    Task { @MainActor in
                        _ = await authentication.presentIfNeeded(error: error, repository: repository, operation: .push) { retry in
                            executeToolbarPush(repository, credential: retry.credential, saveCredential: retry.saveCredential)
                        }
                    }
                }
            }) { active in
                try await authentication.perform(with: credential) {
                    if let preview = try await active.preparePush(credential: credential) {
                        await saveToolbarCredentialAfterSuccess(credential, requested: saveCredential, repository: active, operation: .push)
                        await MainActor.run {
                            if store.repository === active {
                                forcePushPrompt = ForcePushPrompt(repository: active, preview: preview,
                                                                  credential: credential, saveCredential: saveCredential)
                            }
                        }
                        throw CancellationError()
                    }
                    try await active.push(credential: credential)
                }
                await saveToolbarCredentialAfterSuccess(credential, requested: saveCredential, repository: active, operation: .push)
            }
        }
    }
    private func prepareRejectedPush(_ repository: GitRepository, credential suppliedCredential: NetworkCredential? = nil, saveCredential: Bool = false) {
        guard store.repository === repository, !store.isBusy else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else { credential = await authentication.savedCredential(for: repository, operation: .push) }
            guard store.repository === repository, !store.isBusy else { return }
            store.operation("Push preview", onFailure: { error in
                Task { @MainActor in
                    _ = await authentication.presentIfNeeded(error: error, repository: repository, operation: .push) { retry in
                        prepareRejectedPush(repository, credential: retry.credential, saveCredential: retry.saveCredential)
                    }
                }
            }) { active in
                let preview = try await authentication.perform(with: credential) { try await active.prepareForcePush(credential: credential) }
                await saveToolbarCredentialAfterSuccess(credential, requested: saveCredential, repository: active, operation: .push)
                await MainActor.run {
                    guard store.repository === active else { return }
                    forcePushPrompt = ForcePushPrompt(repository: active, preview: preview,
                                                      credential: credential, saveCredential: saveCredential)
                }
            }
        }
    }
    private func runToolbarForcePush(_ prompt: ForcePushPrompt, credential suppliedCredential: NetworkCredential? = nil, saveCredential: Bool = false) {
        guard store.repository === prompt.repository, !store.isBusy else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else if let promptCredential = prompt.credential { credential = promptCredential }
            else { credential = await authentication.savedCredential(for: prompt.repository, operation: .push) }
            let shouldSaveCredential = suppliedCredential == nil ? prompt.saveCredential : saveCredential
            guard store.repository === prompt.repository, !store.isBusy else { return }
            store.operation(forcePushText("action"), onFailure: { error in
                Task { @MainActor in
                    _ = await authentication.presentIfNeeded(error: error, repository: prompt.repository, operation: .push) { retry in
                        if retry.requiresFreshForcePushPreparation {
                            executeToolbarPush(prompt.repository, credential: retry.credential, saveCredential: retry.saveCredential)
                        } else {
                            runToolbarForcePush(prompt, credential: retry.credential, saveCredential: retry.saveCredential)
                        }
                    }
                }
            }) { active in
                _ = try await authentication.perform(with: credential) {
                    try await active.forcePush(prompt.preview, credential: credential) { _ in }
                }
                await saveToolbarCredentialAfterSuccess(credential, requested: shouldSaveCredential, repository: active, operation: .push)
            }
        }
    }
    private func saveToolbarCredentialAfterSuccess(_ credential: NetworkCredential?, requested: Bool, repository: GitRepository, operation: NetworkOperation) async {
        guard requested, let credential else { return }
        do { try await authentication.save(credential, for: repository, operation: operation) }
        catch {
            guard store.repository === repository else { return }
            store.error = OperationFailure.message(error, repository: repository.url)
        }
    }
    var sidebar: some View { RepositorySidebar(store: store, onAction: sidebarAction, repositoryFocusRequest: repositoryFocusRequest, branchFocus: branchesFocus).background(WorkspaceFileFocusRegion(focus: sidebarFocus).allowsHitTesting(false).accessibilityHidden(true)) }
    var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 58, weight: .light)).foregroundStyle(Color.accentColor)
            Text("RayGit").font(.largeTitle.bold())
            Text(mainText("welcomeSubtitle")).font(.title3).foregroundStyle(.secondary)
            Button(mainText("openLocal")) { store.chooseRepository() }.buttonStyle(.borderedProminent).controlSize(.large)
            Text([ShortcutCommand.open, .refresh].map { shortcuts.binding($0).displayString + " " + shortcutText($0.title) }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.tertiary)
        }
    }
    var workspace: some View {
        WorkspacePaneSplit(
            compact: terminals.visible,
            files: filesPane,
            diff: diffPane,
            footer: WorkspaceFooterSplit(history: historyPane(compact: true), commit: commitPane)
        ).frame(minHeight: terminals.visible ? 422 : 432, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
    }
    var filesPane: some View {
        WorkspaceFilesPane(files: store.files, automaticallySelectedPath: store.automaticallySelectedPath, initialSelectionReady: store.initialWorkspaceSelectionReady, selection: $store.selectedPaths, filter: $store.fileFilter, treeMode: $fileTree, isBusy: store.isBusy, onAction: fileAction, treeContent: { paths in workspaceTreeContent(paths) }, repository: store.repository, fileFocus: fileFocus, shortcutRequest: fileShortcutRequest)
    }
    private func workspaceTreeContent(_ paths: Set<String>?) -> some View {
        Group {
            if let repository = store.repository {
                WorkspaceTree(repository: repository, openFile: { path in
                    ComparePresenter.show(title: path, repository: repository, target: .worktree(path: path, untracked: store.files.first(where: { $0.path == path })?.isUntracked ?? false))
                }, visiblePaths: paths, selection: $store.selectedPaths, changedPaths: Set(store.files.map(\.path)), primaryAction: { path in
                    guard !store.isBusy else { return }
                    if RayGitPreferences.doubleClick == "stage", let file = store.files.first(where: { $0.path == path }), !file.isConflict {
                        fileAction(file.isUnstaged ? .stage : .unstage, [path])
                    } else { fileAction(.compare, [path]) }
                }, isBusy: store.isBusy, setBusy: { store.isBusy = $0 }, files: store.files, onAction: { action, targets in
                    guard store.repositoryURL == repository.url else { return }; fileAction(action, targets)
                })
                .id(repository.url.path + store.filesGeneration.uuidString)
            }
        }
    }
    var diffPane: some View {
        VStack(spacing: 0) {
            if let snapshot = store.conflictPreview {
                WorkspaceConflictPreview(snapshot: snapshot, onOpenEditorSearch: { options, replacement in
                    guard !store.isBusy, store.canMutateDisplayedDiff, store.selectedFile?.path == snapshot.path, let repository = store.repository else { return }
                    ComparePresenter.show(title: (snapshot.path as NSString).lastPathComponent, repository: repository,
                        target: .worktree(path: snapshot.path, untracked: false), searchOptions: options, replacement: replacement)
                }, onOpenEditorLine: { pane, line in
                    guard !store.isBusy, store.canMutateDisplayedDiff, store.selectedFile?.path == snapshot.path, let repository = store.repository else { return }
                    ComparePresenter.show(title: (snapshot.path as NSString).lastPathComponent, repository: repository,
                        target: .worktree(path: snapshot.path, untracked: false), initialLine: line, initialPaneID: pane)
                })
            } else {
                DiffPane(text: store.diffText, title: store.diffTitle, isLoading: store.loadingDiff, extraMenuItems: AnyView(workspaceDiffMenuItems), preview: store.staticPreview,
                    leftRevisionTitle: store.diffLeftRevisionTitle, rightRevisionTitle: store.diffRightRevisionTitle,
                    onOpenEditableComparison: editableDiffSearch)
            }
        }.background(WorkspaceFileFocusRegion(focus: changesFocus).allowsHitTesting(false).accessibilityHidden(true))
    }
    private var editableDiffSearch: ((ComparisonSearchOptions, String) -> Void)? {
        guard store.mode == "workspace", let repository = store.repository, let file = store.selectedFile,
              file.worktreeStatus != "D", !store.isBusy, store.canMutateDisplayedDiff else { return nil }
        return { options, replacement in
            guard !store.isBusy, store.canMutateDisplayedDiff, store.repository === repository, store.selectedFile?.path == file.path else { return }
            ComparePresenter.show(title: (file.path as NSString).lastPathComponent, repository: repository,
                target: store.usesStagedDiff(for: file) ? .staged(path: file.path) : .worktree(path: file.path, untracked: file.isUntracked), searchOptions: options, replacement: replacement)
        }
    }
    @ViewBuilder private var workspaceDiffMenuItems: some View {
        Picker(mainText("diffScope"), selection: Binding(get: { store.effectiveStagedDiff }, set: { store.stagedDiff = $0 })) {
            Text(mainText("workspace")).tag(false)
            Text(mainText("staged")).tag(true)
        }
        if store.selectedPaths.count == 1 {
            Button(compareText("Edit / Three-way Compare")) {
                guard !store.isBusy, store.canMutateDisplayedDiff else { return }
                fileAction(.compare, store.selectedPaths)
            }.disabled(store.isBusy || !store.canMutateDisplayedDiff)
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
                    .disabled(!store.canCommit)
            }
        }.controlSize(.small).padding(12).background(RayGitStyle.chrome)
    }
    private func requestAICommit() {
        guard AICommitConfiguration.isConfigured else { showAISettings = true; return }
        if let scope = AICommitScopeChoice.remembered() { aiCommit.generate(store: store, scope: scope) }
        else { aiScopeRepository = store.repository }
    }
    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(mainText("commit"), systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let error = aiCommit.error {
                    FloatingNotice(message: error,
                        guidance: aiCommit.canGenerateSummary ? aiCommitText("Increase the patch limit in AI settings, or generate from file names and change counts. Summary mode cannot describe code details.") : "",
                        command: aiCommit.canGenerateSummary ? (aiCommit.scope == .staged ? "git diff --cached --stat" : "git diff --cached --stat; git diff --stat; git ls-files --others --exclude-standard") : nil,
                        actions: aiCommit.canGenerateSummary && !aiCommit.isLoading ? [
                            (aiCommitText("Generate from summary"), { aiCommit.generate(store: store, scope: aiCommit.scope, summaryOnly: true) }),
                            (aiCommitText("Settings"), { showAISettings = true })
                        ] : [(aiCommitText("Settings"), { showAISettings = true })])
                }
                if aiCommit.isLoading { ProgressView().controlSize(.small); Button { aiCommit.cancel() } label: { Image(systemName: "xmark.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(ToolbarRowButtonStyle()).help(aiCommitText("Cancel")) }
                else {
                    Button { requestAICommit() } label: { Image(systemName: "sparkles").foregroundStyle(RayGitStyle.blue).frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(aiCommitText("Generate commit message")).accessibilityLabel(aiCommitText("Generate commit message"))
                        .disabled(store.isBusy || store.repository == nil)
                }
                Menu {
                    Button(aiCommitText("Generation scope…")) { aiScopeRepository = store.repository }
                        .disabled(store.repository == nil || aiCommit.isLoading)
                    Divider()
                    Button("Signed-off-by", action: addSignoff)
                    Menu {
                        if store.recentCommitMessages.isEmpty {
                            Text(refinementText("No recent commit messages"))
                        } else {
                            ForEach(store.recentCommitMessages, id: \.self) { message in
                                Button { store.commitMessage = message } label: {
                                    Text(recentCommitMessageTitle(message)).lineLimit(1)
                                }
                            }
                        }
                        Divider()
                        Button(refinementText("Clear commit history"), role: .destructive) {
                            store.clearRecentCommitMessages()
                        }.disabled(store.recentCommitMessages.isEmpty)
                    } label: {
                        Label(refinementText("Recent commit messages"), systemImage: "clock.arrow.circlepath")
                    }.disabled(store.repository == nil)
                } label: { Label(refinementText("More"), systemImage: "ellipsis").frame(minHeight: 24).contentShape(Rectangle()) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .help(refinementText("Commit options")).disabled(store.isBusy)
            }
            CommitMessageEditor(text: $store.commitMessage, focused: Binding(get: { commitFocused }, set: { commitFocused = $0 }), placeholder: mainText("commitPlaceholder"))
                .rayGitInputSurface().frame(minHeight: 80)

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
    private func recentCommitMessageTitle(_ message: String) -> String {
        message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? message
    }
    func statusName(_ status: String) -> String { [" ": "—", "?": mainText("untracked"), "M": mainText("modified"), "A": mainText("added"), "D": mainText("deleted"), "R": mainText("renamed"), "C": mainText("copied"), "U": mainText("conflict"), "T": mainText("type") ][status] ?? status }
    func statusColor(_ status: String) -> Color { switch status { case "?": return .blue; case "A": return .green; case "D": return .red; case "M", "R", "U": return .orange; default: return .secondary } }
}

extension MainWindow {
    private func historyPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if compact { HStack { Label(interactionText("Log"), systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)); HistorySearchControl(search: $store.historySearch, focusRequest: historySearchFocusRequest).frame(maxWidth: .infinity); HistoryDisplayMenu(showMergedCommits: Binding(get: { store.showMergedCommits }, set: { store.setShowMergedCommits($0) })); Button { if let repo = store.repository { LogPresenter.show(repository: repo) } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(interactionText("Expand History")) }.padding(.horizontal, 12).frame(height: 36).rayGitChrome() }
            HistoryPane(commits: store.commits, selection: $store.selectedCommit, search: $store.historySearch, isLoading: store.loadingHistory, hasMore: store.hasMore, onLoadMore: { Task { await store.loadHistory(reset: false) } }, isBusy: store.isBusy, onAction: historyAction, onShowChanges: { if let path = store.selectedCommitPath { compareCommitFile(path) } }, compact: compact, showsSearch: !compact, remoteBranchNames: Set(store.branches.filter(\.isRemote).map(\.name)), localUnpushedCommitHashes: store.localUnpushedCommitHashes, navigationGeneration: store.historyNavigationGeneration, onJump: jumpToCommit, firstParentGraph: store.followsCurrentBranch && !store.showMergedCommits, onFind: { historySearchFocusRequest = UUID() }, authorFilter: $store.historyAuthor)
                .background(WorkspaceFileFocusRegion(focus: historyFocus).allowsHitTesting(false).accessibilityHidden(true))
        }
    }
    private func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    @discardableResult private func workspaceShortcut(_ command: ShortcutCommand, fromMenu: Bool = false) -> Bool {
        guard handlesStoreEvents else { return false }
        if fromMenu, command == .stage || command == .unstage {
            performToolbarCommand(command.rawValue); return true
        }
        if historyFocus.hasFileFocus, let action = command.historyAction, let commit = store.commits.first(where: { $0.hash == store.selectedCommit }) {
            historyAction(action, commit); return true
        }
        if command.scopes.contains(.files) {
            guard fileFocus.hasFileFocus, store.repository != nil else { return false }
            if store.isBusy { return true }
            let selection = store.selectedPaths
            switch command {
            case .selectAllFiles:
                if let shortcutWindow, fileFocus.focus(in: shortcutWindow) {
                    (shortcutWindow.firstResponder as? NSTableView)?.selectAll(nil)
                }
            case .copyFiles: fileAction(.copyFiles, selection)
            case .filterFiles, .showUnversionedFiles, .showIgnoredFiles: fileShortcutRequest = FilePaneShortcutRequest(command: command)
            case .selectCommittable: store.selectedPaths = WorkspaceFileActionTargets.paths(for: .stage, files: store.files, selection: [])
            case .copyPath: fileAction(.copyPath, selection)
            case .copyRelativePath: fileAction(.copyRelativePath, selection)
            case .stage: fileAction(.stage, selection)
            case .unstage: fileAction(.unstage, selection)
            case .discard: fileAction(.discard, selection)
            case .deleteFile: fileAction(.trash, selection)
            case .renameFile: fileAction(.rename, selection)
            case .ignore: fileAction(.ignore, selection)
            case .editFile: fileAction(.open, selection)
            case .showChanges: fileAction(.compare, selection)
            case .blame:
                guard selection.count == 1, let file = store.selectedFile, !file.isUntracked else { return true }
                blamePath = file.path
            default: return false
            }
            return true
        }
        switch command {
        case .activateRepositories: repositoryFocusRequest = UUID()
        case .activateBranches: if let shortcutWindow { branchesFocus.focus(in: shortcutWindow) }
        case .activateFiles: if let shortcutWindow { fileFocus.focus(in: shortcutWindow) }
        case .activateChanges: if let shortcutWindow { changesFocus.focus(in: shortcutWindow, text: true) }
        case .activateHistory: if let shortcutWindow { historyFocus.focus(in: shortcutWindow) }
        case .activateCommit: commitFocused = true
        case .activateOutput: showActivity = true
        case .findObject: showWorkspaceSearch = true
        case .applyStash:
            if sidebarFocus.hasFileFocus && !fromMenu { return false }
            guard store.repository != nil, !store.isBusy else { return true }
            performToolbarCommand("applyStash")
        case .refresh, .refreshAlternate: Task { await store.refresh() }
        case .showLogWindow:
            if let repository = store.repository { LogPresenter.show(repository: repository) }
        case .viewLog:
            if sidebarFocus.hasFileFocus && !fromMenu { return false }
            if fileFocus.hasFileFocus, let path = store.selectedPaths.sorted().first { fileAction(.history, [path]) }
            else if let repository = store.repository { LogPresenter.show(repository: repository) }
        case .clone: guard !store.isBusy else { return true }; createClone = true; showCreate = true
        case .commit: guard store.repository != nil, !store.isBusy else { return true }; commitFocused = true
        case .pull, .fetch, .push, .stash:
            guard store.repository != nil, !store.isBusy else { return true }
            performToolbarCommand(command.rawValue)
        case .createBranch:
            guard store.repository != nil, !store.isBusy else { return true }
            performToolbarCommand("newBranch")
        case .createTag:
            guard store.repository != nil, !store.isBusy else { return true }
            askName(interactionText("Create Tag")) { name in store.operation(interactionText("Create Tag")) { try await $0.createTag(name: name, commit: "HEAD") } }
        default: return false
        }
        return true
    }
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
        let ordered = paths.sorted()
        switch action {
        case .compare:
            guard paths.count == 1, let path = ordered.first else { return }
            guard let file = files.first else {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return }
                ComparePresenter.show(title: path, repository: repository, target: .worktree(path: path, untracked: false))
                return
            }
            let staged = paths == store.selectedPaths ? store.usesStagedDiff(for: file) : (file.isStaged && !file.isUnstaged)
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
        case .rename:
            guard !store.isBusy, ordered.count == 1, let path = ordered.first else { return }
            askName(fileContextText("rename"), initial: path) { destination in
                guard store.repositoryURL == root, !store.isBusy else { return }
                store.operation(fileContextText("rename")) { repo in
                    guard repo.url == root else { return }
                    try await repo.renameWorkspaceFile(path: path, destination: destination)
                }
            }
        case .ignore:
            guard !store.isBusy, !paths.isEmpty, files.count == paths.count, files.allSatisfy(\.isUntracked) else { return }
            store.operation(fileContextText("ignore")) { repo in
                guard repo.url == root else { return }
                for path in ordered { try await repo.ignoreWorkspacePath(path, directory: false) }
            }
        case .trash:
            guard !store.isBusy, !ordered.isEmpty else { return }
            confirm(fileContextText("trash"), fileContextText("trashMessage") + "\n\n" + ordered.joined(separator: "\n")) {
                guard store.repositoryURL == root, !store.isBusy else { return }
                store.operation(fileContextText("trash")) { repo in
                    guard repo.url == root else { return }
                    let key = "RayGit.TrashRecords." + root.standardizedFileURL.path
                    var records = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([TrashedRepositoryFile].self, from: $0) } ?? []
                    for path in ordered {
                        records.append(try await repo.trashWorkspaceFile(path: path))
                        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: key)
                    }
                }
            }
        case .copyName: copyText(ordered.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n"))
        case .copyFiles:
            let urls = ordered.map { root.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        case .copyPath: copyText(paths.sorted().map { root.appendingPathComponent($0).path }.joined(separator: "\n"))
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
        case .rebase: rebaseCommit = commit
        case .useCommitMessage: store.commitMessage = commit.body.isEmpty ? commit.subject : commit.body; commitFocused = true
        case .reset, .resetAdvanced:
            guard !store.isBusy else { return }
            resetRequest = HistoryResetRequest(commit: commit, repositoryURL: repository.url, advanced: action == .resetAdvanced)
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
        case .openRepository: store.requestOpen(URL(fileURLWithPath: value))
        case .revealRepository: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)])
        case .removeRecent: store.recentPaths.removeAll { $0 == value }; UserDefaults.standard.set(store.recentPaths, forKey: "recentRepositories")
        case .copy: copyText(value)
        case .history: store.showHistory(path: nil, ref: value)
        case .createLocalBranch:
            askName(interactionText("Create Branch at %@", value), initial: String(value.split(separator: "/", maxSplits: 1).last ?? "")) { name in
                store.operation(sidebarRefinementText("Create Local Branch…")) { try await $0.createBranch(name: name, startPoint: "refs/remotes/" + value) }
            }
        case .checkout:
            store.switchBranch(to: value) { stash in
                confirmation = PendingAction(title: sidebarRefinementText("Changes Saved in Stash"), message: sidebarRefinementText("Auto Stash Retained", String(stash.prefix(12))), action: {}, informational: true)
            }
        case .merge: confirm(sidebarRefinementText("Merge into Current Branch"), sidebarRefinementText("Merge Branch Message", value, store.branch)) { store.operation(sidebarRefinementText("Merge into Current Branch")) { _ = try await $0.advancedOperation(.merge, first: value, second: "") } }
        case .stopTracking:
            store.operation(sidebarRefinementText("Stop Tracking Remote Branch")) {
                if value.hasPrefix("refs/remotes/") { try await $0.stopTracking(remoteBranch: value) }
                else { try await $0.setUpstream(branch: value, remoteBranch: nil) }
            }
        case .setTracking:
            trackingRepository = store.repository
            selectedUpstream = store.branches.first(where: \.isRemote).map { "refs/remotes/" + $0.name } ?? ""
            trackingBranch = value
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
            fileHost = NSHostingView(rootView: Self.focusRoot(model.files))
            diffHost = NSHostingView(rootView: Self.focusRoot(model.diff))
            footerHost = NSHostingView(rootView: Self.focusRoot(model.footer))
            // Pane sizes belong to the split; SwiftUI content may expand inside each one.
            fileHost.sizingOptions = []; diffHost.sizingOptions = []; footerHost.sizingOptions = []
        }
        func update(_ model: WorkspacePaneSplit) {
            fileHost.rootView = Self.focusRoot(model.files)
            diffHost.rootView = Self.focusRoot(model.diff)
            footerHost.rootView = Self.focusRoot(model.footer)
        }
        private static func focusRoot<V: View>(_ view: V) -> AnyView { AnyView(view.controlSize(.small).nativeFocusRoot()) }
    }
}

final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
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
        distribute(fileHeight: 300, footerHeight: compact ? 160 : 180)
        // Startup can pass through a smaller frame before the window reaches its final size.
        initialized = subviews[0].frame.height >= 300
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
