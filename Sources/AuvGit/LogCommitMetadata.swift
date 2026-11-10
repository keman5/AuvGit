import SwiftUI
import GitCore

/// Keep metadata in compact rows so the changed-file list has room to breathe.
struct LogCommitMetadata: View {
    let commit: GitCommit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text(commit.subject)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                CommitIdentityDetails(commit: commit, compact: true)
                HStack(spacing: 10) {
                    Text(commit.hash).lineLimit(1).truncationMode(.middle)
                        .help(commit.hash).layoutPriority(1)
                    if !commit.parents.isEmpty {
                        Text(logText("Parents") + ": " + commit.parents.map { String($0.prefix(8)) }.joined(separator: ", "))
                            .lineLimit(1).truncationMode(.middle)
                            .help(logText("Parents") + ": " + commit.parents.joined(separator: ", "))
                    }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                let message = LogCommitMessage.body(commit)
                if !message.isEmpty {
                    Divider()
                    Text(message).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(logText("Commit"))
    }
}
