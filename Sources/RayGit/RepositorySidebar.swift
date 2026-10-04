import SwiftUI
import GitCore
import RayGitLocalization

func sidebarRefinementText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "SidebarRefinement", arguments: arguments)
}

enum SidebarAction { case openRepository, revealRepository, removeRecent, checkout, history, rename, delete, copy, stashShow, stashApply, stashDrop }

struct RepositorySidebar: View {
    @ObservedObject var store: RepositoryStore
    let onAction: (SidebarAction, String) -> Void
    @State private var branchSelection: String?
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack { Text(interactionText("Repositories")).font(.system(size: 13, weight: .semibold)); Spacer(); Button { store.chooseRepository() } label: { Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle()) }.disabled(store.isBusy) }.padding(.horizontal, 16).frame(height: 42)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.recentPaths, id: \.self) { path in repositoryRow(path) }
                    }.padding(.horizontal, 12)
                }.font(.system(size: 12))
            }.frame(minHeight: 130, idealHeight: 300)
            VStack(spacing: 0) {
                HStack { Text(interactionText("Branches")).font(.system(size: 13, weight: .semibold)); Spacer(); RayGitBadge(String(store.branches.count), tint: .secondary) }.padding(.horizontal, 16).frame(height: 42)
                List(selection: $branchSelection) {
                    Section(interactionText("Local Branches")) {
                        ForEach(store.branches.filter { !$0.isRemote }) { branch in
                            HStack(spacing: 6) {
                                Label(branch.name, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                                if branch.isCurrent { Spacer(minLength: 0); Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).accessibilityHidden(true) }
                            }
                                .fontWeight(branch.isCurrent ? .semibold : .regular)
                                .tag("branch:" + branch.name)
                                .listRowBackground(branch.isCurrent ? RayGitStyle.blue.opacity(0.12) : Color.clear)
                        }
                    }
                    Section(interactionText("Remote Branches")) {
                        ForEach(store.branches.filter(\.isRemote)) { branch in Label(branch.name, systemImage: "network").tag("remote:" + branch.name) }
                    }
                    Section(interactionText("Stashes")) {
                        ForEach(store.stashes) { stash in Label(stash.subject, systemImage: "archivebox").lineLimit(2).tag("stash:" + stash.ref) }
                    }
                }.listStyle(.sidebar).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { items in
                        if let item = items.first, items.count == 1 {
                            let target = String(item.dropFirst(item.firstIndex(of: ":").map { item.distance(from: item.startIndex, to: $0) + 1 } ?? 0))
                            if item.hasPrefix("stash:") {
                                Button(interactionText("Show Changes")) { onAction(.stashShow, target) }
                                Button(interactionText("Apply Stash…")) { onAction(.stashApply, target) }.disabled(store.isBusy)
                                Button(interactionText("Drop Stash…")) { onAction(.stashDrop, target) }.disabled(store.isBusy)
                            } else {
                                if item.hasPrefix("branch:") {
                                    Button(interactionText("Check Out…")) { onAction(.checkout, target) }.disabled(store.isBusy || store.branches.first(where: { $0.name == target })?.isCurrent == true)
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
    }
    private func repositoryRow(_ path: String) -> some View {
        let active = path == store.repositoryURL?.path
        let sync = store.repositorySyncStates[path]
        let ahead = sync?.ahead ?? 0, behind = sync?.behind ?? 0, conflicts = sync?.conflicts ?? 0
        let hasPush = ahead > 0, hasPull = behind > 0, hasConflict = conflicts > 0
        let symbol = hasConflict ? "exclamationmark.triangle.fill" : hasPush && hasPull ? "arrow.up.arrow.down.circle" : hasPull ? "arrow.down.circle" : hasPush ? "arrow.up.circle" : "folder"
        let status = hasConflict ? sidebarRefinementText("conflicts", conflicts) : hasPush && hasPull ? sidebarRefinementText("pushPull", ahead, behind) : hasPull ? sidebarRefinementText("pull", behind) : hasPush ? sidebarRefinementText("push", ahead) : path
        return Button { if !store.isBusy { onAction(.openRepository, path) } } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder").font(.system(size: 15)).frame(width: 24, height: 23)
                    .overlay(alignment: .bottomTrailing) {
                        if symbol != "folder" {
                            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                                .padding(1).background(active ? RayGitStyle.blue : RayGitStyle.sidebar, in: Circle())
                        }
                    }
                    .foregroundStyle(active ? Color.white : hasConflict ? Color.orange : hasPush || hasPull ? RayGitStyle.blue : Color.secondary)
                    .help(status).accessibilityLabel(status)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let count = store.repositoryChangeCounts[path] {
                    Text(String(count)).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background((active ? Color.white : Color.secondary).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                }
            }.foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: 34).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? RayGitStyle.blue : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(path).transaction { $0.animation = nil }
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .contextMenu {
                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(store.isBusy)
                Button(interactionText("Reveal in Finder")) { onAction(.revealRepository, path) }
                Button(interactionText("Copy Path")) { onAction(.copy, path) }
                Divider()
                Button(interactionText("Remove from Recent")) { onAction(.removeRecent, path) }
            }
    }
}
