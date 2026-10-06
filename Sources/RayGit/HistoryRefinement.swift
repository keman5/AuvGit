import SwiftUI
import GitCore
import RayGitLocalization

func historyRefinementText(_ key: String) -> String { L10n.text(key, table: "HistoryRefinement") }

struct HistoryDisplayMenu: View {
    var showMergedCommits: Binding<Bool>? = nil
    @AppStorage("history.showAuthorAvatars") private var avatars = true
    @AppStorage("history.showAuthorNames") private var names = true
    @AppStorage("history.showRemoteLabels") private var remoteLabels = true
    @AppStorage("history.showTagLabels") private var tagLabels = true
    var body: some View {
        Menu {
            if let showMergedCommits { Toggle(historyRefinementText("Show merged commits"), isOn: showMergedCommits); Divider() }
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
    @State private var image: NSImage?
    @State private var displayedURL: URL?
    private var avatarURL: URL? { CommitAvatarIdentity.url(email: email) }
    private var displayedImage: NSImage? {
        if displayedURL == avatarURL, let image { return image }
        return avatarURL.flatMap { CommitAvatarCache.shared.cachedImage(for: $0) }
    }
    var body: some View {
        Group {
            if let image = displayedImage { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
            .task(id: avatarURL) {
                guard let url = avatarURL else { image = nil; displayedURL = nil; return }
                if let cached = CommitAvatarCache.shared.cachedImage(for: url) { image = cached; displayedURL = url; return }
                image = nil; displayedURL = url
                let loaded = await CommitAvatarCache.shared.image(for: url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

struct CommitIdentityDetails: View {
    let commit: GitCommit
    @AppStorage("history.showAuthorAvatars") private var avatars = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity(name: commit.committer, email: commit.committerEmail, role: "Committer")
            Text(historyRefinementText("Commit date") + ": " + HistoryCalendarDate.text(commit.committedDate)).font(.caption).foregroundStyle(.secondary)
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
