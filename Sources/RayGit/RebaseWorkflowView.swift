import SwiftUI
import GitCore

struct RebaseWorkflowView: View {
    @ObservedObject var store: RepositoryStore
    var onClose: (() -> Void)? = nil
    @State private var base = "HEAD~1"
    @State private var captured: RebasePlan?
    @State private var todo = ""
    @State private var messageSelection: String?
    @State private var messages: [String: String] = [:]
    @State private var originalMessages: [String: String] = [:]
    @State private var output = ""
    @State private var confirm = false
    @State private var pending: PendingRebase?
    @State private var editingRequest = UUID()
    @State private var loadRequest = UUID()
    struct MessageTarget: Identifiable { let line: Int; let command: String; let hash: String; var id: String { hash } }
    struct PendingRebase { let repository: GitRepository; let plan: RebasePlan; let todo: String; let messages: [Int: String]; let exec: [String] }
    private var targets: [MessageTarget] {
        todo.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            let command = ["r":"reword", "s":"squash", "f":"fixup", "m":"merge"][fields[0]] ?? fields[0]
            if ["reword", "squash"].contains(command) { return MessageTarget(line: index, command: command, hash: fields[1]) }
            if ["fixup", "merge"].contains(command), fields.count >= 3, fields[1] == "-c" { return MessageTarget(line: index, command: command, hash: fields[2]) }
            return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sessionText("Base revision")).font(.callout)
                HStack(spacing: 8) {
                    TextField(sessionText("Base revision"), text: $base).textFieldStyle(.roundedBorder)
                        .disabled(store.isBusy)
                        .onChange(of: base) { _, _ in loadRequest = UUID(); captured = nil; todo = ""; messages = [:]; originalMessages = [:]; messageSelection = nil }
                    Button(sessionText("Load Git topology plan")) { load() }.disabled(store.isBusy || base.isEmpty)
                }
            }
            Text(sessionText("Rebase plan help")).font(.caption).foregroundStyle(.secondary)
            GroupBox(panelText("Rebase plan")) {
                if captured == nil {
                    VStack(spacing: 8) {
                        if store.isBusy { ProgressView().controlSize(.small) }
                        Text(panelText("Load a base revision to edit its rebase plan.")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $todo).font(.system(size: 12, design: .monospaced)).disabled(store.isBusy)
                }
            }.frame(minHeight: 140, maxHeight: .infinity)
            if !targets.isEmpty {
                HSplitView {
                    List(targets, selection: $messageSelection) { target in Text(target.command + " " + String(target.hash.prefix(12))).tag(target.hash) }
                        .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sessionText("Complete commit message")).font(.callout)
                        TextEditor(text: Binding(get: { messageSelection.flatMap { messages[$0] ?? originalMessages[$0] } ?? "" }, set: { if let key = messageSelection { messages[key] = $0 } }))
                            .font(.system(size: 12)).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                    }.padding(.leading, 8).disabled(messageSelection == nil || store.isBusy)
                }.frame(height: 120)
            }
            if !output.isEmpty {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 88)
            }
            Divider()
            HStack(spacing: 8) {
                if store.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let onClose {
                    Button(workflowText("Close"), action: onClose).keyboardShortcut(.cancelAction).disabled(store.isBusy)
                }
                Button(sessionText("Preview and run rebase")) { prepare() }.buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || captured == nil || todo.isEmpty)
            }
        }.controlSize(.small).onChange(of: messageSelection) { _, _ in loadMessage() }
        .sheet(isPresented: $confirm, onDismiss: { pending = nil }) { preview }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sessionText("Confirm rebase and commands")).font(.title2.weight(.semibold))
            if let pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.repository.url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(sessionText("Base revision") + ": " + pending.plan.base).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(sessionText("Original HEAD") + ": " + pending.plan.head).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox(panelText("Rebase plan")) { Text(pending.todo).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                        GroupBox(sessionText("Explicit exec commands")) {
                            Text(pending.exec.isEmpty ? sessionText("No exec commands") : pending.exec.joined(separator: "\n"))
                                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        ForEach(pending.messages.keys.sorted(), id: \.self) { line in
                            GroupBox(sessionText("Complete commit message") + " [" + String(line + 1) + "]") {
                                Text(pending.messages[line] ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(sessionText("Cancel")) { confirm = false; pending = nil }.keyboardShortcut(.cancelAction)
                Button(sessionText("Run confirmed plan")) { if let request = pending { confirm = false; pending = nil; run(request) } }.buttonStyle(.borderedProminent)
            }
        }.controlSize(.small).padding(20).frame(width: 800, height: 600)
    }

    private func load() {
        guard let repo = store.repository, !store.isBusy else { return }; let revision = base; let token = UUID(); loadRequest = token
        store.isBusy = true; captured = nil; messages = [:]; originalMessages = [:]; messageSelection = nil
        Task { do { let result = try await repo.generatedRebasePlan(onto: revision); if store.repositoryURL == repo.url, base == revision, loadRequest == token { captured = result; todo = result.todo; output = "" } } catch { output = error.localizedDescription }; store.isBusy = false }
    }
    private func loadMessage() {
        let token = UUID(); editingRequest = token
        guard let key = messageSelection, messages[key] == nil, originalMessages[key] == nil, let repo = store.repository else { return }
        Task { do { let hash = try await repo.workflowRevision(key); let message = try await repo.workflowRead(["show", "-s", "--format=%B", hash]); if editingRequest == token, messageSelection == key, messages[key] == nil { originalMessages[key] = message } } catch { if editingRequest == token { output = error.localizedDescription } } }
    }
    private func prepare() {
        guard let repo = store.repository, let plan = captured, !store.isBusy else { return }
        let edited = todo, saved = messages, sourceTargets = targets
        store.isBusy = true
        Task {
            do {
                let instructions = try await repo.validateRebasePlan(base: plan.base, plan: edited, allowExec: true)
                var editedMessages: [Int: String] = [:]
                for target in sourceTargets { if let message = saved[target.hash] { editedMessages[target.line] = message } }
                guard store.repositoryURL == repo.url, captured?.head == plan.head, todo == edited else { throw GitError("Rebase selection changed; preview again") }
                pending = PendingRebase(repository: repo, plan: plan, todo: edited, messages: editedMessages, exec: instructions.filter { $0.command == "exec" }.map(\.argument)); confirm = true
            } catch { output = error.localizedDescription }
            store.isBusy = false
        }
    }
    private func run(_ request: PendingRebase) {
        guard store.repositoryURL == request.repository.url, !store.isBusy else { return }; store.isBusy = true
        Task { do { output = try await request.repository.executeRebase(plan: request.plan, editedTodo: request.todo, messages: request.messages, allowExec: true); if output.isEmpty { output = sessionText("Rebase completed or paused") } } catch { output = error.localizedDescription }; store.isBusy = false; await store.refresh() }
    }
}
