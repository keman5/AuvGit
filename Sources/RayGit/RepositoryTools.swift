import SwiftUI
import GitCore
import RayGitLocalization

func workflowText(_ key: String) -> String { L10n.text(key, table: "Workflow") }

struct RepositoryTools: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = RepositoryWorkflow.compare
    @State private var first = "HEAD~1"
    @State private var second = "HEAD"
    @State private var output = ""
    @State private var busy = false
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(workflowText("Repository Tools")).font(.title2); Spacer(); Button(workflowText("Close")) { dismiss() }.disabled(busy) }
            Picker(workflowText("Operation"), selection: $operation) {
                ForEach(RepositoryWorkflow.allCases) { item in Text(workflowText(item.rawValue)).tag(item) }
            }.onChange(of: operation) { _, _ in output = ""; first = ""; second = "" }
            Text(workflowText(operation.rawValue + ".help")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField(workflowText("First value"), text: $first).textFieldStyle(.roundedBorder)
            TextField(workflowText("Second value"), text: $second).textFieldStyle(.roundedBorder)
            if operation == .partialStash { TextEditor(text: $first).font(.system(.caption, design: .monospaced)).frame(height: 90) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button(workflowText(operation.writes ? "Run change…" : "Read")) { if operation.writes { confirm = true } else { run() } }.disabled(busy || store.isBusy || store.repository == nil) }
            Divider()
            ScrollView([.vertical, .horizontal]) { Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(width: 850, height: 650)
        .alert(workflowText("Confirm repository change"), isPresented: $confirm) { Button(workflowText("Cancel"), role: .cancel) {}; Button(workflowText("Continue"), role: operation == .resetHard ? .destructive : nil) { run() } } message: { Text(workflowText(operation.rawValue) + "\n" + first + "\n" + second + "\n" + workflowText(operation.rawValue + ".help")) }
    }
    private func run() {
        guard let repository = store.repository else { return }
        let op = operation, a = first, b = second
        busy = true; output = ""
        Task {
            do { output = try await repository.advancedOperation(op, first: a, second: b); if output.isEmpty { output = workflowText("Completed") }; if op.writes { await store.refresh() } }
            catch { output = error.localizedDescription }
            busy = false
        }
    }
}

struct CreateRepositorySheet: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var clone = false
    @State private var source = ""
    @State private var destination = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workflowText("Create Repository")).font(.headline)
            Toggle(workflowText("Clone existing repository"), isOn: $clone)
            if clone { TextField(workflowText("Clone URL or local path"), text: $source) }
            HStack { TextField(workflowText("Destination folder"), text: $destination); Button(workflowText("Choose…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; if panel.runModal() == .OK { destination = panel.url?.path ?? "" } } }
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button(workflowText("Cancel")) { dismiss() }.disabled(busy); Button(workflowText("Create")) { create() }.disabled(busy || destination.isEmpty || (clone && source.isEmpty)) }
        }.padding(24).frame(width: 600)
    }
    private func create() {
        busy = true
        Task {
            do { let url = URL(fileURLWithPath: destination); let repo = try await clone ? GitRepository.clone(source: source, destination: url) : GitRepository.initialize(at: url); await store.open(repo.url); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
