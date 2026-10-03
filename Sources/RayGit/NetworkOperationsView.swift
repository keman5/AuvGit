import SwiftUI
import GitCore
import RayGitLocalization

private func networkText(_ key: String) -> String { L10n.text(key, table: "Network") }

struct NetworkOperationsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RepositoryStore
    @State private var operation = NetworkOperation.fetch
    @State private var events: [NetworkProgress] = []
    @State private var output = ""
    @State private var task: Task<Void, Never>?
    @State private var previewReady = false
    @State private var previewIdentity: String?
    @State private var previewRepository: URL?
    @State private var credentials: CredentialConfiguration?
    @State private var keychainConfirm = false
    @State private var pushConfirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(networkText("title")).font(.title2.weight(.semibold))
            Picker(networkText("operation"), selection: $operation) {
                Text(networkText("fetch")).tag(NetworkOperation.fetch)
                Text(networkText("pull")).tag(NetworkOperation.pull)
                Text(networkText("push")).tag(NetworkOperation.pushPreview)
            }.fixedSize(horizontal: true, vertical: false).disabled(task != nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let latest = events.last {
                        if let fraction = latest.fraction {
                            ProgressView(value: fraction).frame(width: 180)
                            Text("\(Int(fraction * 100))%").monospacedDigit()
                        } else if task != nil { ProgressView().controlSize(.small) }
                        Text(latest.message).font(.caption).lineLimit(2).textSelection(.enabled)
                    } else {
                        if task != nil { ProgressView().controlSize(.small) }
                        Text(networkText("progressHint")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                GroupBox(panelText("Results")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if events.isEmpty && output.isEmpty {
                                Text(panelText("Run an operation to view its result.")).foregroundStyle(.secondary)
                            }
                            ForEach(Array(events.enumerated()), id: \.offset) { _, event in Text(event.message) }
                            if !output.isEmpty { Text(output) }
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 180, maxHeight: .infinity)
            }
            GroupBox(networkText("credentials")) {
                VStack(alignment: .leading, spacing: 12) {
                    if let credentials {
                        Text(networkText("helpers") + ": " + (credentials.helpers.isEmpty ? networkText("none") : credentials.helpers.joined(separator: ", "))).font(.callout)
                        Text(networkText(credentials.sshAgentAvailable ? "sshAvailable" : "sshHint")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(networkText("credentialHint")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(networkText("configureKeychain")) { keychainConfirm = true }.disabled(task != nil || store.isBusy || store.repository == nil)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                if task != nil {
                    Button(networkText("cancel")) { task?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(networkText("close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if operation == .pushPreview && previewReady {
                    Button(networkText("preview")) { run(operation) }.disabled(task != nil || store.isBusy || store.repository == nil)
                    Button(networkText("executePush")) { pushConfirm = true }.buttonStyle(.borderedProminent).disabled(task != nil || store.isBusy)
                } else {
                    Button(networkText(operation == .pushPreview ? "preview" : "run")) { run(operation) }
                        .buttonStyle(.borderedProminent).disabled(task != nil || store.isBusy || store.repository == nil)
                }
            }
        }.controlSize(.small).padding(20).frame(width: 760, height: 620)
        .interactiveDismissDisabled(task != nil)
        .task { await loadCredentials() }
        .onChange(of: operation) { _, _ in previewReady = false; events = []; output = "" }
        .onDisappear { task?.cancel() }
        .alert(networkText("executePush"), isPresented: $pushConfirm) {
            Button(networkText("cancel"), role: .cancel) {}
            Button(networkText("executePush")) { run(.push) }
        } message: { Text(networkText("pushConfirm")) }
        .alert(networkText("configureKeychain"), isPresented: $keychainConfirm) {
            Button(networkText("cancel"), role: .cancel) {}
            Button(networkText("run")) { configureKeychain() }
        } message: { Text(networkText("keychainConfirm")) }
    }
    private func loadCredentials() async {
        guard let repository = store.repository else { return }
        do { credentials = try await repository.credentialConfiguration() } catch { output = error.localizedDescription }
    }
    private func run(_ operation: NetworkOperation) {
        guard let repository = store.repository, !store.isBusy, task == nil else { return }
        let expected = previewIdentity, expectedRepository = previewRepository
        store.isBusy = true; events = []; output = ""; previewReady = false
        task = Task { @MainActor in
            do {
                let identity = try await repository.networkPreviewIdentity()
                if operation == .push && (expected != identity || expectedRepository != repository.url) { throw GitError(networkText("previewExpired")) }
                let result = try await repository.runNetwork(operation) { event in
                    Task { @MainActor in
                        events.append(event)
                        if events.count > 300 { events.removeFirst(events.count - 300) }
                    }
                }
                output = result.output + "\n" + networkText("completed")
                if operation == .pushPreview {
                    let after = try await repository.networkPreviewIdentity()
                    previewReady = after == identity
                    previewIdentity = previewReady ? identity : nil; previewRepository = repository.url
                    if !previewReady { output += "\n" + networkText("previewExpired") }
                }
            } catch is CancellationError { output = networkText("cancelled") }
            catch { output = GitProgressParser.redact(error.localizedDescription) }
            store.isBusy = false; task = nil
            if operation != .pushPreview { await store.refresh() }
        }
    }
    private func configureKeychain() {
        guard let repository = store.repository, !store.isBusy else { return }
        store.isBusy = true
        task = Task { @MainActor in
            do { try await repository.configureKeychainHelper(); await loadCredentials() }
            catch { output = error.localizedDescription }
            store.isBusy = false; task = nil
        }
    }
}
