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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(networkText("title")).font(.headline)
                Spacer()
                Button(networkText("close")) { dismiss() }.disabled(task != nil)
                Picker(networkText("operation"), selection: $operation) {
                    Text(networkText("fetch")).tag(NetworkOperation.fetch)
                    Text(networkText("pull")).tag(NetworkOperation.pull)
                    Text(networkText("push")).tag(NetworkOperation.pushPreview)
                }.labelsHidden().frame(width: 200).disabled(task != nil)
            }
            HStack {
                if let latest = events.last {
                    if let fraction = latest.fraction { ProgressView(value: fraction).frame(width: 180); Text("\(Int(fraction * 100))%") }
                    Text(latest.message).font(.caption).lineLimit(2).textSelection(.enabled)
                } else { Text(networkText("progressHint")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if task != nil { Button(networkText("cancel")) { task?.cancel() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in Text(event.message) }
                    Text(output)
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 180).background(.quaternary.opacity(0.2))
            HStack {
                Button(networkText(operation == .pushPreview ? "preview" : "run")) { run(operation) }.disabled(task != nil || store.isBusy || store.repository == nil)
                if operation == .pushPreview && previewReady { Button(networkText("executePush")) { pushConfirm = true }.disabled(task != nil || store.isBusy) }
                Spacer()
            }
            Divider()
            Text(networkText("credentials")).font(.headline)
            if let credentials {
                Text(networkText("helpers") + ": " + (credentials.helpers.isEmpty ? networkText("none") : credentials.helpers.joined(separator: ", "))).font(.caption)
                Text(networkText(credentials.sshAgentAvailable ? "sshAvailable" : "sshHint")).font(.caption).foregroundStyle(.secondary)
            }
            Text(networkText("credentialHint")).font(.caption).foregroundStyle(.secondary)
            Button(networkText("configureKeychain")) { keychainConfirm = true }.disabled(task != nil || store.isBusy || store.repository == nil)
        }.padding(20).frame(minWidth: 680, minHeight: 480)
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
