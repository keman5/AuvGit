import SwiftUI
import GitCore
import AuvGitLocalization

func designWorkspaceText(_ key: String) -> String { L10n.text(key, table: "DesignWorkspace") }

struct WorkspaceSearchSheet: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedCaseInsensitiveContains(query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                StableTextField(designWorkspaceText("Search files, commits, branches…"), text: $query, rounded: false, initialFocus: true)
                DialogButton(designWorkspaceText("Close"), prominent: true, role: .cancel) { dismiss() }
            }.buttonStyle(AuvGitDialogButtonStyle()).padding(16)
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
                    Button { if let repository = store.repository { LogPresenter.show(repository: repository, search: query, applyFilter: true) }; dismiss() } label: { Label(designWorkspaceText("Search all commit history"), systemImage: "clock.arrow.circlepath") }
                    ForEach(store.commits.filter { matches($0.subject + " " + $0.hash) }.prefix(20)) { commit in
                        Button { if let repository = store.repository { LogPresenter.show(repository: repository, selectedCommit: commit.hash, applyFilter: true) }; dismiss() } label: { HStack { Text(commit.subject).lineLimit(1); Spacer(); Text(commit.shortHash).foregroundStyle(.secondary) } }
                    }
                }
            }.listStyle(.plain).buttonStyle(.plain)
        }.frame(width: 620, height: 440).background(AuvGitStyle.canvas)
    }
}
