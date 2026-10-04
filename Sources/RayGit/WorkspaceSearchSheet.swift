import SwiftUI
import GitCore
import RayGitLocalization

func designWorkspaceText(_ key: String) -> String { L10n.text(key, table: "DesignWorkspace") }

struct WorkspaceSearchSheet: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedCaseInsensitiveContains(query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(designWorkspaceText("Search files, commits, branches…"), text: $query).textFieldStyle(.plain).focused($focused)
                Button(designWorkspaceText("Close")) { dismiss() }
            }.padding(16)
            Divider()
            List {
                Section(designWorkspaceText("Files")) {
                    ForEach(store.files.filter { matches($0.path) }.prefix(30)) { file in
                        Button { store.mode = "workspace"; store.fileFilter = ""; store.selectedPaths = [file.path]; dismiss() } label: { Label(file.path, systemImage: "doc.text") }
                    }
                }
                Section(interactionText("Branches")) {
                    ForEach(store.branches.filter { matches($0.name) }.prefix(20)) { branch in
                        Button { store.showHistory(path: nil, ref: branch.name); dismiss() } label: { Label(branch.name, systemImage: "arrow.triangle.branch") }
                    }
                }
                Section(designWorkspaceText("Commits")) {
                    Button { store.historySearch = query; store.mode = "history"; dismiss() } label: { Label(designWorkspaceText("Search all commit history"), systemImage: "clock.arrow.circlepath") }
                    ForEach(store.commits.filter { matches($0.subject + " " + $0.hash) }.prefix(20)) { commit in
                        Button { store.mode = "history"; store.selectedCommit = commit.hash; dismiss() } label: { HStack { Text(commit.subject).lineLimit(1); Spacer(); Text(commit.shortHash).foregroundStyle(.secondary) } }
                    }
                }
            }.listStyle(.plain).buttonStyle(.plain)
        }.frame(width: 620, height: 440).background(RayGitStyle.canvas).onAppear { focused = true }
    }
}
