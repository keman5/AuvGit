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
    @State private var compared: (String, String)?
    @State private var pending: (GitRepository, RepositoryWorkflow, String, String)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(workflowText("Repository Tools")).font(.title2); Spacer(); Button(workflowText("Close")) { dismiss() }.disabled(busy) }
            Picker(workflowText("Operation"), selection: $operation) {
                Section(workflowText("Inspect")) { ForEach(RepositoryWorkflow.allCases.filter { !$0.writes }) { item in Text(workflowText(item.rawValue)).tag(item) } }
                Section(workflowText("Change")) { ForEach(RepositoryWorkflow.allCases.filter { $0.writes }) { item in Text(workflowText(item.rawValue)).tag(item) } }
            }.disabled(busy).onChange(of: operation) { _, _ in output = ""; compared = nil; first = operation == .compare ? "HEAD~1" : ""; second = operation == .compare || operation == .blame ? "HEAD" : "" }
            Text(workflowText(operation.rawValue + ".help")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !firstLabel.isEmpty, operation != .partialStash { TextField(workflowText(firstLabel), text: $first).textFieldStyle(.roundedBorder).disabled(busy) }
            if !secondLabel.isEmpty { TextField(workflowText(secondLabel), text: $second).textFieldStyle(.roundedBorder).disabled(busy) }
            if operation == .partialStash || operation == .interactiveRebase { TextEditor(text: operation == .interactiveRebase ? $second : $first).font(.system(.caption, design: .monospaced)).frame(height: operation == .interactiveRebase ? 180 : 90).disabled(busy) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button(workflowText(operation.writes ? "Run change…" : "Read")) { if operation.writes, let repo = store.repository { pending = (repo, operation, first, second); confirm = true } else if let repo = store.repository { run(repo, operation, first, second) } }.disabled(busy || store.isBusy || store.repository == nil || (!firstLabel.isEmpty && first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (operation == .partialStash && first.isEmpty) || (operation == .interactiveRebase && second.isEmpty)) }
            if operation == .interactiveRebase { Button(workflowText("Load rebase plan")) { loadPlan() }.disabled(busy || store.isBusy || first.isEmpty) }
            Divider()
            if operation == .compare, let refs = compared, let repo = store.repository { ReferenceChangesView(repository: repo, left: refs.0, right: refs.1).id(refs.0 + "\0" + refs.1) } else if operation == .compare { Text(output).textSelection(.enabled) } else if operation == .reflog || operation == .blame { HistoricalRecordsView(text: output, repository: store.repository) } else { ScrollView([.vertical, .horizontal]) { Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
        }.onChange(of: confirm) { _, value in if !value { pending = nil } }.interactiveDismissDisabled(busy).padding(20).frame(width: 850, height: 650)
        .alert(workflowText("Confirm repository change"), isPresented: $confirm) { Button(workflowText("Cancel"), role: .cancel) { pending = nil }; Button(workflowText("Continue"), role: operation == .resetHard ? .destructive : nil) { if let request = pending { pending = nil; run(request.0, request.1, request.2, request.3) } } } message: { Text(workflowText(operation.rawValue) + "\n" + first + "\n" + second + "\n" + workflowText(operation.rawValue + ".help")) }
    }
    private func loadPlan() {
        guard let repo = store.repository, !store.isBusy else { return }; let base = first
        busy = true; store.isBusy = true
        Task {
            do { let plan = try await repo.advancedOperation(.rebasePlan, first: base, second: ""); if operation == .interactiveRebase && first == base && store.repositoryURL == repo.url { second = plan } } catch { output = error.localizedDescription }
            busy = false; store.isBusy = false
        }
    }
    private var firstLabel: String {
        switch operation {
        case .compare, .rebasePlan, .interactiveRebase: return "Base revision"
        case .stashRename: return "Stash reference"
        case .blame: return "File path"
        case .remoteAdd, .remoteRemove: return "Remote name"
        case .upstream: return "Remote branch"
        case .trackingBranch: return "Local branch name"
        case .annotatedTag, .tagDelete: return "Tag name"
        case .merge, .resetHard, .resetMixed, .resetSoft: return "Target revision"
        case .submoduleAdd: return "Repository URL"
        case .lfsTrack: return "File pattern"
        case .flowStart: return "Feature name"
        case .commitTemplate: return "Template file path"
        case .signingKey: return "Signing key ID"
        case .signingEnable: return "true / false"
        default: return ""
        }
    }
    private var secondLabel: String {
        switch operation {
        case .compare: return "Target revision"
        case .blame: return "Revision"
        case .remoteAdd: return "Repository URL"
        case .trackingBranch: return "Remote branch"
        case .annotatedTag: return "Annotation"
        case .partialStash, .stashRename: return "Stash message"
        case .submoduleAdd: return "Destination path"
        case .flowStart: return "Base branch"
        default: return ""
        }
    }
    private func run(_ repository: GitRepository, _ op: RepositoryWorkflow, _ a: String, _ b: String) {
        guard !store.isBusy, store.repositoryURL == repository.url else { return }
        busy = true; store.isBusy = true; output = ""
        Task {
            do { output = try await repository.advancedOperation(op, first: a, second: b); if op == .compare { compared = (a, b) }; if output.isEmpty { output = workflowText("Completed") };  }
            catch { output = error.localizedDescription }
            busy = false; store.isBusy = false; if op.writes { await store.refresh() }
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
        }.disabled(busy).interactiveDismissDisabled(busy).padding(24).frame(width: 600)
    }
    private func create() {
        let cloning = clone, cloneSource = source, target = destination
        busy = true; store.isBusy = true
        Task {
            do { let url = URL(fileURLWithPath: target); let repo = try await cloning ? GitRepository.clone(source: cloneSource, destination: url) : GitRepository.initialize(at: url); store.isBusy = false; await store.open(repo.url); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false; store.isBusy = false
        }
    }
}

struct HistoricalRecordsView: View {
    let text: String
    let repository: GitRepository?
    @State private var selected: String?
    @State private var error = ""
    var body: some View {
        VStack {
            List(selection: $selected) {
                ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { index, line in
                    Text(String(line)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).tag(String(line))
                }
            }.contextMenu(forSelectionType: String.self) { rows in
                if let line = rows.first { Button(workflowText("Open commit")) { open(line) }; Button(workflowText("Copy record")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line, forType: .string) } }
            } primaryAction: { rows in if let line = rows.first { open(line) } }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }
    }
    private func open(_ line: String) {
        guard let repository, let word = line.split(separator: " ").first else { return }
        let revision = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "^"))
        Task { do { let hash = try await repository.workflowRevision(revision); if let commit = try await repository.log(limit: 1, ref: hash).first { CommitDetailPresenter.show(commit: commit, repository: repository) } } catch { self.error = error.localizedDescription } }
    }
}
