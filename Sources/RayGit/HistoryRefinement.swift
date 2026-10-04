import SwiftUI
import GitCore
import RayGitLocalization

func historyRefinementText(_ key: String) -> String { L10n.text(key, table: "HistoryRefinement") }

struct HistoryDisplayMenu: View {
    @AppStorage("history.showAuthorAvatars") private var avatars = true
    @AppStorage("history.showAuthorNames") private var names = true
    @AppStorage("history.showRemoteLabels") private var remoteLabels = true
    @AppStorage("history.showTagLabels") private var tagLabels = true
    var body: some View {
        Menu {
            Toggle(historyRefinementText("Show author avatars"), isOn: $avatars)
            Toggle(historyRefinementText("Show author names"), isOn: $names)
            Toggle(historyRefinementText("Show remote branch labels"), isOn: $remoteLabels)
            Toggle(historyRefinementText("Show tag labels"), isOn: $tagLabels)
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
        }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            .help(historyRefinementText("History display options")).accessibilityLabel(historyRefinementText("History display options"))
    }
}

struct CommitAvatar: View {
    let email: String
    var size: CGFloat = 22
    var body: some View {
        AsyncImage(url: CommitAvatarIdentity.url(email: email), transaction: Transaction(animation: nil)) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
    }
}

struct CommitIdentityDetails: View {
    let commit: GitCommit
    @AppStorage("history.showAuthorAvatars") private var avatars = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity(name: commit.author, email: commit.authorEmail, role: "Author")
            Text(historyRefinementText("Author date") + ": " + preferencesDate(commit.date)).font(.caption).foregroundStyle(.secondary)
            identity(name: commit.committer, email: commit.committerEmail, role: "Committer")
            Text(historyRefinementText("Commit date") + ": " + preferencesDate(commit.committedDate)).font(.caption).foregroundStyle(.secondary)
                .help(commit.committedDate == commit.date ? "" : historyRefinementText("Different dates may reflect history rewriting or importing; they do not identify a specific operation."))
        }.textSelection(.enabled)
    }
    private func identity(name: String, email: String, role: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if avatars { CommitAvatar(email: email, size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(historyRefinementText(role) + ": " + name).font(.caption).fontWeight(.medium)
                if !email.isEmpty { Text(email).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
