import SwiftUI
import GitCore
import RayGitLocalization

enum SidebarAction { case openRepository, revealRepository, removeRecent, checkout, history, rename, delete, copy, stashShow, stashApply, stashDrop }

struct RepositorySidebar: View {
    @ObservedObject var store: RepositoryStore
    let onAction: (SidebarAction, String) -> Void
    @State private var branchSelection: String?
    @State private var groupPath: String?
    @State private var groupName = ""
    @State private var collapsedGroups: Set<String> = []
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header("Repositories", icon: "externaldrive")
                List {
                    ForEach(Array(Set(store.recentPaths.map { store.repositoryGroups[$0] ?? "" })).sorted(), id: \.self) { group in
                        DisclosureGroup(group.isEmpty ? workflowText("Ungrouped") : group, isExpanded: Binding(get: { !collapsedGroups.contains(group) }, set: { if $0 { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) } })) {
                            ForEach(store.recentPaths.filter { (store.repositoryGroups[$0] ?? "") == group }, id: \.self) { path in repositoryRow(path) }
                        }
                    }
                    Button { store.chooseRepository() } label: { Label(interactionText("Add Repository…"), systemImage: "plus") }.buttonStyle(.plain).disabled(store.isBusy)
                }.listStyle(.sidebar)
            }.frame(minHeight: 140, idealHeight: 350)
            VStack(spacing: 0) {
                header("Branches", icon: "arrow.triangle.branch")
                List(selection: $branchSelection) {
                    Section(interactionText("Local Branches")) {
                        ForEach(store.branches.filter { !$0.isRemote }) { branch in
                            Label(branch.name, systemImage: branch.isCurrent ? "play.fill" : "arrow.triangle.branch")
                                .foregroundStyle(branch.isCurrent ? Color.accentColor : .primary).fontWeight(branch.isCurrent ? .semibold : .regular)
                                .tag("branch:" + branch.name)
                        }
                    }
                    Section(interactionText("Remote Branches")) {
                        ForEach(store.branches.filter(\.isRemote)) { branch in Label(branch.name, systemImage: "network").tag("remote:" + branch.name) }
                    }
                    Section(interactionText("Stashes")) {
                        ForEach(store.stashes) { stash in Label(stash.subject, systemImage: "archivebox").lineLimit(2).tag("stash:" + stash.ref) }
                    }
                }.listStyle(.sidebar)
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
            }.frame(minHeight: 190)
        }
        .sheet(isPresented: Binding(get: { groupPath != nil }, set: { if !$0 { groupPath = nil } })) {
            VStack(spacing: 12) { Text(workflowText("Repository group")); TextField(workflowText("Group name"), text: $groupName); Button(workflowText("Save")) { if let path = groupPath { store.setGroup(path: path, group: groupName) }; groupPath = nil } }.padding(24).frame(width: 360)
        }
    }
    private func repositoryRow(_ path: String) -> some View {
                        Button { onAction(.openRepository, path) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "externaldrive").foregroundStyle(path == store.repositoryURL?.path ? Color.accentColor : .secondary)
                                Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(path == store.repositoryURL?.path ? .semibold : .regular).lineLimit(1)
                                if path == store.repositoryURL?.path { Text("(\(store.branch))").foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(path).disabled(store.isBusy)
                            .contextMenu {
                                Button(interactionText("Open Repository")) { onAction(.openRepository, path) }.disabled(store.isBusy)
                                Button(interactionText("Reveal in Finder")) { onAction(.revealRepository, path) }
                                Button(workflowText("Set group…")) { groupPath = path; groupName = store.repositoryGroups[path] ?? "" }
                                Button(interactionText("Copy Path")) { onAction(.copy, path) }
                                Divider()
                                Button(interactionText("Remove from Recent")) { onAction(.removeRecent, path) }
                            }

    }
    private func header(_ title: String, icon: String) -> some View {
        HStack { Label(interactionText(title), systemImage: icon).font(.system(size: 12, weight: .semibold)); Spacer() }.padding(.horizontal, 10).frame(height: 30).background(.bar)
    }
}
