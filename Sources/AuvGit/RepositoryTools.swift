import SwiftUI
import GitCore
import AuvGitLocalization

func workflowText(_ key: String) -> String { L10n.text(key, table: "Workflow") }
func panelText(_ key: String) -> String { L10n.text(key, table: "VisualPanels") }

struct RepositoryTools: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = RepositoryWorkflow.compare
    @State private var first = "HEAD~1"
    @State private var second = "HEAD"
    @State private var output = ""
    @State private var resultFailed = false
    @State private var busy = false
    @State private var confirm = false
    @State private var compared: (String, String)?
    @State private var inspected: (String?, String)?
    @State private var pending: (GitRepository, RepositoryWorkflow, String, String)?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workflowText("Repository Tools")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Picker(workflowText("Operation"), selection: $operation) {
                    Section(workflowText("Inspect")) { ForEach(RepositoryWorkflow.allCases.filter { !$0.writes }) { item in Text(workflowText(item.rawValue)).tag(item) } }
                    Section(workflowText("Change")) { ForEach(RepositoryWorkflow.allCases.filter { $0.writes }) { item in Text(workflowText(item.rawValue)).tag(item) } }
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(busy || store.isBusy)
                .onChange(of: operation) { _, _ in
                    output = ""; resultFailed = false; compared = nil; inspected = nil
                    first = operation == .compare ? "HEAD~1" : ""
                    second = operation == .compare || operation == .blame ? "HEAD" : ""
                }
                if operation == .interactiveRebase {
                    RebaseWorkflowView(store: store, onClose: { dismiss() })
                } else {
                    Text(workflowText(operation.rawValue + ".help"))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if !firstLabel.isEmpty, operation != .partialStash { field(firstLabel, text: $first) }
                    if !secondLabel.isEmpty { field(secondLabel, text: $second) }
                    if operation == .partialStash {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflowText("File path")).font(.callout)
                            TextEditor(text: $first).font(.system(.caption, design: .monospaced))
                                .frame(height: 88).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                                .disabled(busy || store.isBusy)
                        }
                    }
                }
            }
            if operation != .interactiveRebase {
                GroupBox(resultFailed ? L10n.text("Operation failed") : panelText("Results")) { results.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    .frame(maxHeight: .infinity)
            }
            if operation != .interactiveRebase {
                Divider()
                HStack(spacing: 8) {
                    if busy || store.isBusy { ProgressView().controlSize(.small) }
                    DialogButton(workflowText("Close"), role: .cancel) { dismiss() }
                        .disabled(busy || store.isBusy)
                    DialogButton(workflowText(operation.writes ? "Run change…" : "Read"), prominent: true) {
                        if operation.writes, let repo = store.repository { pending = (repo, operation, first, second); confirm = true }
                        else if let repo = store.repository { run(repo, operation, first, second) }
                    }
                    .disabled(busy || store.isBusy || store.repository == nil || (!firstLabel.isEmpty && first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (operation == .partialStash && first.isEmpty))
                }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
            }
        }
        .controlSize(.small)
        .onChange(of: confirm) { _, value in if !value { pending = nil } }
        .interactiveDismissDisabled(busy || store.isBusy).padding(20).frame(width: operation == .interactiveRebase ? 1100 : 850, height: operation == .interactiveRebase ? 850 : 640)
        .auvGitAlert(workflowText("Confirm repository change"), isPresented: $confirm) {
            AuvGitAlertButton(workflowText("Cancel"), role: .cancel) { pending = nil }
            AuvGitAlertButton(workflowText("Continue"), role: operation == .resetHard ? .destructive : nil) {
                if let request = pending { pending = nil; run(request.0, request.1, request.2, request.3) }
            }
        } message: { Text(workflowText(operation.rawValue) + "\n" + first + "\n" + second + "\n" + workflowText(operation.rawValue + ".help")) }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflowText(label)).font(.callout)
            StableTextField(workflowText(label), text: text).textFieldStyle(.roundedBorder)
                .disabled(busy || store.isBusy)
        }
    }
    @ViewBuilder private var results: some View {
        if busy {
            VStack(spacing: 12) { ProgressView().controlSize(.small); Text(panelText("Running operation…")).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if resultFailed {
            ScrollView {
                Text(output).font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        } else if operation == .compare, let refs = compared, let repo = store.repository {
            ReferenceChangesView(repository: repo, left: refs.0, right: refs.1).id(refs.0 + "\0" + refs.1)
        } else if (operation == .reflog || operation == .blame), let inspection = inspected, let repo = store.repository {
            StructuredHistoryView(repository: repo, blamePath: inspection.0, revision: inspection.1).id((inspection.0 ?? "") + inspection.1)
        } else if output.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                Text(panelText("Run an operation to view its result.")).font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }
    private func loadPlan() {
        guard let repo = store.repository, !store.isBusy else { return }; let base = first
        busy = true; store.isBusy = true
        Task {
            await store.cancelBackgroundRepositorySync()
            do { let plan = try await repo.advancedOperation(.rebasePlan, first: base, second: ""); if operation == .interactiveRebase && first == base && store.repositoryURL == repo.url { second = plan } } catch { resultFailed = true; output = OperationFailure.message(error, repository: store.repositoryURL) }
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
        busy = true; store.isBusy = true; output = ""; resultFailed = false
        Task {
            await store.cancelBackgroundRepositorySync()
            do { if op == .blame || op == .reflog { inspected = (op == .blame ? a : nil, b.isEmpty ? "HEAD" : b); output = "" } else { output = try await repository.advancedOperation(op, first: a, second: b) }; if op == .compare { compared = (a, b) }; if output.isEmpty { output = workflowText("Completed") };  }
            catch { resultFailed = true; output = OperationFailure.message(error, repository: store.repositoryURL) }
            busy = false; store.isBusy = false; if op.writes { await store.refresh() }
        }
    }
}

extension Notification.Name {
    static let auvGitRepositoryCreated = Notification.Name("AuvGitRepositoryCreated")
}

struct CreateRepositorySheet: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var clone = false
    @State private var source = ""
    @State private var destination = ""
    @State private var cloneDestination: CloneDestination
    @State private var busy = false
    @State private var error = ""
    @State private var authenticationRequested = false
    @State private var sshAuthenticationRequested = false
    @State private var privateKey: URL?
    @State private var keyPassphrase = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredential = true
    init(store: RepositoryStore, initialClone: Bool? = nil) {
        self.store = store
        var draft = RepositoryCreationDraft.load()
        if let initialClone { draft.clone = initialClone }
        draft.applyClipboard(NSPasteboard.general.string(forType: .string))
        _clone = State(initialValue: draft.clone)
        _source = State(initialValue: draft.source)
        _destination = State(initialValue: draft.destination)
        _cloneDestination = State(initialValue: draft.cloneDestination)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workflowText("Create Repository")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                KeyViewProxy(label: workflowText("Clone existing repository"), checked: clone) { clone.toggle() }
                    .onChange(of: clone) { _, value in
                        if value { cloneDestination.sourceChanged(source); destination = cloneDestination.path }
                        else { authenticationRequested = false; sshAuthenticationRequested = false; username = ""; password = ""; keyPassphrase = ""; privateKey = nil }
                    }
                if clone {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(workflowText("Clone URL or local path")).font(.callout)
                        StableTextField(workflowText("Clone URL or local path"), text: $source).textFieldStyle(.roundedBorder)
                            .onChange(of: source) { _, value in
                                authenticationRequested = false; username = ""; password = ""; error = ""
                                sshAuthenticationRequested = false; privateKey = nil; keyPassphrase = ""
                                cloneDestination.sourceChanged(value); destination = cloneDestination.path
                            }
                    }
                    if authenticationRequested {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflowText("HTTPS authentication")).font(.headline)
                            StableTextField(workflowText("Username"), text: $username).textFieldStyle(.roundedBorder)
                            SecureField(workflowText("Password or personal access token"), text: $password).textFieldStyle(.roundedBorder)
                            KeyViewProxy(label: workflowText("Save authenticated credentials in macOS Keychain"), checked: saveCredential) { saveCredential.toggle() }
                            Text(workflowText("Git saves credentials after authentication succeeds, even if cloning fails later.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if sshAuthenticationRequested {
                        Divider()
                        Text(networkText("sshPrivateKey")).font(.headline)
                        StableTextField(networkText("username"), text: $username).textFieldStyle(.roundedBorder)
                        HStack {
                            Text(privateKey?.path ?? networkText("noPrivateKeySelected"))
                                .lineLimit(1).truncationMode(.middle)
                            KeyViewProxy(label: networkText("choosePrivateKey")) {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { privateKey = panel.url }
                            }
                        }
                        SecureField(networkText("keyPassphraseOptional"), text: $keyPassphrase).textFieldStyle(.roundedBorder)
                        KeyViewProxy(label: workflowText("Save authenticated credentials in macOS Keychain"), checked: saveCredential) { saveCredential.toggle() }
                        Text(networkText("sshCredentialScope")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(workflowText("Destination folder")).font(.callout)
                    HStack(spacing: 8) {
                        StableTextField(workflowText("Destination folder"), text: Binding(get: { destination }, set: {
                            destination = $0
                            if clone { cloneDestination.edit($0) }
                        })).textFieldStyle(.roundedBorder)
                        KeyViewProxy(label: workflowText(clone ? "Choose parent folder…" : "Choose…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            if clone { panel.directoryURL = cloneDestination.parent }
                            if panel.runModal() == .OK, let folder = panel.url {
                                if clone { cloneDestination.chooseParent(folder, source: source); destination = cloneDestination.path }
                                else { destination = folder.path }
                            }
                        }
                    }
                }
            }.disabled(busy)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                KeyViewProxy(label: workflowText("Cancel"), keyEquivalent: "\u{1b}", minimumWidth: AuvGitDialogButtonStyle.minimumWidth) { dismiss() }.disabled(busy)
                KeyViewProxy(label: workflowText(authenticationRequested || sshAuthenticationRequested ? "Retry Clone" : "Create"), prominent: true, minimumWidth: AuvGitDialogButtonStyle.minimumWidth) { create() }
                    .disabled(busy || CloneDestination.targetURL(destination) == nil || (clone && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (authenticationRequested && (username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)))
                    .disabled(sshAuthenticationRequested && (privateKey == nil || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.controlSize(.small).interactiveDismissDisabled(busy).padding(20).frame(width: 440)
            .nativeFocusRoot(reusingParent: true)
            .onChange(of: clone) { _, _ in saveDraft() }
            .onChange(of: source) { _, _ in saveDraft() }
            .onChange(of: destination) { _, _ in saveDraft() }
            .onChange(of: cloneDestination) { _, _ in saveDraft() }
            .onDisappear { password = ""; keyPassphrase = ""; saveDraft() }
    }
    private func saveDraft() {
        RepositoryCreationDraft(clone: clone, source: source, destination: destination, cloneDestination: cloneDestination).save()
    }
    private func create() {
        let cloning = clone, cloneSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = CloneDestination.targetURL(destination) else { return }
        let credential = authenticationRequested ? HTTPSCloneCredential(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            saveToKeychain: saveCredential
        ) : nil
        busy = true; store.isBusy = true
        Task {
            await store.cancelBackgroundRepositorySync()
            do {
                let endpoint = RemoteEndpoint.parse(cloneSource)
                var sshCredential: NetworkCredential?
                if cloning, let endpoint, endpoint.transport == .ssh {
                    if sshAuthenticationRequested, let privateKey {
                        sshCredential = .ssh(username: username.trimmingCharacters(in: .whitespacesAndNewlines), privateKey: privateKey, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
                    } else if let name = endpoint.username ?? RemoteCredentialStore.shared.preferredUsername(for: endpoint) {
                        sshCredential = try? RemoteCredentialStore.shared.load(for: endpoint, username: name)
                    }
                }
                let key: URL?
                if case let .ssh(_, url, _)? = sshCredential { key = url } else { key = nil }
                let accessed = key?.startAccessingSecurityScopedResource() ?? false
                defer { if accessed { key?.stopAccessingSecurityScopedResource() } }
                let repo = try await cloning ? GitRepository.clone(source: cloneSource, destination: target, credential: credential, sshCredential: sshCredential) : GitRepository.initialize(at: target)
                if let sshCredential, let endpoint, saveCredential {
                    do { try RemoteCredentialStore.shared.save(sshCredential, for: endpoint) }
                    catch { store.error = OperationFailure.message(error) }
                }
                if cloning { cloneDestination.rememberSuccessfulClone(target) }
                password = ""
                keyPassphrase = ""
                store.isBusy = false; await store.open(repo.url)
                NotificationCenter.default.post(name: .auvGitRepositoryCreated, object: store, userInfo: ["path": repo.url.path])
                dismiss()
            }
            catch {
                _ = OperationFailure.message(error)
                switch CloneAuthentication.classify(source: cloneSource, error: error) {
                case .httpsCredentials:
                    authenticationRequested = true
                    self.error = workflowText("HTTPS authentication is required. Enter your username and password or personal access token, then retry.")
                case .sshKey:
                    sshAuthenticationRequested = true
                    if username.isEmpty { username = RemoteEndpoint.parse(cloneSource)?.username ?? "git" }
                    self.error = networkText("authenticationRequired")
                case .other(let message):
                    self.error = message
                }
            }
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
        Task { do { let hash = try await repository.workflowRevision(revision); if let commit = try await repository.log(limit: 1, ref: hash).first { CommitDetailPresenter.show(commit: commit, repository: repository) } } catch { self.error = OperationFailure.message(error) } }
    }
}
