import SwiftUI
import GitCore
import RayGitLocalization

func forcePushText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "ForcePush", arguments: arguments)
}

func networkPreflightMessage(_ hint: LocalNetworkPreflight) -> String {
    switch hint {
    case let .pushBehind(preview):
        return L10n.text("knownPushBehind", table: "Network", arguments: [preview.remote, String(preview.remoteBranch.dropFirst("refs/heads/".count)), preview.remoteOnlyCount ?? 0])
    case let .pullDiverged(remoteOnly, localOnly):
        return L10n.text("knownPullDiverged", table: "Network", arguments: [localOnly, remoteOnly])
    }
}

struct NetworkPreflightPrompt: Identifiable {
    let id = UUID()
    let operation: NetworkOperation
    let repository: GitRepository
    let hint: LocalNetworkPreflight
}
struct PullOperationPrompt: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let hint: LocalNetworkPreflight?
}

struct PullOperationConfirmation: View {
    let hint: LocalNetworkPreflight?
    let cancel: () -> Void
    let execute: (NetworkOperation) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("pullTitle", table: "Main")).font(.headline)
            Text(hint.map(networkPreflightMessage) ?? L10n.text("pullMessage", table: "Main"))
            HStack {
                Spacer()
                Button(L10n.text("cancel", table: "Network"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.text("pull", table: "Network")) { execute(.pull) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                Button(L10n.text("fetch", table: "Network")) { execute(.fetch) }
                Spacer()
            }
        }.padding(24).frame(width: 360)
    }
}

struct ForcePushPrompt: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let preview: ForcePushPreview
    let credential: NetworkCredential?
    let saveCredential: Bool

    init(repository: GitRepository, preview: ForcePushPreview,
         credential: NetworkCredential? = nil, saveCredential: Bool = false) {
        self.repository = repository
        self.preview = preview
        self.credential = credential
        self.saveCredential = saveCredential
    }
}

struct ForcePushConfirmation: View {
    let preview: ForcePushPreview
    let cancel: () -> Void
    let execute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(forcePushText("title")).font(.headline)
            Text(forcePushText("target", preview.remote, preview.remoteBranch)).textSelection(.enabled)
            Text(preview.remoteOnlyCount.map { forcePushText("count", $0) } ?? forcePushText("unknownCount"))
            Text(forcePushText("explanation")).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(forcePushText("cancel"), action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button(forcePushText("action"), role: .destructive, action: execute)
                Spacer()
            }
        }.padding(24).frame(width: 360).onExitCommand(perform: cancel)
    }
}
