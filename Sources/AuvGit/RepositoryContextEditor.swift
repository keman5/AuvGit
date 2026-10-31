import SwiftUI
import GitCore
import AuvGitLocalization

func repositoryContextText(_ key: String) -> String { L10n.text(key, table: "RepositoryContext") }
struct RepositoryContextTarget: Identifiable {
    enum Editor { case remote, ignore }
    let path: String
    let editor: Editor
    var id: String { path + (editor == .remote ? ":remote" : ":ignore") }
}

struct RepositoryContextEditor: View {
    @ObservedObject var store: RepositoryStore
    let target: RepositoryContextTarget
    @Environment(\.dismiss) private var dismiss
    @State private var expectedIgnore: Data?
    @State private var ignoreText = ""
    @State private var remotes: [RepositoryRemoteConfiguration] = []
    @State private var remoteName = ""
    @State private var fetchIndex = 0
    @State private var fetchURL = ""
    @State private var editPush = false
    @State private var pushURL = ""
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?
    private var selectedRemote: RepositoryRemoteConfiguration? { remotes.first { $0.name == remoteName } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(repositoryContextText(target.editor == .ignore ? "Edit Ignore File" : "Edit Remote URL")).font(.headline)
            Text(target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if target.editor == .ignore {
                TextEditor(text: $ignoreText).font(.system(size: 12, design: .monospaced)).frame(minHeight: 240).disabled(!loaded || store.isBusy)
            } else if remotes.isEmpty && loaded {
                Text(repositoryContextText("No remotes configured")).foregroundStyle(.secondary)
            } else {
                Picker(repositoryContextText("Remote"), selection: $remoteName) { ForEach(remotes) { Text($0.name).tag($0.name) } }
                    .onChange(of: remoteName) { _, _ in selectRemote() }
                if let remote = selectedRemote, remote.fetchURLs.count > 1 {
                    Picker(repositoryContextText("Fetch URL"), selection: $fetchIndex) {
                        ForEach(remote.fetchURLs.indices, id: \.self) { index in Text(remote.fetchURLs[index]).tag(index) }
                    }.onChange(of: fetchIndex) { _, index in
                        guard let remote = selectedRemote, remote.fetchURLs.indices.contains(index) else { return }
                        fetchURL = remote.fetchURLs[index]
                    }
                }
                TextField(repositoryContextText("Fetch URL"), text: $fetchURL).textFieldStyle(.roundedBorder)
                KeyViewProxy(label: repositoryContextText("Edit explicit push URL"), checked: editPush) { editPush.toggle() }
                if editPush {
                    TextField(repositoryContextText("Push URL"), text: $pushURL).textFieldStyle(.roundedBorder)
                    Text(repositoryContextText("Empty removes the first explicit push URL")).font(.caption).foregroundStyle(.secondary)
                    if (selectedRemote?.pushURLs.count ?? 0) > 1 { Text(repositoryContextText("Only the first push URL is edited")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                DialogButton(repositoryContextText("Reload")) { Task { await load() } }.disabled(store.isBusy || loading)
                DialogButton(repositoryContextText("Cancel"), role: .cancel) { dismiss() }.disabled(store.isBusy)
                DialogButton(repositoryContextText("Save"), prominent: true) { save() }
                    .disabled(!loaded || store.isBusy || (target.editor == .remote && (selectedRemote == nil || fetchURL.isEmpty)))
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(20).frame(width: target.editor == .ignore ? 580 : 360)
        // Rehosting a sheet cancels SwiftUI .task; keep this finite read alive.
        .onAppear { Task { await load() } }
    }
    private func selectRemote() {
        fetchIndex = 0; fetchURL = selectedRemote?.fetchURLs.first ?? ""; pushURL = selectedRemote?.pushURLs.first ?? ""; editPush = false
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        loaded = false; error = nil
        let repository = GitRepository(url: URL(fileURLWithPath: target.path))
        do {
            if target.editor == .ignore {
                expectedIgnore = try await repository.gitignoreSnapshot()
                ignoreText = expectedIgnore.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            } else {
                remotes = try await repository.remoteConfigurations(); remoteName = remotes.first?.name ?? ""; selectRemote()
            }
            loaded = true
        } catch { self.error = GitCommandLog.redact(error.localizedDescription) }
    }
    private func save() {
        let expected = expectedIgnore, text = ignoreText, remote = selectedRemote, index = fetchIndex, fetch = fetchURL, push: String? = editPush ? pushURL : nil
        if target.editor == .ignore {
            if Data(text.utf8) == (expected ?? Data()) { dismiss(); return }
        } else if let remote, remote.fetchURLs.indices.contains(index), remote.fetchURLs[index] == fetch,
                  push == nil || (push == "" ? remote.pushURLs.isEmpty : push == remote.pushURLs.first) {
            dismiss(); return
        }
        Task {
            let success = await store.performRepositoryContextOperation(repositoryContextText(target.editor == .ignore ? "Edit Ignore File" : "Edit Remote URL"), path: target.path) { repository in
                if target.editor == .ignore { try await repository.saveGitignore(text: text, expected: expected) }
                else if let remote { try await repository.updateRemoteURL(expected: remote, fetchIndex: index, fetchURL: fetch, pushURL: push) }
            }
            if success { dismiss() } else { error = store.error }
        }
    }
}
