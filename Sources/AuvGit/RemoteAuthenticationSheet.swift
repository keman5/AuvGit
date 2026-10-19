import SwiftUI
import AppKit
import GitCore

enum RemoteAuthenticationMethod: String, CaseIterable {
    case accessToken, accountPassword, sshPrivateKey
}

struct RemoteAuthenticationMethodPicker: NSViewRepresentable {
    @Binding var selection: RemoteAuthenticationMethod
    var isEnabled: Bool
    @Environment(\.nativeFocusScope) private var scope

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [networkText("accessTokenOrAppPassword"),
            networkText("accountPassword"), networkText("sshPrivateKey")], trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        NativeFocusAppearance.rememberOriginalRing(for: control)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = RemoteAuthenticationMethod.allCases.firstIndex(of: selection) ?? 0
        control.isEnabled = isEnabled
        scope?.register(control)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 576, height: 28)
    }
    final class Coordinator: NSObject {
        var selection: Binding<RemoteAuthenticationMethod>
        init(selection: Binding<RemoteAuthenticationMethod>) { self.selection = selection }
        @objc func changed(_ control: NSSegmentedControl) {
            guard RemoteAuthenticationMethod.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = RemoteAuthenticationMethod.allCases[control.selectedSegment]
        }
    }
}

struct RemoteAuthenticationSubmission {
    let credential: NetworkCredential
    let sshPort: Int?
}

struct RemoteAuthenticationRetryContext {
    let credential: NetworkCredential
    let saveCredential: Bool
    let remoteChanged: Bool

    var acceptsMigratedPushIdentity: Bool { remoteChanged }
    var requiresFreshForcePushPreparation: Bool { remoteChanged }
}

struct RemoteAuthenticationDraft {
    let endpoint: RemoteEndpoint
    var method: RemoteAuthenticationMethod
    var httpsUsername: String
    var token = ""
    var password = ""
    var sshUsername: String
    var sshPort: String
    var privateKey: URL?
    var passphrase = ""

    init(endpoint: RemoteEndpoint, preferredUsername: String?, privateKey: URL? = nil,
         preferredSSHUsername: String? = nil) {
        self.endpoint = endpoint
        method = endpoint.transport == .https ? .accessToken : .sshPrivateKey
        httpsUsername = endpoint.transport == .https ? (preferredUsername ?? endpoint.username ?? "") : ""
        sshUsername = endpoint.transport == .ssh ? (preferredUsername ?? endpoint.username ?? "git") : (preferredSSHUsername ?? "git")
        sshPort = String(endpoint.transport == .ssh ? endpoint.port : 22)
        self.privateKey = privateKey
    }

    var validationMessageKey: String? {
        guard method == .accessToken else { return nil }
        return NetworkAuthenticationPolicy.tokenValidationMessageKey(token, endpoint: endpoint)
    }

    var submission: RemoteAuthenticationSubmission? {
        guard validationMessageKey == nil else { return nil }
        let name = (method == .sshPrivateKey ? sshUsername : httpsUsername).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else { return nil }
        switch method {
        case .accessToken, .accountPassword:
            guard endpoint.transport == .https else { return nil }
            let value = method == .accessToken ? token : password
            guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else { return nil }
            return RemoteAuthenticationSubmission(credential: .https(username: name, password: value), sshPort: nil)
        case .sshPrivateKey:
            guard let port = Int(sshPort), (1...65535).contains(port) else { return nil }
            guard let privateKey, FileManager.default.fileExists(atPath: privateKey.path) else { return nil }
            guard !passphrase.contains("\n"), !passphrase.contains("\r"), !passphrase.contains("\0") else { return nil }
            return RemoteAuthenticationSubmission(credential: .ssh(username: name, privateKey: privateKey, passphrase: passphrase.isEmpty ? nil : passphrase), sshPort: port)
        }
    }
}

@MainActor
struct RemoteAuthenticationRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let operation: NetworkOperation
    let remoteName: String?
    let endpoint: RemoteEndpoint
    let preferredUsername: String?
    let preferredSSHUsername: String?
    let privateKey: URL?
    let retry: @MainActor (RemoteAuthenticationRetryContext) -> Void
}

@MainActor
final class RemoteAuthenticationCoordinator: ObservableObject {
    @Published var request: RemoteAuthenticationRequest?
    @Published private(set) var submissionError: String?
    @Published private(set) var isSubmitting = false
    private let credentials: RemoteCredentialStore
    // Retain only the account name between retries, never the rejected secret.
    private var lastHTTPSAttempt: (repository: URL, endpoint: RemoteEndpoint, username: String)?

    init(credentials: RemoteCredentialStore = .shared) { self.credentials = credentials }

    func savedCredential(for repository: GitRepository, operation: NetworkOperation, remoteName: String? = nil) async -> NetworkCredential? {
        guard let target = try? await repository.remoteAuthenticationTarget(for: operation, remoteName: remoteName) else { return nil }
        let username = credentials.preferredUsername(for: target.endpoint) ?? target.endpoint.username
        guard let username else { return nil }
        return try? credentials.load(for: target.endpoint, username: username)
    }

    @discardableResult
    func presentIfNeeded(error: Error, repository: GitRepository, operation: NetworkOperation, remoteName: String? = nil,
                         retry: @escaping @MainActor (RemoteAuthenticationRetryContext) -> Void) async -> Bool {
        guard let target = try? await repository.remoteAuthenticationTarget(for: operation, remoteName: remoteName),
              NetworkAuthenticationPolicy.prompt(for: error, endpoint: target.endpoint) != nil else { return false }
        let attempted = lastHTTPSAttempt.flatMap {
            $0.repository == repository.url && $0.endpoint == target.endpoint ? $0.username : nil
        }
        let preferred = attempted ?? credentials.preferredUsername(for: target.endpoint) ?? target.endpoint.username
        var privateKey: URL?
        var preferredSSHUsername: String?
        if target.endpoint.transport == .ssh {
            preferredSSHUsername = preferred
            if let preferred, case let .ssh(_, key, _)? = try? credentials.load(for: target.endpoint, username: preferred) { privateKey = key }
        } else if let candidate = target.endpoint.convertingToSSH(username: "git", port: 22) {
            preferredSSHUsername = credentials.preferredUsername(for: candidate)
            if let preferredSSHUsername,
               case let .ssh(_, key, _)? = try? credentials.load(for: candidate, username: preferredSSHUsername) { privateKey = key }
        }
        submissionError = target.endpoint.transport == .https && NetworkAuthenticationPolicy.credentialWasRejected(error)
            ? networkText("httpsCredentialRejected") : nil
        request = RemoteAuthenticationRequest(repository: repository, operation: operation, remoteName: remoteName, endpoint: target.endpoint,
                                              preferredUsername: preferred, preferredSSHUsername: preferredSSHUsername,
                                              privateKey: privateKey, retry: retry)
        return true
    }

    func submit(_ submission: RemoteAuthenticationSubmission) {
        guard let request, !isSubmitting else { return }
        if case let .https(username, password) = submission.credential {
            if let key = NetworkAuthenticationPolicy.tokenValidationMessageKey(password, endpoint: request.endpoint) {
                submissionError = networkText(key)
                return
            }
            lastHTTPSAttempt = (request.repository.url, request.endpoint, username)
        }
        if request.endpoint.transport == .https,
           case let .ssh(username, key, _) = submission.credential,
           let port = submission.sshPort {
            isSubmitting = true; submissionError = nil
            Task { @MainActor in
                do {
                    let plan = try await request.repository.remoteSSHMigrationPlan(for: request.operation, username: username, port: port, remoteName: request.remoteName)
                    let accessed = key.startAccessingSecurityScopedResource()
                    defer { if accessed { key.stopAccessingSecurityScopedResource() } }
                    try await request.repository.migrateRemoteToSSH(plan, credential: submission.credential)
                    try credentials.save(submission.credential, for: plan.replacement)
                    self.request = nil; isSubmitting = false
                    request.retry(RemoteAuthenticationRetryContext(credential: submission.credential,
                                                                   saveCredential: false,
                                                                   remoteChanged: true))
                } catch {
                    submissionError = OperationFailure.message(error, repository: request.repository.url)
                    isSubmitting = false
                }
            }
            return
        }
        self.request = nil; submissionError = nil
        request.retry(RemoteAuthenticationRetryContext(credential: submission.credential,
                                                       saveCredential: true,
                                                       remoteChanged: false))
    }

    func cancel() {
        guard !isSubmitting else { return }
        lastHTTPSAttempt = nil
        if request != nil { request = nil }
        if submissionError != nil { submissionError = nil }
    }

    func save(_ credential: NetworkCredential, for repository: GitRepository, operation: NetworkOperation, remoteName: String? = nil) async throws {
        let target = try await repository.remoteAuthenticationTarget(for: operation, remoteName: remoteName)
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
    let error: String?
    let isSubmitting: Bool
    let submit: (RemoteAuthenticationSubmission) -> Void
    let cancel: () -> Void
    @State private var draft: RemoteAuthenticationDraft

    init(request: RemoteAuthenticationRequest, error: String?, isSubmitting: Bool,
         submit: @escaping (RemoteAuthenticationSubmission) -> Void, cancel: @escaping () -> Void) {
        self.request = request; self.error = error; self.isSubmitting = isSubmitting
        self.submit = submit; self.cancel = cancel
        _draft = State(initialValue: RemoteAuthenticationDraft(endpoint: request.endpoint,
                                                                preferredUsername: request.preferredUsername,
                                                                privateKey: request.privateKey,
                                                                preferredSSHUsername: request.preferredSSHUsername))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: request.endpoint.transport == .https ? "person.badge.key.fill" : "key.fill")
                    .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(networkText("authenticationRequired")).font(.headline)
                    Text(request.endpoint.host + ":" + String(request.endpoint.port)).font(.caption).foregroundStyle(.secondary)
                    Text(request.repository.url.lastPathComponent).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            Divider()
            RemoteAuthenticationMethodPicker(selection: $draft.method, isEnabled: !isSubmitting)
                .frame(height: 28).accessibilityLabel(networkText("authenticationMethod"))
            VStack(alignment: .leading, spacing: 8) {
                Text(networkText("username")).font(.caption).foregroundStyle(.secondary)
                StableTextField(networkText("username"), text: draft.method == .sshPrivateKey ? $draft.sshUsername : $draft.httpsUsername)
                    .textFieldStyle(.roundedBorder).disabled(isSubmitting)
            }
            if draft.method == .accessToken {
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("accessTokenOrAppPassword")).font(.caption).foregroundStyle(.secondary)
                    SecureField(networkText("accessTokenOrAppPassword"), text: $draft.token).textFieldStyle(.roundedBorder).disabled(isSubmitting)
                }
            } else if draft.method == .accountPassword {
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("accountPassword")).font(.caption).foregroundStyle(.secondary)
                    SecureField(networkText("accountPassword"), text: $draft.password).textFieldStyle(.roundedBorder).disabled(isSubmitting)
                    Text(networkText("twoFactorHint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("sshPort")).font(.caption).foregroundStyle(.secondary)
                    StableTextField("22", text: $draft.sshPort).textFieldStyle(.roundedBorder).frame(width: 90).disabled(isSubmitting)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("privateKey")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(draft.privateKey?.path ?? networkText("noPrivateKeySelected"))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Button(networkText("choosePrivateKey")) { choosePrivateKey() }.disabled(isSubmitting)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(networkText("keyPassphraseOptional")).font(.caption).foregroundStyle(.secondary)
                    SecureField(networkText("keyPassphraseOptional"), text: $draft.passphrase).textFieldStyle(.roundedBorder).disabled(isSubmitting)
                }
            }
            Text(networkText(draft.method == .sshPrivateKey
                             ? (request.endpoint.transport == .https ? "sshMigrationScope" : "sshCredentialScope")
                             : "httpsCredentialScope"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Reserve feedback space so typing and validation never resize the footer.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let key = draft.validationMessageKey {
                        Text(networkText(key)).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 60)
            Divider()
            HStack {
                ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(isSubmitting ? 1 : 0)
                    .accessibilityHidden(!isSubmitting)
                DialogButton(networkText("cancel"), role: .cancel, action: cancel).disabled(isSubmitting).fixedSize()
                DialogButton(networkText("retry"), prominent: true) {
                    guard let submission = draft.submission else { return }
                    submit(submission)
                }.disabled(draft.submission == nil || isSubmitting).fixedSize()
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity).frame(height: 32)
        }.padding(22).frame(width: 620).fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled()
            .onDisappear { draft.token = ""; draft.password = ""; draft.passphrase = "" }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = networkText("choosePrivateKey")
        if panel.runModal() == .OK { draft.privateKey = panel.url }
    }
}
