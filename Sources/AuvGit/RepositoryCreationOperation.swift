import SwiftUI
import GitCore

/// Owned by the window's store so dismissing the form never owns the operation lifetime.
@MainActor
final class RepositoryCreationOperation: ObservableObject {
    typealias CreateRepository = (Bool, String, URL, HTTPSCloneCredential?, NetworkCredential?) async throws -> GitRepository
    unowned let store: RepositoryStore
    private let createRepository: CreateRepository
    private var prepared = false
    @Published var isPresented = false
    @Published var clone = false
    @Published var source = ""
    @Published var destination = ""
    @Published var cloneDestination: CloneDestination
    @Published var busy = false
    @Published var error = ""
    @Published var authenticationRequested = false
    @Published var sshAuthenticationRequested = false
    @Published var privateKey: URL?
    @Published var keyPassphrase = ""
    @Published var username = ""
    @Published var password = ""
    @Published var saveCredential = true

    init(store: RepositoryStore, createRepository: @escaping CreateRepository = { cloning, source, target, https, ssh in
        try await cloning ? GitRepository.clone(source: source, destination: target, credential: https, sshCredential: ssh) : GitRepository.initialize(at: target)
    }) {
        self.store = store
        self.createRepository = createRepository
        let draft = RepositoryCreationDraft.load()
        cloneDestination = draft.cloneDestination
        clone = draft.clone; source = draft.source; destination = draft.destination
    }

    func prepare(initialClone: Bool?) {
        guard !prepared, !busy, !authenticationRequested, !sshAuthenticationRequested else { return }
        prepared = true
        var draft = RepositoryCreationDraft.load()
        if let initialClone { draft.clone = initialClone }
        draft.applyClipboard(NSPasteboard.general.string(forType: .string))
        clone = draft.clone; source = draft.source; destination = draft.destination
        cloneDestination = draft.cloneDestination
        error = ""
    }

    func saveDraft() {
        RepositoryCreationDraft(clone: clone, source: source, destination: destination, cloneDestination: cloneDestination).save()
    }

    func endPresentation() {
        saveDraft()
        guard !busy else { return }
        password = ""; keyPassphrase = ""
        authenticationRequested = false; sshAuthenticationRequested = false
        prepared = false
    }

    func create() {
        let store = store
        let cloning = clone, cloneSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = CloneDestination.targetURL(destination) else { return }
        let credential = authenticationRequested ? HTTPSCloneCredential(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            saveToKeychain: saveCredential
        ) : nil
        guard !busy, !store.isBusy else { return }
        let targetRepository = GitRepository(url: target)
        let name = cloning ? "Clone" : "Create Repository"
        busy = true; store.isBusy = true
        store.beginUserOperation(name)
        let operationID = store.currentUserOperationID
        let progress = store.creationProgressHandler(operationID: operationID)
        isPresented = false
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
                let repo = try await GitCommandLog.$operationID.withValue(operationID) {
                    try await GitCommandLog.$userInitiated.withValue(true) {
                        try await GitCommandLog.$progress.withValue(progress) {
                            try await createRepository(cloning, cloneSource, target, credential, sshCredential)
                        }
                    }
                }
                if let sshCredential, let endpoint, saveCredential {
                    do { try RemoteCredentialStore.shared.save(sshCredential, for: endpoint) }
                    catch { store.error = OperationFailure.message(error) }
                }
                if cloning { cloneDestination.rememberSuccessfulClone(target) }
                password = ""
                keyPassphrase = ""
                store.isBusy = false; await store.open(repo.url)
                store.finishUserOperation(name, repository: targetRepository, reportInCurrentWindow: true)
                NotificationCenter.default.post(name: .auvGitRepositoryCreated, object: store, userInfo: ["path": repo.url.path])

            }
            catch {
                store.finishUserOperation(name, repository: targetRepository, failure: error, reportInCurrentWindow: true)
                switch CloneAuthentication.classify(source: cloneSource, error: error) {
                case .httpsCredentials:
                    authenticationRequested = true
                    isPresented = true
                    self.error = workflowText("HTTPS authentication is required. Enter your username and password or personal access token, then retry.")
                case .sshKey:
                    sshAuthenticationRequested = true
                    isPresented = true
                    if username.isEmpty { username = RemoteEndpoint.parse(cloneSource)?.username ?? "git" }
                    self.error = networkText("authenticationRequired")
                case .other(let message):
                    self.error = message
                }
            }
            password = ""; keyPassphrase = ""
            if !isPresented { prepared = false }
            busy = false; store.isBusy = false
        }
    }
}

