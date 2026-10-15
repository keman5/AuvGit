import SwiftUI
import GitCore

struct FirstBranchPushPrompt: Identifiable {
    let repository: GitRepository
    let request: FirstBranchPushRequest
    var id: UUID { request.id }
}

struct FirstBranchPushSheet: View {
    @ObservedObject var store: RepositoryStore
    let prompt: FirstBranchPushPrompt
    let close: () -> Void
    @StateObject private var authentication = RemoteAuthenticationCoordinator()
    @State private var remote: String
    @State private var branch: String
    @State private var error = ""

    init(store: RepositoryStore, prompt: FirstBranchPushPrompt, close: @escaping () -> Void) {
        self.store = store; self.prompt = prompt; self.close = close
        _remote = State(initialValue: prompt.request.remotes.contains("origin") ? "origin" : prompt.request.remotes.first ?? "")
        _branch = State(initialValue: prompt.request.branch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(networkText("firstPushTitle")).font(.title3.weight(.semibold))
            Text(networkText("firstPushHint")).font(.callout).foregroundStyle(.secondary)
            Text(prompt.request.branch).font(.system(.body, design: .monospaced))
            if prompt.request.remotes.isEmpty {
                Text(panelText("No configured remotes")).foregroundStyle(.orange)
            } else {
                Picker(workflowText("Remote name"), selection: $remote) {
                    ForEach(prompt.request.remotes, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    StableTextField(sidebarRefinementText("Remote Branch"), text: $branch).textFieldStyle(.roundedBorder)
                    Menu(networkText("chooseExistingBranch")) {
                        ForEach(prompt.request.remoteBranches.filter { $0.name.hasPrefix(remote + "/") }) { item in
                            let name = String(item.name.dropFirst(remote.count + 1))
                            Button(name) { branch = name }
                        }
                    }.fixedSize()
                }
                Text(networkText("firstPushDestination") + " " + remote + "/" + branch).font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                DialogButton(networkText("cancel"), role: .cancel, action: close).disabled(store.isBusy)
                DialogButton(networkText("executePush"), prominent: true) { push() }
                    .disabled(store.isBusy || remote.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 490)
        .interactiveDismissDisabled(store.isBusy)
        .onChange(of: store.repositoryURL) { _, _ in authentication.cancel(); close() }
        .onDisappear { authentication.cancel() }
        .auvGitSheet(item: $authentication.request, focusesOnPresentation: false) { request in
            RemoteAuthenticationSheet(request: request, error: authentication.submissionError, isSubmitting: authentication.isSubmitting,
                submit: { authentication.submit($0) }, cancel: { authentication.cancel() })
        }
    }

    private func push(credential supplied: NetworkCredential? = nil, save: Bool = false) {
        let repository = prompt.repository, selectedRemote = remote
        let selectedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.repository === repository, !store.isBusy else { return }
        Task { @MainActor in
            let credential: NetworkCredential?
            if let supplied { credential = supplied }
            else { credential = await authentication.savedCredential(for: repository, operation: .push, remoteName: selectedRemote) }
            guard store.repository === repository, !store.isBusy else { return }
            error = ""
            store.operation("Push", onFailure: { failure in
                error = OperationFailure.message(failure, repository: repository.url)
                Task { @MainActor in
                    guard store.repository === repository else { return }
                    _ = await authentication.presentIfNeeded(error: failure, repository: repository, operation: .push, remoteName: selectedRemote) { retry in
                        push(credential: retry.credential, save: retry.saveCredential)
                    }
                }
            }) { active in
                try await authentication.perform(with: credential) {
                    try await active.pushFirstBranch(prompt.request, remote: selectedRemote, remoteBranch: selectedBranch, credential: credential)
                }
                if save, let credential {
                    do { try await authentication.save(credential, for: active, operation: .push, remoteName: selectedRemote) }
                    catch { store.report(error) }
                }
                close()
            }
        }
    }
}
