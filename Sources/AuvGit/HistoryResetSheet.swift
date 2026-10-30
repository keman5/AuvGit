import SwiftUI
import GitCore
import AuvGitLocalization

struct HistoryResetRequest: Identifiable {
    let id = UUID()
    let commit: GitCommit
    let repositoryURL: URL
    let advanced: Bool
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
            if let context { Text(context.reference).font(.caption).foregroundStyle(.secondary) }
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
                    guard let context, store.repositoryURL == request.repositoryURL, !store.isBusy else { return }
                    let selectedMode = request.advanced ? mode : .hard
                    store.operation(historyActionText(request.advanced ? "resetAdvanced" : "reset")) { repository in
                        _ = try await repository.reset(to: request.commit.hash, mode: selectedMode, expected: context)
                    }
                    dismiss()
                }.disabled(context == nil || store.isBusy || store.repositoryURL != request.repositoryURL)
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(22).frame(width: 360)
        .task {
            guard let repository = store.repository, repository.url == request.repositoryURL else { return }
            do { context = try await repository.resetContext() } catch { self.error = GitFailureSummary.message(for: error.localizedDescription, localize: { L10n.text($0, table: "OperationLog") }) ?? GitCommandLog.redact(error.localizedDescription) }
        }
    }
}
