import SwiftUI
import GitCore
import RayGitLocalization

func sidebarRefinementText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "SidebarRefinement", arguments: arguments)
}

enum SidebarAction { case openRepository, revealRepository, removeRecent, checkout, history, rename, delete, copy, stashShow, stashApply, stashDrop }

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
    @AppStorage("sidebar.remoteBranchesExpanded") private var remoteBranchesExpanded = true
    @AppStorage("sidebar.stashesExpanded") private var stashesExpanded = true
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack { Text(interactionText("Repositories")).font(.system(size: 13, weight: .semibold)); Spacer(); Button { store.chooseRepository() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 18, height: 18).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(store.isBusy) }.padding(.horizontal, 16).frame(height: 32)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.recentPaths, id: \.self) { path in repositoryRow(path) }
                    }.padding(.horizontal, 12)
                }.font(.system(size: 12))
                    .onChange(of: repositoryFocusRequest) { _, _ in
                        guard let path = store.repositoryURL?.path ?? store.recentPaths.first else { return }
                        proxy.scrollTo(path)
                        DispatchQueue.main.async { focusedRepository = path }
                    }
                }
            }.frame(minHeight: 130, idealHeight: 300)
            VStack(spacing: 0) {
                HStack { Text(interactionText("Branches")).font(.system(size: 13, weight: .semibold)); Spacer(); RayGitBadge(String(store.branches.count), tint: .secondary) }.padding(.horizontal, 16).frame(height: 42)
                List(selection: $branchSelection) {
                    branchGroupHeader("Local Branches", isExpanded: $localBranchesExpanded)
                    if localBranchesExpanded {
                        ForEach(store.branches.filter { !$0.isRemote }) { branch in
                            HStack(spacing: 6) {
                                Label(branch.name, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                                if branch.isCurrent { Spacer(minLength: 0); Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).accessibilityHidden(true) }
                            }
                                .frame(height: 18)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 2, trailing: 8))
                                .fontWeight(branch.isCurrent ? .semibold : .regular)
                                .tag("branch:" + branch.name)
                                .listRowBackground(branch.isCurrent ? RayGitStyle.blue.opacity(0.12) : Color.clear)
                        }
                    }
                    branchGroupHeader("Remote Branches", isExpanded: $remoteBranchesExpanded)
                    if remoteBranchesExpanded {
                        ForEach(store.branches.filter(\.isRemote)) { branch in
                            Label(branch.name, systemImage: "network")
                                .lineLimit(1).truncationMode(.middle).frame(height: 18)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 2, trailing: 8))
                                .tag("remote:" + branch.name)
                        }
                    }
                    branchGroupHeader("Stashes", isExpanded: $stashesExpanded)
                    if stashesExpanded {
                        ForEach(store.stashes) { stash in
                            Label(stash.subject, systemImage: "archivebox")
                                .lineLimit(1).truncationMode(.tail).frame(height: 18)
                                .listRowSeparator(.hidden)
                                .help(stash.subject)
                                .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 2, trailing: 8))
                                .tag("stash:" + stash.ref)
                        }
                    }
                }.listStyle(.plain).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    .environment(\.defaultMinListRowHeight, 22)
                    .background(BranchListDensity(onShortcut: handleShortcut).allowsHitTesting(false).accessibilityHidden(true))
                    .background { if let branchFocus { WorkspaceFileFocusRegion(focus: branchFocus).allowsHitTesting(false).accessibilityHidden(true) } }
                    .contextMenu(forSelectionType: String.self) { items in
                        if let item = items.first, items.count == 1 {
                            let target = String(item.dropFirst(item.firstIndex(of: ":").map { item.distance(from: item.startIndex, to: $0) + 1 } ?? 0))
                            if item.hasPrefix("stash:") {
                                Button(interactionText("Show Changes")) { onAction(.stashShow, target) }
                                Button(interactionText("Apply Stash…")) { onAction(.stashApply, target) }.disabled(store.isBusy)
                                Button(shortcutText("Rename Stash")) { prepareStashRename(target) }.disabled(store.isBusy)
                                Button(interactionText("Drop Stash…")) { onAction(.stashDrop, target) }.disabled(store.isBusy)
                            } else {
                                if item.hasPrefix("branch:") {
                                    Button(interactionText("Check Out…")) { onAction(.checkout, target) }.disabled(store.isBusy)
                                }
                                Button(interactionText("Log")) { onAction(.history, (item.hasPrefix("remote:") ? "refs/remotes/" : "refs/heads/") + target) }.disabled(store.isBusy)
                                if item.hasPrefix("branch:") {
                                    Divider()
                                    Button(interactionText("Rename Branch…")) { onAction(.rename, target) }.disabled(store.isBusy)
                                    Button(interactionText("Delete Branch…")) { onAction(.delete, target) }.disabled(store.isBusy || store.branches.first(where: { $0.name == target })?.isCurrent == true)
                                }
                                Divider()
                                Button(interactionText("Copy Name")) { onAction(.copy, target) }
                            }
                        }
                    } primaryAction: { items in
                        guard let item = items.first else { return }
                        if item.hasPrefix("branch:") { onAction(.checkout, String(item.dropFirst(7))) }
                        else if item.hasPrefix("remote:") { onAction(.history, "refs/remotes/" + String(item.dropFirst(7))) }
                        else if item.hasPrefix("stash:") { onAction(.stashShow, String(item.dropFirst(6))) }
                    }
            }.frame(minHeight: 170)
        }
        .controlSize(.small)
        .background(RayGitStyle.sidebar)
        .sheet(item: $contextTarget) { target in RepositoryContextEditor(store: store, target: target) }
        .sheet(isPresented: Binding(get: { rebaseReference != nil }, set: { if !$0 { rebaseReference = nil } })) {
            RebaseWorkflowView(store: store, onClose: { rebaseReference = nil }, initialBase: rebaseReference ?? "HEAD~1")
                .frame(width: 1000, height: 700).padding(20)
        }
        .alert(shortcutText("Rename Stash"), isPresented: Binding(get: { renameStash != nil }, set: { if !$0 { renameStash = nil } })) {
            TextField(workflowText("Stash message"), text: $stashName)
            Button(workflowText("Cancel"), role: .cancel) { renameStash = nil }
            Button(shortcutText("Rename Stash")) {
                guard let reference = renameStash else { return }; let name = stashName; renameStash = nil
                store.operation(shortcutText("Rename Stash")) { _ = try await $0.renameStash(reference: reference, message: name) }
            }.disabled(stashName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func prepareStashRename(_ reference: String) {
        stashName = store.stashes.first { $0.ref == reference }?.subject ?? ""
        renameStash = reference
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard !store.isBusy, let item = branchSelection, let separator = item.firstIndex(of: ":") else { return false }
        let target = String(item[item.index(after: separator)...])
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
    private func branchGroupHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12)
                    .accessibilityHidden(true)
                Text(interactionText(title)).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }.foregroundStyle(.secondary).frame(height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(interactionText(title))
            .accessibilityValue(isExpanded.wrappedValue ? sidebarRefinementText("Expanded") : sidebarRefinementText("Collapsed"))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
    }
    private func repositoryRow(_ path: String) -> some View {
        let active = path == store.repositoryURL?.path
        let sync = store.repositorySyncStates[path]
        let ahead = sync?.ahead ?? 0, behind = sync?.behind ?? 0, conflicts = sync?.conflicts ?? 0
        let hasPush = ahead > 0, hasPull = behind > 0, hasConflict = conflicts > 0
        let symbol = hasConflict ? "exclamationmark.triangle.fill" : hasPush && hasPull ? "arrow.up.arrow.down.circle" : hasPull ? "arrow.down.circle" : hasPush ? "arrow.up.circle" : "folder"
        let status = hasConflict ? sidebarRefinementText("conflicts", conflicts) : hasPush && hasPull ? sidebarRefinementText("pushPull", ahead, behind) : hasPull ? sidebarRefinementText("pull", behind) : hasPush ? sidebarRefinementText("push", ahead) : path
        return Button { if !store.isBusy { onAction(.openRepository, path) } } label: {
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
            }.foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? RayGitStyle.blue : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(path).transaction { $0.animation = nil }
            .focusable().focused($focusedRepository, equals: path).id(path)
            .onKeyPress(.return) { guard !store.isBusy else { return .handled }; onAction(.openRepository, path); return .handled }
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .contextMenu {
                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(store.isBusy)
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

/// SwiftUI's macOS List can keep native row spacing despite compact row insets.
private struct BranchListDensity: NSViewRepresentable {
    var onShortcut: (NSEvent) -> Bool = { _ in false }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onShortcut = onShortcut; view.configure() }

    final class Probe: NSView {
        private weak var configuredTable: NSTableView?
        var onShortcut: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); configure()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                      !self.isHiddenOrHasHiddenAncestor, let table = self.configuredTable,
                      let responder = window.firstResponder as? NSView,
                      !(responder is NSTextView), !(responder is NSTextField),
                      responder === table || responder.isDescendant(of: table) else { return event }
                return self.onShortcut(event) ? nil : event
            }
        }
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
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
            if table.rowSizeStyle != .custom { table.rowSizeStyle = .custom }
            if table.rowHeight != 24 { table.rowHeight = 24 }
            if table.intercellSpacing.height != 0 { table.intercellSpacing.height = 0 }
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = table(in: child) { return table }
            }
            return nil
        }
    }
}
