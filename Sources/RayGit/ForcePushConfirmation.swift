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

struct PullResultNotice: Identifiable {
    let id = UUID()
    let message: String
    init(outcome: PullOperationOutcome) {
        var parts: [String] = []
        if !outcome.conflicts.isEmpty {
            parts.append(L10n.text("pullConflicts", table: "Network", arguments: [outcome.conflicts.count]))
            parts.append(outcome.conflicts.prefix(8).joined(separator: "\n"))
        }
        if let stash = outcome.stashHash {
            parts.append(L10n.text("pullSavedChanges", table: "Network", arguments: [String(stash.prefix(12))]))
            parts.append(networkText(outcome.changesRestored ? "pullChangesRestored" : "pullChangesRetained"))
        }
        if let error = outcome.restorationError { parts.append(error) }
        message = parts.joined(separator: "\n\n")
    }
    init(error: Error) {
        if let recovery = error as? PullRecoveryFailure {
            message = GitCommandLog.redact(recovery.message) + "\n\n" +
                L10n.text("pullSavedChanges", table: "Network", arguments: [String(recovery.stashHash.prefix(12))]) +
                "\n\n" + networkText("pullChangesRetained")
        } else { message = GitCommandLog.redact(error.localizedDescription) }
    }
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
                DialogButton(L10n.text("cancel", table: "Network"), role: .cancel, action: cancel)
                DialogButton(L10n.text("pull", table: "Network"), prominent: true) { execute(.pull) }
                DialogButton(L10n.text("fetch", table: "Network")) { execute(.fetch) }
                Spacer()
            }.buttonStyle(RayGitDialogButtonStyle())
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
                DialogButton(forcePushText("cancel"), prominent: true, role: .cancel, action: cancel)
                DialogButton(forcePushText("action"), role: .destructive, action: execute)
                Spacer()
            }.buttonStyle(RayGitDialogButtonStyle())
        }.padding(24).frame(width: 360).onExitCommand(perform: cancel)
    }
}
