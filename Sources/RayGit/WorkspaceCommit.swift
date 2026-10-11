import SwiftUI
import GitCore
import RayGitLocalization

struct WorkspaceCommitRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let message: String
    let hasTrackedChanges: Bool
}

extension RepositoryStore {
    var canCommit: Bool {
        repository != nil && workspaceStatusFailure == nil && pendingRepositoryPath == nil && !isBusy &&
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (amend || !files.isEmpty) && !files.contains(where: \.isConflict)
    }

    func commit(includeUntracked: Bool? = nil) {
        guard canCommit, let repository else { return }
        let message = commitMessage, amending = amend
        isBusy = true
        Task {
            do {
                let current = try await repository.status()
                guard self.repository === repository else { isBusy = false; return }
                isBusy = false
                guard !current.contains(where: \.isConflict) else {
                    throw GitError(workflowText("Resolve conflicts before committing."))
                }
                if !amending, !current.contains(where: \.isStaged),
                   includeUntracked == nil, current.contains(where: \.isUntracked) {
                    workspaceCommitRequest = WorkspaceCommitRequest(repository: repository, message: message,
                        hasTrackedChanges: current.contains { !$0.isUntracked && $0.isUnstaged })
                    return
                }
                operation(amending ? "修订提交" : "提交") { repo in
                    let latest = try await repo.status()
                    guard !latest.contains(where: \.isConflict) else {
                        throw GitError(workflowText("Resolve conflicts before committing."))
                    }
                    if !latest.contains(where: \.isStaged) {
                        let paths = latest.filter { $0.isUnstaged && (!$0.isUntracked || amending || includeUntracked == true) }.map(\.path)
                        if !paths.isEmpty { try await repo.stage(paths: paths) }
                    }
                    try await repo.commit(message: message, amend: amending)
                    self.recordSuccessfulCommitMessage(message, for: repo.url)
                    if self.repository === repo, self.commitMessage == message {
                        self.commitMessage = ""; self.amend = false
                    }
                }
            } catch { isBusy = false; report(error) }
        }
    }

    func confirmWorkspaceCommit(_ request: WorkspaceCommitRequest, includeUntracked: Bool) {
        workspaceCommitRequest = nil
        guard repository === request.repository, commitMessage == request.message, !amend else { return }
        commit(includeUntracked: includeUntracked)
    }

    func recordSuccessfulCommitMessage(_ message: String, for repositoryURL: URL) {
        commitHistory.record(message, for: repositoryURL)
        if self.repositoryURL == repositoryURL { recentCommitMessages = commitHistory.messages(for: repositoryURL) }
    }

    func clearRecentCommitMessages() {
        guard let repositoryURL else { return }
        commitHistory.clear(for: repositoryURL)
        recentCommitMessages = []
    }
}

struct WorkspaceCommitSheet: View {
    @ObservedObject var store: RepositoryStore
    let request: WorkspaceCommitRequest
    @Environment(\.dismiss) private var dismiss
    @State private var includeUntracked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workflowText("Commit workspace changes")).font(.headline)
            Text(workflowText("There are no staged files. All tracked changes will be staged and committed. Include untracked files too?"))
            Toggle(workflowText("Include untracked files"), isOn: $includeUntracked)
            HStack {
                Button(workflowText("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("commit", table: "Main")) {
                    store.confirmWorkspaceCommit(request, includeUntracked: includeUntracked)
                    dismiss()
                }.buttonStyle(RayGitDialogButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(!request.hasTrackedChanges && !includeUntracked)
            }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 360)
    }
}
