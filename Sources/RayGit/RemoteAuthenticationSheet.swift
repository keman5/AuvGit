import SwiftUI
import AppKit
import GitCore

struct RemoteAuthenticationDraft {
    let endpoint: RemoteEndpoint
    var username: String
    var secret = ""
    var privateKey: URL?
    var save = true

    init(endpoint: RemoteEndpoint, preferredUsername: String?, privateKey: URL? = nil) {
        self.endpoint = endpoint
        username = preferredUsername ?? endpoint.username ?? (endpoint.transport == .ssh ? "git" : "")
        self.privateKey = privateKey
    }

    var credential: NetworkCredential? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else { return nil }
        switch endpoint.transport {
        case .https:
            guard !secret.isEmpty, !secret.contains("\n"), !secret.contains("\r"), !secret.contains("\0") else { return nil }
            return .https(username: name, password: secret)
        case .ssh:
            guard let privateKey, FileManager.default.fileExists(atPath: privateKey.path) else { return nil }
            return .ssh(username: name, privateKey: privateKey, passphrase: secret.isEmpty ? nil : secret)
        }
    }
}

@MainActor
struct RemoteAuthenticationRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let operation: NetworkOperation
    let endpoint: RemoteEndpoint
    let preferredUsername: String?
    let privateKey: URL?
    let retry: @MainActor (NetworkCredential, Bool) -> Void
}

@MainActor
final class RemoteAuthenticationCoordinator: ObservableObject {
    @Published var request: RemoteAuthenticationRequest?
    private let credentials: RemoteCredentialStore

    init(credentials: RemoteCredentialStore = .shared) { self.credentials = credentials }

    func savedCredential(for repository: GitRepository, operation: NetworkOperation) async -> NetworkCredential? {
        guard let target = try? await repository.remoteAuthenticationTarget(for: operation) else { return nil }
        let username = credentials.preferredUsername(for: target.endpoint) ?? target.endpoint.username
        guard let username else { return nil }
        return try? credentials.load(for: target.endpoint, username: username)
    }

    @discardableResult
    func presentIfNeeded(error: Error, repository: GitRepository, operation: NetworkOperation,
                         retry: @escaping @MainActor (NetworkCredential, Bool) -> Void) async -> Bool {
        guard let target = try? await repository.remoteAuthenticationTarget(for: operation),
              NetworkAuthenticationPolicy.prompt(for: error, endpoint: target.endpoint) != nil else { return false }
        let preferred = credentials.preferredUsername(for: target.endpoint) ?? target.endpoint.username
        var privateKey: URL?
        if let preferred, case let .ssh(_, key, _)? = try? credentials.load(for: target.endpoint, username: preferred) { privateKey = key }
        request = RemoteAuthenticationRequest(repository: repository, operation: operation, endpoint: target.endpoint,
                                              preferredUsername: preferred, privateKey: privateKey, retry: retry)
        return true
    }

    func submit(_ credential: NetworkCredential, save: Bool) {
        let retry = request?.retry
        request = nil
        retry?(credential, save)
    }

    func cancel() { request = nil }

    func save(_ credential: NetworkCredential, for repository: GitRepository, operation: NetworkOperation) async throws {
        let target = try await repository.remoteAuthenticationTarget(for: operation)
        try credentials.save(credential, for: target.endpoint)
    }

    func perform<T>(with credential: NetworkCredential?, _ operation: () async throws -> T) async throws -> T {
        guard case let .ssh(_, key, _)? = credential else { return try await operation() }
        let accessed = key.startAccessingSecurityScopedResource()
        defer { if accessed { key.stopAccessingSecurityScopedResource() } }
        return try await operation()
    }
}

struct RemoteAuthenticationSheet: View {
    let request: RemoteAuthenticationRequest
    let submit: (NetworkCredential, Bool) -> Void
    let cancel: () -> Void
    @State private var draft: RemoteAuthenticationDraft

    init(request: RemoteAuthenticationRequest, submit: @escaping (NetworkCredential, Bool) -> Void, cancel: @escaping () -> Void) {
        self.request = request; self.submit = submit; self.cancel = cancel
        _draft = State(initialValue: RemoteAuthenticationDraft(endpoint: request.endpoint,
                                                                preferredUsername: request.preferredUsername,
                                                                privateKey: request.privateKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: request.endpoint.transport == .https ? "person.badge.key.fill" : "key.fill")
                    .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(networkText("authenticationRequired")).font(.headline)
                    Text(request.endpoint.host + ":" + String(request.endpoint.port)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(networkText("username")).font(.caption).foregroundStyle(.secondary)
                StableTextField(networkText("username"), text: $draft.username).textFieldStyle(.roundedBorder)
            }
            if request.endpoint.transport == .https {
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("passwordOrToken")).font(.caption).foregroundStyle(.secondary)
                    SecureField(networkText("passwordOrToken"), text: $draft.secret).textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("privateKey")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(draft.privateKey?.path ?? networkText("noPrivateKeySelected"))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Button(networkText("choosePrivateKey")) { choosePrivateKey() }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("keyPassphraseOptional")).font(.caption).foregroundStyle(.secondary)
                    SecureField(networkText("keyPassphraseOptional"), text: $draft.secret).textFieldStyle(.roundedBorder)
                }
            }
            Toggle(networkText("saveCredential"), isOn: $draft.save)
            Text(networkText(request.endpoint.transport == .https ? "httpsCredentialScope" : "sshCredentialScope"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(networkText("cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(networkText("retry")) {
                    guard let credential = draft.credential else { return }
                    submit(credential, draft.save)
                    draft.secret = ""
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(draft.credential == nil)
            }.frame(maxWidth: .infinity)
        }.padding(22).frame(width: 460)
            .interactiveDismissDisabled()
            .onDisappear { draft.secret = "" }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = networkText("choosePrivateKey")
        if panel.runModal() == .OK { draft.privateKey = panel.url }
    }
}
