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
                RayGitPaneHeader(title: interactionText("Repositories"), systemImage: "externaldrive", count: store.recentPaths.count)
                List {
                    ForEach(store.recentPaths, id: \.self) { path in repositoryRow(path) }
                    Button { store.chooseRepository() } label: { Label(interactionText("Add Repository…"), systemImage: "plus") }.buttonStyle(.plain).disabled(store.isBusy)
                }.listStyle(.sidebar).font(.system(size: 12)).scrollContentBackground(.hidden)
            }.frame(minHeight: 110, idealHeight: 240)
            VStack(spacing: 0) {
                RayGitPaneHeader(title: interactionText("Branches"), systemImage: "arrow.triangle.branch", count: store.branches.count)
                List(selection: $branchSelection) {
                    Section(interactionText("Local Branches")) {
                        ForEach(store.branches.filter { !$0.isRemote }) { branch in
                            HStack(spacing: 6) {
                                Label(branch.name, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                                if branch.isCurrent { Spacer(minLength: 0); Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).accessibilityHidden(true) }
                            }
                                .fontWeight(branch.isCurrent ? .semibold : .regular)
                                .tag("branch:" + branch.name)
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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: active ? "folder.fill" : "folder").foregroundStyle(active ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(active ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.middle)
                    if active, !store.branch.isEmpty {
                        Label(store.branch, systemImage: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if active { Circle().fill(Color.accentColor).frame(width: 5, height: 5).accessibilityHidden(true) }
            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(path).disabled(store.isBusy)
            .listRowBackground(active ? Color.accentColor.opacity(0.10) : Color.clear)
            .contextMenu {
                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(store.isBusy)
                Button(interactionText("Reveal in Finder")) { onAction(.revealRepository, path) }
                Button(interactionText("Copy Path")) { onAction(.copy, path) }
                Divider()
                Button(interactionText("Remove from Recent")) { onAction(.removeRecent, path) }
            }
    }
}
