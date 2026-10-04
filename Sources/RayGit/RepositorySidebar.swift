import SwiftUI
import GitCore
import RayGitLocalization

enum SidebarAction { case openRepository, revealRepository, removeRecent, checkout, history, rename, delete, copy, stashShow, stashApply, stashDrop }

struct RepositorySidebar: View {
    @ObservedObject var store: RepositoryStore
    let onAction: (SidebarAction, String) -> Void
    @State private var branchSelection: String?
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack { Text(interactionText("Repositories")).font(.system(size: 13, weight: .semibold)); Spacer(); Button { store.chooseRepository() } label: { Image(systemName: "plus") }.disabled(store.isBusy) }.padding(.horizontal, 16).frame(height: 42)
                List {
                    ForEach(store.recentPaths, id: \.self) { path in repositoryRow(path) }
                }.listStyle(.sidebar).font(.system(size: 12)).scrollContentBackground(.hidden)
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
                                Button(interactionText("Log")) { onAction(.history, target) }.disabled(store.isBusy)
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
                        else if item.hasPrefix("remote:") { onAction(.history, String(item.dropFirst(7))) }
                        else if item.hasPrefix("stash:") { onAction(.stashShow, String(item.dropFirst(6))) }
                    }
            }.frame(minHeight: 170)
        }
        .controlSize(.small)
        .background(RayGitStyle.sidebar)
    }
    private func repositoryRow(_ path: String) -> some View {
        let active = path == store.repositoryURL?.path
        return Button { onAction(.openRepository, path) } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder").frame(width: 20)
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
        }.buttonStyle(.plain).help(path).disabled(store.isBusy)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
            .contextMenu {
                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(store.isBusy)
                Button(interactionText("Reveal in Finder")) { onAction(.revealRepository, path) }
                Button(interactionText("Copy Path")) { onAction(.copy, path) }
                Divider()
                Button(interactionText("Remove from Recent")) { onAction(.removeRecent, path) }
            }
    }
}
