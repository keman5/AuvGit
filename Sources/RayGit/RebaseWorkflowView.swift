import SwiftUI
import GitCore

struct RebaseWorkflowView: View {
    @ObservedObject var store: RepositoryStore
    var onClose: (() -> Void)? = nil
    @State private var base = "HEAD~1"
    init(store: RepositoryStore, onClose: (() -> Void)? = nil, initialBase: String = "HEAD~1") {
        self.store = store; self.onClose = onClose; _base = State(initialValue: initialBase)
    }
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
    @State private var execCommand = ""
    @State private var metadata: [String: CommitMetadata] = [:]
    struct CommitMetadata { let author: String; let date: Date }
    struct PlanRow: Identifiable {
        let line: Int; let command: String; let hash: String?; let subject: String
        var id: Int { line }
    }
    private var planRows: [PlanRow] {
        todo.components(separatedBy: "\n").enumerated().compactMap { line, text in
            let fields = text.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = fields.first, !first.hasPrefix("#") else { return nil }
            let command = ["p":"pick", "r":"reword", "s":"squash", "f":"fixup", "e":"edit", "d":"drop", "x":"exec"][first] ?? first
            let simple = ["pick", "reword", "squash", "fixup", "edit", "drop"].contains(command) && fields.count > 1 && !fields[1].hasPrefix("-")
            return PlanRow(line: line, command: command, hash: simple ? fields[1] : nil, subject: simple ? (fields.count > 2 ? fields[2] : "") : fields.dropFirst().joined(separator: " "))
        }
    }
    private var selectedRow: PlanRow? { planRows.first { $0.hash == messageSelection && messageSelection != nil } }
    private var canEditMessage: Bool { targets.contains { $0.hash == messageSelection } }

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
        VStack(alignment: .leading, spacing: 16) {
            DesignPageHeading(title: designText("Interactive Rebase"), subtitle: sessionText("Rebase plan help"), icon: "arrow.triangle.branch")
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(designText("Current branch")).font(.system(size: 13, weight: .semibold))
                    Label(store.branch.isEmpty ? "HEAD" : store.branch, systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 8) {
                    Text(sessionText("Base revision")).font(.system(size: 13, weight: .semibold))
                    HStack {
                        StableTextField(sessionText("Base revision"), text: $base).textFieldStyle(.roundedBorder)
                            .onChange(of: base) { _, _ in loadRequest = UUID(); captured = nil; todo = ""; messages = [:]; originalMessages = [:]; metadata = [:]; messageSelection = nil }
                        Menu {
                            Button("HEAD") { base = "HEAD" }
                            ForEach(store.branches.filter { !$0.isRemote }, id: \.name) { branch in Button(branch.name) { base = branch.name } }
                        } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 5)
                }
                Button(sessionText("Load Git topology plan")) { load() }.disabled(base.isEmpty).padding(.bottom, 5)
            }.disabled(store.isBusy)
            DesignCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(designText("Commit list, oldest first"), systemImage: "list.bullet").font(.system(size: 14, weight: .semibold))
                        DesignActionChip(title: "\(planRows.filter { $0.hash != nil }.count)")
                        Spacer()
                    }
                    Divider()
                    if captured == nil {
                        VStack(spacing: 10) {
                            if store.isBusy { ProgressView().controlSize(.small) }
                            Text(panelText("Load a base revision to edit its rebase plan.")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 135)
                    } else {
                        HStack {
                            Text(designText("Action")).padding(.leading, 24).frame(width: 142, alignment: .leading)
                            Text(workflowText("Commit hash")).frame(width: 100, alignment: .leading)
                            Text(designText("Commit message")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(designText("Author")).frame(width: 110, alignment: .leading)
                            Text(designText("Date")).frame(width: 125, alignment: .leading)
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(planRows) { row in
                                    HStack(spacing: 12) {
                                        VStack(spacing: 2) {
                                            Button { moveRow(row.line, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(row.line == 0)
                                            Button { moveRow(row.line, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(row.line >= todo.components(separatedBy: "\n").count - 1)
                                        }.buttonStyle(.plain).font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 12)
                                        if row.hash != nil {
                                            Picker(designText("Action"), selection: Binding(get: { row.command }, set: { setCommand($0, line: row.line) })) {
                                                ForEach(["pick", "reword", "squash", "fixup", "edit", "drop"], id: \.self) { Text($0).tag($0) }
                                            }.labelsHidden().tint(actionColor(row.command)).frame(width: 118)
                                                .background(actionColor(row.command).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                                        } else { DesignActionChip(title: row.command, color: actionColor(row.command)).frame(width: 118, alignment: .leading) }
                                        Text(row.hash.map { String($0.prefix(8)) } ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                                        Text(row.subject).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(rowMetadata(row)?.author ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                                        Text(rowMetadata(row).map { preferencesDate($0.date, style: "relative") } ?? "").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 125, alignment: .leading)
                                    }.padding(.horizontal, 8).padding(.vertical, 9)
                                        .background(row.hash != nil && messageSelection == row.hash ? Color.blue.opacity(0.13) : Color.clear)
                                        .contentShape(Rectangle()).onTapGesture { if let hash = row.hash { messageSelection = hash } }
                                    Divider()
                                }
                            }
                        }.frame(minHeight: 130, maxHeight: 250)
                        DisclosureGroup(designText("Edit complete Git plan")) {
                            TextEditor(text: $todo).font(.system(size: 12, design: .monospaced)).frame(height: 120)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(store.isBusy)
            HStack(alignment: .top, spacing: 16) {
                DesignCard(designText("Commit message preview")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !targets.isEmpty {
                            Picker(sessionText("Complete commit message"), selection: $messageSelection) {
                                Text(designText("Select a commit to preview its message")).tag(Optional<String>.none)
                                ForEach(targets) { target in Text(target.command + " " + String(target.hash.prefix(12))).tag(Optional(target.hash)) }
                            }.labelsHidden()
                        }
                        if let selectedRow {
                            HStack {
                                Text((selectedRow.hash.map { String($0.prefix(8)) } ?? "") + "  " + selectedRow.subject).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                DesignActionChip(title: selectedRow.command, color: actionColor(selectedRow.command))
                            }
                        }
                        if messageSelection == nil {
                            Text(designText("Select a commit to preview its message")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                        } else {
                            TextEditor(text: Binding(get: { messageSelection.flatMap { messages[$0] ?? originalMessages[$0] } ?? "" }, set: { if canEditMessage, let key = messageSelection { messages[key] = $0 } }))
                                .font(.system(size: 12)).frame(height: 160).disabled(!canEditMessage || store.isBusy)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
                            Text(designText(canEditMessage ? "This message will be included in the confirmed plan" : "Choose reword or squash to edit this message")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    DesignCard(sessionText("Explicit exec commands")) {
                        HStack(spacing: 8) {
                            StableTextField(designText("Command to insert in the plan"), text: $execCommand).textFieldStyle(.roundedBorder)
                            Button { insertExec() } label: { Image(systemName: "plus") }.help(designText("Add exec command"))
                                .disabled(execCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || captured == nil || store.isBusy)
                        }
                    }
                    DesignCard(designText("Planned commits")) {
                        ScrollView {
                            VStack(spacing: 9) {
                                ForEach(planRows.filter { $0.command != "drop" }) { row in
                                    HStack(spacing: 9) {
                                        Circle().fill(Color.blue).frame(width: 7, height: 7)
                                        Text(row.hash.map { String($0.prefix(8)) } ?? "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                        Text(row.subject).font(.system(size: 11)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        DesignActionChip(title: row.command, color: actionColor(row.command))
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 120)
                    }
                }.frame(maxWidth: .infinity)
            }
            if !output.isEmpty {
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
            }
            Label(designText("Rebase rewrites commit history and may change commit IDs"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 10) {
                if store.isBusy { ProgressView().controlSize(.small) }
                if let onClose { Button(workflowText("Close"), action: onClose).keyboardShortcut(.cancelAction).disabled(store.isBusy) }
                Button(sessionText("Preview and run rebase")) { prepare() }.buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || captured == nil || todo.isEmpty)
            }.frame(maxWidth: .infinity)
        }.tint(.blue).controlSize(.regular).padding(20)
            .onChange(of: messageSelection) { _, _ in loadMessage() }
            .rayGitSheet(isPresented: $confirm, onDismiss: { pending = nil }) { preview }
    }
    private func actionColor(_ command: String) -> Color {
        switch command { case "reword": return .orange; case "squash": return .purple; case "edit": return .yellow; case "drop": return .red; case "exec": return .secondary; default: return .blue }
    }
    private func rowMetadata(_ row: PlanRow) -> CommitMetadata? {
        guard let hash = row.hash else { return nil }; return metadata.first { $0.key.hasPrefix(hash) }?.value
    }
    private func setCommand(_ command: String, line: Int) {
        var lines = todo.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let suffix = lines[line].drop(while: { $0.isWhitespace }).drop(while: { !$0.isWhitespace })
        lines[line] = command + String(suffix); todo = lines.joined(separator: "\n")
    }
    private func moveRow(_ line: Int, by offset: Int) {
        guard !store.isBusy else { return }
        var lines = todo.components(separatedBy: "\n")
        let target = line + offset
        guard lines.indices.contains(line), lines.indices.contains(target), !lines[target].trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lines.swapAt(line, target); todo = lines.joined(separator: "\n")
    }
    private func insertExec() {
        let command = execCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard captured != nil, !store.isBusy, !command.isEmpty, !command.contains("\n"), !command.contains("\r") else { return }
        var lines = todo.components(separatedBy: "\n")
        if let selectedRow { lines.insert("exec " + command, at: selectedRow.line + 1) }
        else { if lines.last == "" { lines.removeLast() }; lines.append("exec " + command); lines.append("") }
        todo = lines.joined(separator: "\n"); execCommand = ""
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
                Button(sessionText("Cancel")) { confirm = false; pending = nil }.keyboardShortcut(.cancelAction)
                Button(sessionText("Run confirmed plan")) { if let request = pending { confirm = false; pending = nil; run(request) } }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity)
        }.controlSize(.small).padding(20).frame(width: 800, height: 600)
    }

    private func load() {
        guard let repo = store.repository, !store.isBusy else { return }; let revision = base; let token = UUID(); loadRequest = token
        store.isBusy = true; captured = nil; messages = [:]; originalMessages = [:]; messageSelection = nil
        Task {
            await store.cancelBackgroundRepositorySync()
            do { let result = try await repo.generatedRebasePlan(onto: revision); if store.repositoryURL == repo.url, base == revision, loadRequest == token { captured = result; todo = result.todo; output = ""
                    if let info = try? await repo.workflowRead(["log", "--format=%H%x00%an%x00%at", result.base + ".." + result.head]), store.repositoryURL == repo.url, loadRequest == token {
                        metadata = Dictionary(uniqueKeysWithValues: info.split(separator: "\n").compactMap { row in
                            let fields = row.split(separator: "\0").map(String.init)
                            guard fields.count == 3, let seconds = Double(fields[2]) else { return nil }
                            return (fields[0], CommitMetadata(author: fields[1], date: Date(timeIntervalSince1970: seconds)))
                        })
                    } } } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false }
    }
    private func loadMessage() {
        let token = UUID(); editingRequest = token
        guard let key = messageSelection, messages[key] == nil, originalMessages[key] == nil, let repo = store.repository else { return }
        Task { do { let hash = try await repo.workflowRevision(key); let message = try await repo.workflowRead(["show", "-s", "--format=%B", hash]); if editingRequest == token, messageSelection == key, messages[key] == nil { originalMessages[key] = message } } catch { if editingRequest == token { output = OperationFailure.message(error, repository: store.repositoryURL) } } }
    }
    private func prepare() {
        guard let repo = store.repository, let plan = captured, !store.isBusy else { return }
        let edited = todo, saved = messages, sourceTargets = targets
        store.isBusy = true
        Task {
            await store.cancelBackgroundRepositorySync()
            do {
                let instructions = try await repo.validateRebasePlan(base: plan.base, plan: edited, allowExec: true)
                var editedMessages: [Int: String] = [:]
                for target in sourceTargets { if let message = saved[target.hash] { editedMessages[target.line] = message } }
                guard store.repositoryURL == repo.url, captured?.head == plan.head, todo == edited else { throw GitError("Rebase selection changed; preview again") }
                pending = PendingRebase(repository: repo, plan: plan, todo: edited, messages: editedMessages, exec: instructions.filter { $0.command == "exec" }.map(\.argument)); confirm = true
            } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }
            store.isBusy = false
        }
    }
    private func run(_ request: PendingRebase) {
        guard store.repositoryURL == request.repository.url, !store.isBusy else { return }; store.isBusy = true
        Task {
            await store.cancelBackgroundRepositorySync()
            do { output = try await request.repository.executeRebase(plan: request.plan, editedTodo: request.todo, messages: request.messages, allowExec: true); if output.isEmpty { output = sessionText("Rebase completed or paused") } } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }; store.isBusy = false; await store.refresh() }
    }
}
