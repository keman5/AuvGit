import SwiftUI
import GitCore
import RayGitLocalization

func forcePushText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "ForcePush", arguments: arguments)
}

struct ForcePushPrompt: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let preview: ForcePushPreview
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
            }
        }.padding(24).frame(width: 490).onExitCommand(perform: cancel)
    }
}
