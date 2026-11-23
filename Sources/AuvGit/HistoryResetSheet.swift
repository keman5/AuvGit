import SwiftUI
import GitCore
import AuvGitLocalization

struct HistoryResetRequest: Identifiable {
    let id = UUID()
    let commit: GitCommit
    let repositoryURL: URL
    let advanced: Bool
}

@MainActor
extension RepositoryStore {
    func historyResetRequest(advanced: Bool) async throws -> HistoryResetRequest? {
        guard let repository, !isBusy else { return nil }
        // Menu and toolbar clicks can move focus without changing the selected commit.
        let commit: GitCommit?
        if let selectedCommit, !historyVirtualRows.contains(where: { $0.id == selectedCommit }) {
            if let selected = commits.first(where: { $0.hash == selectedCommit }) {
                commit = selected
            } else {
                commit = try await repository.log(limit: 1, ref: selectedCommit).first
            }
        } else {
            commit = try await repository.log(limit: 1, ref: "HEAD").first
        }
        guard let commit, self.repository === repository, !isBusy else { return nil }
        return HistoryResetRequest(commit: commit, repositoryURL: repository.url, advanced: advanced)
    }

    func startHistoryReset(_ request: HistoryResetRequest, mode: GitResetMode, context: GitResetContext) throws {
        guard repository?.url == request.repositoryURL, context.repositoryURL == request.repositoryURL else {
            throw GitError("Repository or HEAD changed. Reopen the reset confirmation.")
        }
        if let workspaceStatusFailure { throw GitError(workspaceStatusFailure) }
        let started = operation(historyActionText(request.advanced ? "resetAdvanced" : "reset"), waitForBackgroundSync: false) { repository in
            _ = try await repository.reset(to: request.commit.hash, mode: mode, expected: context)
        }
        guard started else { throw GitError(L10n.text("busy", table: "HistoryReset")) }
    }
}

struct HistoryResetSheet: View {
    @ObservedObject var store: RepositoryStore
    let request: HistoryResetRequest
    @Environment(\.dismiss) private var dismiss
    @State private var mode = GitResetMode.mixed
    @State private var context: GitResetContext?
    @State private var error: String?
    private func text(_ key: String) -> String { L10n.text(key, table: "HistoryReset") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(historyActionText(request.advanced ? "resetAdvanced" : "reset")).font(.title3.weight(.semibold))
            Text(request.commit.subject).lineLimit(3)
            Text(request.commit.hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let context {
                Text(context.reference).font(.caption).foregroundStyle(.secondary)
            } else if error == nil {
                ProgressView(text("checking")).controlSize(.small).font(.caption)
            }
            if request.advanced {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("mode"))
                    ForEach(GitResetMode.allCases, id: \.self) { option in
                        KeyViewProxy(label: text(option.rawValue), checked: mode == option, radio: true) {
                            mode = option
                        }
                    }
                }
            }
            Text(text((request.advanced ? mode : .hard).rawValue + "Message")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                DialogButton(workflowText("Cancel"), prominent: (request.advanced ? mode : .hard) == .hard, role: .cancel) { dismiss() }
                DialogButton(text("confirm"), prominent: (request.advanced ? mode : .hard) != .hard, role: (request.advanced ? mode : .hard) == .hard ? .destructive : nil) {
                    guard let context else { return }
                    do {
                        try store.startHistoryReset(request, mode: request.advanced ? mode : .hard, context: context)
                        dismiss()
                    } catch {
                        self.error = OperationFailure.display(error.localizedDescription)
                    }
                }.disabled(context == nil)
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(22).frame(width: 360)
        .task {
            do {
                guard let repository = store.repository, repository.url == request.repositoryURL else {
                    throw GitError("Repository or HEAD changed. Reopen the reset confirmation.")
                }
                context = try await repository.resetContext()
            } catch {
                self.error = OperationFailure.display(error.localizedDescription)
            }
        }
    }
}
