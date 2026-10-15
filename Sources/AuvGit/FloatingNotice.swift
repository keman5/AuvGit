import AppKit
import SwiftUI
import AuvGitLocalization

func noticeText(_ key: String) -> String { L10n.text(key, table: "FloatingNotice") }

/// Keeps limitations discoverable without changing the editor's layout.
struct FloatingNotice: View {
    let message: String
    var guidance: String = ""
    var command: String? = nil
    var actions: [(title: String, action: () -> Void)] = []
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(message).accessibilityLabel(message)
            .auvGitPopover(isPresented: $expanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).fontWeight(.semibold).textSelection(.enabled)
                    if !guidance.isEmpty { Text(guidance).textSelection(.enabled) }
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].title) { expanded = false; actions[index].action() }
                    }
                    if let command {
                        Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button(noticeText("Copy command")) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                        }
                        Text(noticeText("Copying does not execute this command.")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack { Spacer(); Button(noticeText("Close")) { expanded = false } }
                }.padding(16).frame(width: 360)
            }
            .onChange(of: message) { _, _ in expanded = true }
            .onAppear { expanded = true }
    }
}
