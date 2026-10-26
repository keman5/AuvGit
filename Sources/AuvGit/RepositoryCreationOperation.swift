import SwiftUI
import GitCore
import Combine

/// Owned by the window's store so dismissing the form never owns the operation lifetime.
@MainActor
final class RepositoryCreationOperation: ObservableObject {
    enum Prompt: Identifiable {
        case replace(URL)
        case retry(String)
        var id: String {
            switch self {
            case .replace(let url): return "replace:" + url.path
            case .retry(let message): return "retry:" + message
            }
        }
    }
    typealias CreateRepository = (Bool, String, URL, HTTPSCloneCredential?, NetworkCredential?) async throws -> GitRepository
    unowned let store: RepositoryStore
    private let createRepository: CreateRepository
    private let trashItem: (URL) throws -> Void
    private var prepared = false
    private var operationObservation: AnyCancellable?
    private(set) var operationStore: RepositoryStore?
    @Published var prompt: Prompt?
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

    init(store: RepositoryStore, trashItem: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }, createRepository: @escaping CreateRepository = { cloning, source, target, https, ssh in
        try await cloning ? GitRepository.clone(source: source, destination: target, credential: https, sshCredential: ssh) : GitRepository.initialize(at: target)
    }) {
        self.store = store
        self.trashItem = trashItem
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

    func present(initialClone: Bool? = nil) {
        guard !busy else { return }
        prepare(initialClone: initialClone)
        isPresented = true
    }

    func saveDraft() {
        RepositoryCreationDraft(clone: clone, source: source, destination: destination, cloneDestination: cloneDestination).save()
    }

    func endPresentation() {
        saveDraft()
        guard !busy, prompt == nil else { return }
        password = ""; keyPassphrase = ""
        authenticationRequested = false; sshAuthenticationRequested = false
        prepared = false
    }

    func create() {
        let store = store
        let cloning = clone, cloneSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = CloneDestination.targetURL(destination) else { return }
        guard !busy else { return }
        if cloning, (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
            prompt = .replace(target)
            return
        }
        let credential = authenticationRequested ? HTTPSCloneCredential(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            saveToKeychain: saveCredential
        ) : nil
        let targetRepository = GitRepository(url: target)
        let name = cloning ? "Clone" : "Create Repository"
        let runner = operationStore ?? RepositoryStore(persistsSession: false)
        operationStore = runner
        runner.repository = targetRepository; runner.repositoryURL = target
        operationObservation = runner.objectWillChange.sink { [weak store] _ in store?.objectWillChange.send() }
        let previousOperationID = store.currentUserOperationID
        busy = true; runner.isBusy = true
        runner.beginUserOperation(name)
        let operationID = runner.currentUserOperationID
        let progress = runner.progressHandler(for: targetRepository, operationID: operationID)
        store.objectWillChange.send()
        isPresented = false
        Task {
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
                    catch { runner.error = OperationFailure.message(error) }
                }
                if cloning { cloneDestination.rememberSuccessfulClone(target) }
                password = ""
                keyPassphrase = ""
                runner.finishUserOperation(name, repository: targetRepository)
                store.adoptCreationResult(from: runner, previousOperationID: previousOperationID)
                if store.workspaceProjects != nil || !store.isBusy { await store.open(repo.url) }
                NotificationCenter.default.post(name: .auvGitRepositoryCreated, object: store, userInfo: ["path": repo.url.path])

            }
            catch {
                runner.finishUserOperation(name, repository: targetRepository, failure: error)
                store.adoptCreationResult(from: runner, previousOperationID: previousOperationID)
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
                    self.error = runner.error ?? message
                    if cloning, !(error is CancellationError) { prompt = .retry(self.error) }
                }
            }
            password = ""; keyPassphrase = ""
            if !isPresented { prepared = false }
            busy = false; runner.isBusy = false
            store.objectWillChange.send()
        }
    }

    func replaceAndCreate(_ target: URL) {
        guard !busy, clone, CloneDestination.targetURL(destination)?.path == target.standardizedFileURL.path else { return }
        do {
            let cloneSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let localSource = URL(string: cloneSource).flatMap { $0.isFileURL ? $0 : nil }
                ?? (!cloneSource.contains(":") ? URL(fileURLWithPath: (cloneSource as NSString).expandingTildeInPath, relativeTo: target.deletingLastPathComponent()) : nil)
            if let localSource {
                let sourcePath = localSource.resolvingSymlinksInPath().path
                let targetPath = target.resolvingSymlinksInPath().path
                guard sourcePath != targetPath, !sourcePath.hasPrefix(targetPath + "/") else {
                    throw GitError(workflowText("The destination contains the clone source. Choose another destination."))
                }
            }
            try trashItem(target)
            create()
        } catch {
            self.error = OperationFailure.message(error, repository: target)
            prompt = .retry(self.error)
        }
    }
}

