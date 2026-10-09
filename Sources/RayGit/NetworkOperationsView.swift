import SwiftUI
import GitCore
import RayGitLocalization

func networkText(_ key: String) -> String { L10n.text(key, table: "Network") }

struct NetworkOperationsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RepositoryStore
    @StateObject private var authentication = RemoteAuthenticationCoordinator()
    @State private var operation = NetworkOperation.fetch
    @State private var events: [NetworkProgress] = []
    @State private var output = ""
    @State private var task: Task<Void, Never>?
    @State private var previewReady = false
    @State private var previewIdentity: String?
    @State private var previewRepository: URL?
    @State private var credentials: CredentialConfiguration?
    @State private var keychainConfirm = false
    @State private var pullPrompt: PullOperationPrompt?
    @State private var forcePushPrompt: ForcePushPrompt?
    @State private var preflightPrompt: NetworkPreflightPrompt?
    @State private var remoteNames: [String] = []
    @State private var upstream = ""
    @State private var divergence: (ahead: Int, behind: Int)?
    @State private var outgoing: [OutgoingCommit] = []
    private struct OutgoingCommit: Identifiable {
        let hash: String
        let author: String
        let date: Date
        let subject: String
        var id: String { hash }
        var shortHash: String { String(hash.prefix(8)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            DesignPageHeading(title: networkText("title"), subtitle: designText("Synchronize with your remote repository"), icon: "arrow.triangle.branch")
                .padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(networkText("operation"), selection: $operation) {
                        Text(networkText("fetch")).tag(NetworkOperation.fetch)
                        Text(networkText("pull")).tag(NetworkOperation.pull)
                        Text(networkText("push")).tag(NetworkOperation.pushPreview)
                    }.pickerStyle(.segmented).disabled(task != nil)
                    DesignCard {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack(spacing: 12) {
                                Image(systemName: operation == .pushPreview ? "square.and.arrow.up" : "square.and.arrow.down").font(.system(size: 23))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(networkText(operation == .fetch ? "fetch" : operation == .pull ? "pull" : "push")).font(.system(size: 16, weight: .semibold))
                                    Text(designText(operation == .pushPreview ? "Preview the configured push before executing" : "Use your repository Git configuration")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            HStack {
                                Text(designText("Current branch")).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                DesignActionChip(title: store.branch.isEmpty ? "HEAD" : store.branch)
                                if !upstream.isEmpty { Image(systemName: "arrow.right").foregroundStyle(.secondary); DesignActionChip(title: upstream) }
                                Spacer()
                            }
                            HStack {
                                Text(workflowText("Remote name")).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(remoteNames.isEmpty ? panelText("No configured remotes") : remoteNames.joined(separator: ", ")).textSelection(.enabled)
                                Spacer()
                            }
                            if let divergence {
                                HStack(spacing: 13) {
                                    Image(systemName: divergence.ahead > 0 ? "arrow.up.circle.fill" : "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(designText("Branch comparison")).font(.system(size: 13, weight: .semibold))
                                        Text((store.branch.isEmpty ? "HEAD" : store.branch) + " → " + upstream).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    DesignActionChip(title: designText("Ahead") + " \(divergence.ahead)", color: .green)
                                    DesignActionChip(title: designText("Behind") + " \(divergence.behind)", color: .secondary)
                                }.padding(12).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                if operation == .pushPreview {
                                    HStack {
                                        Text(designText("Commits to push")).font(.system(size: 13, weight: .semibold))
                                        DesignActionChip(title: "\(divergence.ahead)")
                                        Spacer()
                                    }
                                    if outgoing.isEmpty {
                                        Text(designText("No outgoing commits")).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        VStack(spacing: 0) {
                                            ForEach(outgoing.prefix(8)) { commit in
                                                HStack(spacing: 12) {
                                                    Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.blue.opacity(0.55))
                                                    Text(commit.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                                    Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                                                    Spacer()
                                                    Text(commit.author).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 90)
                                                    Text(preferencesDate(commit.date, style: "relative")).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                                                }.padding(.vertical, 8)
                                                Divider()
                                            }
                                        }
                                    }
                                }
                            } else if upstream.isEmpty {
                                Text(designText("No upstream branch is configured")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DesignCard(panelText("Results")) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                if task != nil { ProgressView().controlSize(.small) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(events.last.map { RepositoryStore.progressDetail($0.message) } ?? networkText("progressHint")).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let fraction = events.last?.fraction {
                                        HStack { ProgressView(value: fraction); Text("\(Int(fraction * 100))%").monospacedDigit() }
                                    }
                                }
                                Spacer(minLength: 0)
                                if task != nil { Button(networkText("cancel")) { task?.cancel() } }
                            }
                            Divider()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    if events.isEmpty && output.isEmpty { Text(panelText("Run an operation to view its result.")).foregroundStyle(.secondary) }
                                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in Text(RepositoryStore.progressDetail(event.message)) }
                                    if !output.isEmpty { Text(output) }
                                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 115, maxHeight: 220)
                        }
                    }
                    DesignCard {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "key").font(.system(size: 19)).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(networkText("credentials")).font(.system(size: 13, weight: .semibold))
                                if let credentials {
                                    Text(networkText("helpers") + ": " + (credentials.helpers.isEmpty ? networkText("none") : credentials.helpers.joined(separator: ", "))).font(.system(size: 12))
                                    Text(networkText(credentials.sshAgentAvailable ? "sshAvailable" : "sshHint")).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(networkText("credentialHint")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(networkText("configureKeychain")) { keychainConfirm = true }.disabled(task != nil || store.isBusy || store.repository == nil)
                        }
                    }
                }.padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                if previewReady { Label(designText("Push preview is ready"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                if task != nil {
                    Button(networkText("cancel")) { task?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(networkText("close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if operation == .pushPreview && previewReady {
                    Button(networkText("preview")) { run(operation) }.disabled(task != nil || store.isBusy || store.repository == nil)
                    Button(networkText("executePush")) { run(.push) }.buttonStyle(.borderedProminent).disabled(task != nil || store.isBusy)
                } else {
                    Button(networkText(operation == .pushPreview ? "preview" : "run")) { run(operation) }
                        .buttonStyle(.borderedProminent).disabled(task != nil || store.isBusy || store.repository == nil)
                }
            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 16)
        }.tint(.blue).background(Color(nsColor: .windowBackgroundColor)).frame(width: 800, height: 720)
        .interactiveDismissDisabled(task != nil)
        .task { await loadCredentials(); await loadRepositoryContext() }
        .onChange(of: operation) { _, _ in previewReady = false; events = []; output = "" }
        .onChange(of: store.repositoryURL) { _, _ in authentication.cancel() }
        .onDisappear { task?.cancel(); authentication.cancel() }
        .rayGitSheet(item: $authentication.request) { request in
            RemoteAuthenticationSheet(request: request, error: authentication.submissionError, isSubmitting: authentication.isSubmitting, submit: { submission in
                authentication.submit(submission)
            }, cancel: { authentication.cancel() })
        }
        .rayGitAlert(item: $preflightPrompt) { prompt in
            RayGitAlert(title: networkText("knownStateTitle"), message: networkPreflightMessage(prompt.hint), buttons: [
                RayGitAlertButton(networkText("cancel"), role: .cancel),
                RayGitAlertButton(networkText("verifyRemote")) {
                    guard store.repository === prompt.repository else { return }
                    runVerified(prompt.operation)
                }
            ])
        }
        .rayGitSheet(item: $pullPrompt) { prompt in
            PullOperationConfirmation(hint: prompt.hint) { pullPrompt = nil } execute: { operation in
                pullPrompt = nil
                guard store.repository === prompt.repository else { return }
                runVerified(operation)
            }
        }
        .rayGitSheet(item: $forcePushPrompt) { prompt in
            ForcePushConfirmation(preview: prompt.preview) { forcePushPrompt = nil } execute: {
                forcePushPrompt = nil
                guard store.repository === prompt.repository, !store.isBusy, task == nil else { return }
                runForcePush(prompt)
            }
        }
        .rayGitAlert(networkText("configureKeychain"), isPresented: $keychainConfirm) {
            RayGitAlertButton(networkText("cancel"), role: .cancel) {}
            RayGitAlertButton(networkText("run")) { configureKeychain() }
        } message: { Text(networkText("keychainConfirm")) }
    }
    private func loadCredentials() async {
        guard let repository = store.repository else { return }
        do { credentials = try await repository.credentialConfiguration() } catch { output = OperationFailure.message(error, repository: store.repositoryURL) }
    }
    private func loadRepositoryContext() async {
        guard let repository = store.repository else { return }
        do {
            let names = try await repository.workflowRead(["remote"])
            let tracked = try? await repository.workflowRead(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
            guard store.repositoryURL == repository.url else { return }
            remoteNames = names.split(separator: "\n").map(String.init)
            upstream = tracked?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            divergence = nil; outgoing = []
            if !upstream.isEmpty {
                let counts = try await repository.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
                let values = counts.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                let commitText = try await repository.workflowRead(["log", "-8", "--format=%H%x00%an%x00%at%x00%s", "@{upstream}..HEAD", "--"])
                let commits: [OutgoingCommit] = commitText.split(separator: "\n").compactMap { line in
                    let fields = line.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    guard fields.count == 4, let timestamp = Double(fields[2]) else { return nil }
                    return OutgoingCommit(hash: fields[0], author: fields[1], date: Date(timeIntervalSince1970: timestamp), subject: fields[3])
                }
                guard store.repositoryURL == repository.url else { return }
                if values.count == 2 { divergence = (values[0], values[1]) }
                outgoing = commits
            }
        } catch { output = GitProgressParser.redact(OperationFailure.message(error, repository: store.repositoryURL)) }
    }
    private func progressHandler(for repository: GitRepository, operationID: UUID) -> @Sendable (NetworkProgress) -> Void {
        let footerProgress = store.progressHandler(for: repository, operationID: operationID)
        return { event in
            footerProgress(event)
            Task { @MainActor in
                guard store.repository === repository, store.currentUserOperationID == operationID, store.isBusy else { return }
                events.append(event)
                if events.count > 300 { events.removeFirst(events.count - 300) }
            }
        }
    }
    private func run(_ operation: NetworkOperation) {
        guard let repository = store.repository, !store.isBusy, task == nil else { return }
        if operation == .fetch { runVerified(operation); return }
        store.checkNetworkPreflight(operation) { hint in
            if operation == .pull { pullPrompt = PullOperationPrompt(repository: repository, hint: hint) }
            else if case let .pushBehind(preview) = hint { forcePushPrompt = ForcePushPrompt(repository: repository, preview: preview) }
            else if let hint { preflightPrompt = NetworkPreflightPrompt(operation: operation, repository: repository, hint: hint) }
            else { runVerified(operation) }
        }
    }
    private func runVerified(_ operation: NetworkOperation, credential suppliedCredential: NetworkCredential? = nil,
                             saveCredential: Bool = false, acceptsMigratedPushIdentity: Bool = false) {
        guard let repository = store.repository, !store.isBusy, task == nil else { return }
        let expected = previewReady ? previewIdentity : nil, expectedRepository = previewRepository
        let name = operation == .fetch ? "Fetch" : operation == .pull ? "Pull" : operation == .push ? "Push" : "Push preview"
        store.beginUserOperation(name)
        let operationID = store.currentUserOperationID
        let progress: @Sendable (NetworkProgress) -> Void = progressHandler(for: repository, operationID: operationID)
        store.isBusy = true; events = []; output = ""; previewReady = false
        task = Task { @MainActor in
            await store.cancelBackgroundRepositorySync()
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else { credential = await authentication.savedCredential(for: repository, operation: operation) }
            do { try await authentication.perform(with: credential) { try await GitCommandLog.$operationID.withValue(operationID) { try await GitCommandLog.$userInitiated.withValue(true) { try await GitCommandLog.$progress.withValue(progress) {
                let identity = try await repository.networkPreviewIdentity()
                if operation == .push && !acceptsMigratedPushIdentity && expected != nil && (expected != identity || expectedRepository != repository.url) { throw GitError(networkText("previewExpired")) }
                if operation == .push || operation == .pushPreview {
                    let forcePreview = try await repository.preparePush(credential: credential, verifyRemote: operation == .pushPreview || acceptsMigratedPushIdentity)
                    if let forcePreview {
                        await saveCredentialAfterSuccess(credential, requested: saveCredential, repository: repository, operation: operation)
                        store.finishUserOperation(name, repository: repository, failure: CancellationError())
                        store.isBusy = false; task = nil
                        if store.repository === repository {
                            forcePushPrompt = ForcePushPrompt(repository: repository, preview: forcePreview,
                                                              credential: credential, saveCredential: saveCredential)
                        }
                        return
                    }
                }
                if operation == .pushPreview {
                    let after = try await repository.networkPreviewIdentity()
                    previewReady = after == identity
                    previewIdentity = previewReady ? identity : nil; previewRepository = repository.url
                    output = networkText(previewReady ? "completed" : "previewExpired")
                    await saveCredentialAfterSuccess(credential, requested: saveCredential, repository: repository, operation: operation)
                    store.completeNetworkOperation(name, repository: repository)
                    return
                }
                let result = try await repository.runNetwork(operation, credential: credential, progress: { _ in })
                output = result.output + "\n" + networkText("completed")
                await saveCredentialAfterSuccess(credential, requested: saveCredential, repository: repository, operation: operation)
                store.completeNetworkOperation(name, repository: repository)
            } } } } } catch is CancellationError {
                output = networkText("cancelled")
                store.finishUserOperation(name, repository: repository, failure: CancellationError())
            }
            catch {
                output = GitProgressParser.redact(OperationFailure.message(error, repository: repository.url))
                if (operation == .push || operation == .pushPreview), ForcePushRejection.isNonFastForward(error),
                   let preview = try? await GitCommandLog.$progress.withValue(progress, operation: { try await repository.prepareForcePush(credential: credential) }), store.repository === repository {
                    await saveCredentialAfterSuccess(credential, requested: saveCredential, repository: repository, operation: operation)
                    forcePushPrompt = ForcePushPrompt(repository: repository, preview: preview,
                                                      credential: credential, saveCredential: saveCredential)
                } else {
                    _ = await authentication.presentIfNeeded(error: error, repository: repository, operation: operation) { retry in
                        guard store.repository === repository else { return }
                        runVerified(operation, credential: retry.credential, saveCredential: retry.saveCredential,
                                    acceptsMigratedPushIdentity: retry.acceptsMigratedPushIdentity)
                    }
                }
                store.finishUserOperation(name, repository: repository, failure: error)
            }
            store.isBusy = false; task = nil
            if operation != .pushPreview { await store.refresh() }
            await loadRepositoryContext()
        }
    }
    private func runForcePush(_ prompt: ForcePushPrompt, credential suppliedCredential: NetworkCredential? = nil, saveCredential: Bool = false) {
        guard store.repository === prompt.repository, !store.isBusy, task == nil else { return }
        let name = forcePushText("action")
        store.beginUserOperation(name)
        let operationID = store.currentUserOperationID
        let progress: @Sendable (NetworkProgress) -> Void = progressHandler(for: prompt.repository, operationID: operationID)
        store.isBusy = true; store.error = nil; events = []
        task = Task { @MainActor in
            await store.cancelBackgroundRepositorySync()
            let credential: NetworkCredential?
            if let suppliedCredential { credential = suppliedCredential }
            else if let promptCredential = prompt.credential { credential = promptCredential }
            else { credential = await authentication.savedCredential(for: prompt.repository, operation: .push) }
            let shouldSaveCredential = suppliedCredential == nil ? prompt.saveCredential : saveCredential
            do {
                let result = try await authentication.perform(with: credential) { try await GitCommandLog.$operationID.withValue(operationID) { try await GitCommandLog.$userInitiated.withValue(true) { try await GitCommandLog.$progress.withValue(progress) { try await prompt.repository.forcePush(prompt.preview, credential: credential, progress: { _ in })
                } } } }
                output += "\n" + result.output + "\n" + networkText("completed")
                await saveCredentialAfterSuccess(credential, requested: shouldSaveCredential, repository: prompt.repository, operation: .push)
                store.completeNetworkOperation(forcePushText("action"), repository: prompt.repository)
            } catch is CancellationError {
                output += "\n" + networkText("cancelled")
                store.finishUserOperation(name, repository: prompt.repository, failure: CancellationError())
            }
            catch {
                output += "\n" + GitProgressParser.redact(OperationFailure.message(error, repository: prompt.repository.url))
                _ = await authentication.presentIfNeeded(error: error, repository: prompt.repository, operation: .push) { retry in
                    guard store.repository === prompt.repository else { return }
                    if retry.requiresFreshForcePushPreparation {
                        runVerified(.push, credential: retry.credential, saveCredential: retry.saveCredential,
                                    acceptsMigratedPushIdentity: retry.acceptsMigratedPushIdentity)
                    } else {
                        runForcePush(prompt, credential: retry.credential, saveCredential: retry.saveCredential)
                    }
                }
                store.finishUserOperation(name, repository: prompt.repository, failure: error)
            }
            store.isBusy = false; task = nil
            await store.refresh(); await loadRepositoryContext()
        }
    }
    private func saveCredentialAfterSuccess(_ credential: NetworkCredential?, requested: Bool, repository: GitRepository, operation: NetworkOperation) async {
        guard requested, let credential else { return }
        do { try await authentication.save(credential, for: repository, operation: operation) }
        catch { output += "\n" + OperationFailure.message(error, repository: repository.url) }
    }
    private func configureKeychain() {
        guard let repository = store.repository, !store.isBusy else { return }
        store.isBusy = true
        task = Task { @MainActor in
            await store.cancelBackgroundRepositorySync()
            do { try await repository.configureKeychainHelper(); await loadCredentials() }
            catch { output = OperationFailure.message(error, repository: store.repositoryURL) }
            store.isBusy = false; task = nil
        }
    }
}
