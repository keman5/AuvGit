import SwiftUI
import GitCore
import AuvGitLocalization

func designWorkspaceText(_ key: String) -> String { L10n.text(key, table: "DesignWorkspace") }

struct WorkspaceSearchSheet: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedResults: Set<String> = []
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedCaseInsensitiveContains(query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                StableTextField(designWorkspaceText("Search files, commits, branches…"), text: $query, rounded: false)
                DialogButton(designWorkspaceText("Close"), prominent: true, role: .cancel) { dismiss() }
            }.buttonStyle(AuvGitDialogButtonStyle()).padding(16)
            Divider()
            List(selection: $selectedResults) {
                Section(designWorkspaceText("Files")) {
                    ForEach(store.files.filter { matches($0.path) }.prefix(30)) { file in
                        Label(file.path, systemImage: "doc.text").tag("file:" + file.path)
                    }
                }
                Section(interactionText("Branches")) {
                    ForEach(store.branches.filter { matches($0.name) }.prefix(20)) { branch in
                        Label(branch.name, systemImage: "arrow.triangle.branch").tag("branch:" + branch.name)
                    }
                }
                Section(designWorkspaceText("Commits")) {
                    Label(designWorkspaceText("Search all commit history"), systemImage: "clock.arrow.circlepath").tag("search")
                    ForEach(store.commits.filter { matches($0.subject + " " + $0.hash) }.prefix(20)) { commit in
                        HStack { Text(commit.subject).lineLimit(1); Spacer(); Text(commit.shortHash).foregroundStyle(.secondary) }.tag("commit:" + commit.hash)
                    }
                }
            }.listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty { Button(workflowText("Open")) { openResults(ids) } }
                } primaryAction: { openResults($0) }
                .onKeyPress(.return) { guard !selectedResults.isEmpty else { return .ignored }; openResults(selectedResults); return .handled }
                .onChange(of: query) { _, _ in selectedResults = [] }
        }.frame(width: 620, height: 440).background(AuvGitStyle.canvas)
    }
    private func openResults(_ ids: Set<String>) {
        let files = Set(ids.filter { $0.hasPrefix("file:") }.map { String($0.dropFirst(5)) })
        if files.count == ids.count, !files.isEmpty {
            store.mode = "workspace"; store.fileFilter = ""; store.selectedPaths = files; dismiss(); return
        }
        guard ids.count == 1, let id = ids.first else { return }
        if id.hasPrefix("branch:") { store.showHistory(path: nil, ref: String(id.dropFirst(7))) }
        else if let repository = store.repository {
            if id == "search" { LogPresenter.show(repository: repository, search: query, applyFilter: true) }
            else if id.hasPrefix("commit:") { LogPresenter.show(repository: repository, selectedCommit: String(id.dropFirst(7)), applyFilter: true) }
        }
        dismiss()
    }
}
