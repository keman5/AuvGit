import SwiftUI
import GitCore
import RayGitLocalization

func sidebarRefinementText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "SidebarRefinement", arguments: arguments)
}

enum SidebarAction { case openRepository, revealRepository, removeRecent, checkout, createLocalBranch, history, rename, delete, deleteRemote, copy, stashShow, stashApply, stashDrop, merge, stopTracking, setTracking }

private struct RepositoryRowButtonStyle: ButtonStyle {
    var selected: Bool
    var allowsSelection: Bool
    func makeBody(configuration: Configuration) -> some View {
        let highlighted = selected || (allowsSelection && configuration.isPressed)
        configuration.label
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .background(highlighted ? RayGitStyle.blue : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct RepositorySidebar: View {
    @ObservedObject var store: RepositoryStore
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @State private var renameStash: String?
    @State private var stashName = ""
    @State private var rebaseReference: String?
    let onAction: (SidebarAction, String) -> Void
    var repositoryFocusRequest: UUID? = nil
    var branchFocus: WorkspaceFileFocus? = nil
    @FocusState private var focusedRepository: String?
    @State private var branchSelection: String?
    @State private var contextTarget: RepositoryContextTarget?
    @AppStorage("sidebar.localBranchesExpanded") private var localBranchesExpanded = true
    @AppStorage("sidebar.stashesExpanded") private var stashesExpanded = true
    var body: some View {
        RepositorySidebarSplit(repositories: repositoryPane, branches: branchPane)
        .controlSize(.small)
        .background(RayGitStyle.sidebar)
        .rayGitSheet(item: $contextTarget) { target in RepositoryContextEditor(store: store, target: target) }
        .rayGitSheet(isPresented: Binding(get: { rebaseReference != nil }, set: { if !$0 { rebaseReference = nil } })) {
            RebaseWorkflowView(store: store, onClose: { rebaseReference = nil }, initialBase: rebaseReference ?? "HEAD~1")
                .frame(width: 1000, height: 700).padding(20)
        }
        .rayGitSheet(isPresented: Binding(get: { renameStash != nil }, set: { if !$0 { renameStash = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text(shortcutText("Rename Stash")).font(.headline)
                TextField(workflowText("Stash message"), text: $stashName).textFieldStyle(.roundedBorder)
                HStack {
                    DialogButton(workflowText("Cancel"), role: .cancel) { renameStash = nil }
                    DialogButton(shortcutText("Rename Stash"), prominent: true) {
                        guard let reference = renameStash else { return }; let name = stashName; renameStash = nil
                        store.operation(shortcutText("Rename Stash")) { _ = try await $0.renameStash(reference: reference, message: name) }
                    }.disabled(stashName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
            }.padding(24).frame(width: 360)
        }
    }
    private var repositoryPane: some View {
        VStack(spacing: 0) {
                HStack { Text(interactionText("Repositories")).font(.system(size: 13, weight: .semibold)); Spacer(); Button { store.chooseRepository() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(store.isBusy) }.padding(.horizontal, 10).frame(height: 32)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.recentPaths, id: \.self) { path in repositoryRow(path) }
                    }.padding(.horizontal, 6)
                }.font(.system(size: 12))
                    .onChange(of: repositoryFocusRequest) { _, _ in
                        guard let path = store.highlightedRepositoryPath ?? store.recentPaths.first else { return }
                        proxy.scrollTo(path)
                        DispatchQueue.main.async { focusedRepository = path }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .rayGitRepositoryCreated)) { event in
                        guard let owner = event.object as? RepositoryStore, owner === store,
                              let path = event.userInfo?["path"] as? String else { return }
                        proxy.scrollTo(path, anchor: .center)
                        focusedRepository = path
                    }
                }
            }.frame(minHeight: 130, idealHeight: 300)
    }
    private var branchPane: some View {
        VStack(spacing: 0) {
                HStack { Text(interactionText("Branches")).font(.system(size: 13, weight: .semibold)); Spacer(); RayGitBadge(String(store.branches.count), tint: .secondary) }.padding(.horizontal, 10).frame(height: 32)
                NativeBranchTable(branches: store.branches, stashes: store.stashes,
                    repositoryPath: store.repositoryURL?.path, repositoryIdentity: store.repository.map { ObjectIdentifier($0) }, currentBranch: store.branch, isBusy: store.isBusy,
                    localExpanded: $localBranchesExpanded, stashesExpanded: $stashesExpanded, selection: $branchSelection,
                    onAction: onAction, onRenameStash: prepareStashRename, onShortcut: handleShortcut)
                    .background { if let branchFocus { WorkspaceFileFocusRegion(focus: branchFocus).allowsHitTesting(false).accessibilityHidden(true) } }
            }.frame(minHeight: 170)
    }

    private func prepareStashRename(_ reference: String) {
        stashName = store.stashes.first { $0.ref == reference }?.subject ?? ""
        renameStash = reference
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let item = branchSelection, let separator = item.firstIndex(of: ":") else { return false }
        let target = String(item[item.index(after: separator)...])
        if ShortcutBinding(key: "c", modifiers: 1).matches(event) {
            onAction(.copy, item.hasPrefix("stash:") ? store.stashes.first { $0.ref == target }?.subject ?? target : target)
            return true
        }
        guard !store.isBusy else { return false }
        func matches(_ command: ShortcutCommand) -> Bool { shortcuts.binding(command).matches(event) }
        if item.hasPrefix("stash:") {
            if matches(.renameStash) { prepareStashRename(target); return true }
            if matches(.applyStash) { onAction(.stashApply, target); return true }
            if matches(.viewLog) || matches(.showChanges) { onAction(.stashShow, target); return true }
        } else {
            let reference = (item.hasPrefix("remote:") ? "refs/remotes/" : "refs/heads/") + target
            if matches(.viewLog) { onAction(.history, reference); return true }
            if matches(.rebase) { rebaseReference = reference; return true }
            if item.hasPrefix("branch:") {
                if matches(.renameBranch) { onAction(.rename, target); return true }
                if matches(.checkout) { onAction(.checkout, target); return true }
            }
        }
        return false
    }
    private func repositoryRow(_ path: String) -> some View {
        let active = path == store.highlightedRepositoryPath
        let sync = store.repositorySyncStates[path]
        let ahead = sync?.ahead ?? 0, behind = sync?.behind ?? 0, conflicts = sync?.conflicts ?? 0
        let hasPush = ahead > 0, hasPull = behind > 0, hasConflict = conflicts > 0
        let symbol = hasConflict ? "exclamationmark.triangle.fill" : hasPush && hasPull ? "arrow.up.arrow.down.circle" : hasPull ? "arrow.down.circle" : hasPush ? "arrow.up.circle" : "folder"
        let status = hasConflict ? sidebarRefinementText("conflicts", conflicts) : hasPush && hasPull ? sidebarRefinementText("pushPull", ahead, behind) : hasPull ? sidebarRefinementText("pull", behind) : hasPush ? sidebarRefinementText("push", ahead) : path
        return Button { focusedRepository = path; if store.canOpenRepository { onAction(.openRepository, path) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 13)).frame(width: 20, height: 19)
                    .overlay(alignment: .bottomTrailing) {
                        if symbol != "folder" {
                            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
                                .padding(1).background(active ? RayGitStyle.blue : RayGitStyle.sidebar, in: Circle())
                        }
                    }
                    .foregroundStyle(active ? Color.white : hasConflict ? Color.orange : hasPush || hasPull ? RayGitStyle.blue : Color.secondary)
                    .help(status).accessibilityLabel(status)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let count = store.repositoryChangeCounts[path], count > 0 {
                    Text(String(count)).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((active ? Color.white : Color.secondary).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                }
            }.padding(.horizontal, 6).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(RepositoryRowButtonStyle(selected: active, allowsSelection: store.canOpenRepository)).help(path).transaction { $0.animation = nil }
            .accessibilityAddTraits(active ? .isSelected : [])
            .focusable().focused($focusedRepository, equals: path).id(path)
            .onKeyPress("c", phases: .down) { press in
                guard press.modifiers == .command else { return .ignored }
                onAction(.copy, URL(fileURLWithPath: path).lastPathComponent)
                return .handled
            }
            .onKeyPress(.return) { guard store.canOpenRepository else { return .handled }; onAction(.openRepository, path); return .handled }
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .contextRowFocus()
            .contextMenu {
                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(!store.canOpenRepository)
                Button(L10n.text("Refresh Repository")) {
                    Task { _ = await store.performRepositoryContextOperation(L10n.text("Refresh Repository"), path: path) { repository in _ = try await repository.status() } }
                }.disabled(store.isBusy)
                Divider()
                Button(repositoryContextText("Edit Remote URL")) { contextTarget = RepositoryContextTarget(path: path, editor: .remote) }.disabled(store.isBusy)
                Button(repositoryContextText("Edit Ignore File")) { contextTarget = RepositoryContextTarget(path: path, editor: .ignore) }.disabled(store.isBusy)
                Divider()
                Button(interactionText("Reveal in Finder")) { onAction(.revealRepository, path) }
                Button(interactionText("Copy Path")) { onAction(.copy, path) }
                Divider()
                Button(interactionText("Remove Repository")) { onAction(.removeRecent, path) }
            }
    }
}
