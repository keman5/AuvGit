import SwiftUI
import GitCore

struct FetchRemoteBranchesPrompt: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let remote: String
}

struct FetchRemoteBranchesSheet: View {
    @ObservedObject var store: RepositoryStore
    let prompt: FetchRemoteBranchesPrompt
    let close: () -> Void
    @StateObject private var authentication = RemoteAuthenticationCoordinator()
    @State private var branches: [String] = []
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var loaded = false
    @State private var error = ""
    private var visible: [String] { branches.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sidebarRefinementText("Fetch…")).font(.title3.weight(.semibold))
            Text(prompt.remote).font(.system(.body, design: .monospaced))
            Text(sidebarRefinementText("Choose remote branches to fetch and track.")).font(.callout).foregroundStyle(.secondary)
            StableTextField(sidebarRefinementText("Remote Branch"), text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Button(sidebarRefinementText("Select All")) { selected.formUnion(visible) }
                Button(sidebarRefinementText("Deselect All")) { selected.subtract(visible) }
                Spacer()
                Text(String(selected.count)).monospacedDigit().foregroundStyle(.secondary)
            }.disabled(store.isBusy || visible.isEmpty)
            List(visible, id: \.self) { branch in
                KeyViewProxy(label: branch, checked: selected.contains(branch)) {
                    if selected.contains(branch) { selected.remove(branch) } else { selected.insert(branch) }
                }
            }.frame(height: 250).disabled(store.isBusy)
                .overlay {
                    if loaded && branches.isEmpty { Text(sidebarRefinementText("All remote branches have already been fetched.")).foregroundStyle(.secondary) }
                }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                DialogButton(workflowText("Cancel"), role: .cancel, action: close).disabled(store.isBusy)
                if !loaded { DialogButton(sidebarRefinementText("Reload Remote Branches")) { run(fetch: false) }.disabled(store.isBusy) }
                DialogButton(sidebarRefinementText("Fetch Selected Branches"), prominent: true) { run(fetch: true) }
                    .disabled(store.isBusy || selected.isEmpty)
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 540)
        .interactiveDismissDisabled(store.isBusy)
        .onAppear { if !loaded { run(fetch: false) } }
        .onChange(of: store.repositoryURL) { _, _ in authentication.cancel(); close() }
        .onDisappear { authentication.cancel() }
        .auvGitSheet(item: $authentication.request, focusesOnPresentation: false) { request in
            RemoteAuthenticationSheet(request: request, error: authentication.submissionError, isSubmitting: authentication.isSubmitting,
                                      submit: { authentication.submit($0) }, cancel: { authentication.cancel() })
        }
    }

    private func run(fetch: Bool, credential supplied: NetworkCredential? = nil, save: Bool = false) {
        let repository = prompt.repository, remote = prompt.remote
        let names = selected.sorted()
        guard store.repository === repository, !store.isBusy, !fetch || !names.isEmpty else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let supplied { credential = supplied }
            else { credential = await authentication.savedCredential(for: repository, operation: .fetch, remoteName: remote) }
            guard store.repository === repository, !store.isBusy else { return }
            error = ""
            let name = sidebarRefinementText(fetch ? "Fetch Selected Branches" : "Reload Remote Branches")
            store.operation(name, onFailure: { failure in
                error = OperationFailure.message(failure, repository: repository.url)
                Task { @MainActor in
                    guard store.repository === repository else { return }
                    _ = await authentication.presentIfNeeded(error: failure, repository: repository, operation: .fetch, remoteName: remote) { retry in
                        run(fetch: fetch, credential: retry.credential, save: retry.saveCredential)
                    }
                }
            }) { active in
                try await authentication.perform(with: credential) {
                    if fetch { try await active.fetchRemoteBranches(remote: remote, branches: names, credential: credential) }
                    else {
                        branches = try await active.unfetchedRemoteBranches(remote: remote, credential: credential)
                        selected.formIntersection(branches); loaded = true
                    }
                }
                if save, let credential {
                    do { try await authentication.save(credential, for: active, operation: .fetch, remoteName: remote) }
                    catch { store.report(error) }
                }
                if fetch { close() }
            }
        }
    }
}
