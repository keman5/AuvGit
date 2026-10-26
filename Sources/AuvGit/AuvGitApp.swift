import SwiftUI
import AppKit
import Combine
import GitCore
import AuvGitLocalization

// Routine command completions update the log window without invalidating the entire workspace.
@MainActor
final class RepositoryCommandRecords: ObservableObject {
    @Published var reads: [GitCommandRecord] = []
    @Published var userCommands: [GitCommandRecord] = []
}

@main
struct AuvGitApp: App {
    private let brandMigration: Void = AppBrandMigration.migrate()
    @NSApplicationDelegateAdaptor(AuvGitApplicationDelegate.self) private var appDelegate
    @StateObject private var projects = WorkspaceProjects()
    private var store: RepositoryStore { projects.active }
    @AppStorage(L10n.preferenceKey) private var languageCode = AppLanguage.system.rawValue
    @StateObject private var shortcuts = KeyboardShortcuts.shared
    private var workspaceActive: Bool {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return false }
        return window.contentView.map { containsWorkspaceRegion($0) } ?? false
    }
    private func containsWorkspaceRegion(_ view: NSView) -> Bool {
        if view is WorkspaceKeyboardRegion.RegionView, !view.isHiddenOrHasHiddenAncestor { return true }
        return view.subviews.contains { containsWorkspaceRegion($0) }
    }
    private func sendWorkspaceShortcut(_ command: ShortcutCommand) {
        guard workspaceActive, let window = NSApp.keyWindow else { return }
        NotificationCenter.default.post(name: .auvGitWorkspaceShortcut, object: command.rawValue, userInfo: ["window": window])
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceProjectsView(projects: projects)
                .nativeFocusRoot()
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 1000)
                .task { appDelegate.store = store; store.setApplicationActive(NSApp.isActive); AuvGitPreferences.applyAppearance(); await store.restore() }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in AuvGitPreferences.applyAppearance() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Open Repository…")) { store.chooseRepository() }.configuredShortcut(.open, using: shortcuts)
            }
            CommandGroup(after: .newItem) {
                Button(logText("Log")) { LogPresenter.showForCurrentWindow(fallback: store.repository) }.configuredShortcut(.viewLog, using: shortcuts)
                    .disabled(store.repository == nil && !LogPresenter.hasWindows)
                Button(L10n.text("Refresh Repository")) { if !LogPresenter.refreshCurrentWindow() { sendWorkspaceShortcut(.refresh) } }.configuredShortcut(.refresh, using: shortcuts)
                    .disabled(!LogPresenter.isLogWindowActive && (!workspaceActive || store.repository == nil || store.isBusy))
                Button(L10n.text("Refresh Repository")) { if !LogPresenter.refreshCurrentWindow() { sendWorkspaceShortcut(.refresh) } }.configuredShortcut(.refreshAlternate, using: shortcuts)
                    .disabled(!LogPresenter.isLogWindowActive && (!workspaceActive || store.repository == nil || store.isBusy))
                Button(L10n.text("stage", table: "Main")) { sendWorkspaceShortcut(.stage) }.configuredShortcut(.stage, using: shortcuts)
                    .disabled(!workspaceActive || !store.canStageSelection)
                Button(L10n.text("unstage", table: "Main")) { sendWorkspaceShortcut(.unstage) }
                    .configuredShortcut(.unstage, using: shortcuts)
                    .disabled(!workspaceActive || !store.canUnstageSelection)
                Button(compareText("Commit")) { sendWorkspaceShortcut(.commit) }.configuredShortcut(.commit, using: shortcuts)
                    .disabled(!workspaceActive || store.repository == nil || store.isBusy)
            }
        }
        Settings {
            PreferencesWindow(store: store)
                .background(WindowFrameStyle())
                .nativeFocusRoot()
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 860, height: 660)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class RepositoryStore: ObservableObject {
    let sessionIdentity = UUID()
    weak var workspaceProjects: WorkspaceProjects?
    var persistsWorkspaceSession: Bool { persistsSession }
    func makeWorkspaceProjectStore() -> RepositoryStore {
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: .shared)
        let owner = workspaceProjects?.sessions.first ?? self
        store.session = owner.session
        store.historyMemoryCache = owner.historyMemoryCache
        store.recentPaths = recentPaths
        store.openRepositories = openRepositories
        store.repositoryGroups = repositoryGroups
        store.repositoryChangeCounts = owner.repositoryChangeCounts
        store.repositorySyncStates = owner.repositorySyncStates
        return store
    }
    lazy var creationOperation = RepositoryCreationOperation(store: self)

    func creationProgressHandler(operationID: UUID) -> @Sendable (NetworkProgress) -> Void {
        progressOperationID = operationID; progressRepository = repositoryURL
        return { [weak self] event in
            Task { @MainActor in
                guard let self, self.currentUserOperationID == operationID, self.isBusy else { return }
                self.liveProgress = event
            }
        }
    }
    private struct HistoryMemorySnapshot {
        let files: [GitFile]
        let filesGeneration: UUID
        let branches: [GitBranch]
        let branch: String
        let stashes: [GitStash]
        let observedState: RepositoryChangeState?
        let historyState: String?
        let mainHistoryHead: String?
        let historyScope: [String]?
        let commits: [GitCommit]
        let loadedCount: Int
        let hasMore: Bool
        let localUnpushedCommitHashes: Set<String>?
        let viewState: RepositoryViewState
        let commitFiles: [GitCommitFile]
        let diffText: String
        let staticPreview: FileComparisonSnapshot?
        let conflictPreview: FileComparisonSnapshot?
        let diffIdentity: String?
        let diffFilename: String?
        let diffLeft: String?
        let diffRight: String?
        let diffTitle: String
        let diffArguments: [String]
        let retainedBytes: Int
        var workspaceStatusFailure: String? = nil
    }

    @Published var repository: GitRepository? {
        didSet { if oldValue !== repository { repositoryOperation = nil; recreatableConflicts = [] } }
    }
    @Published var recreatableConflicts: Set<String> = []
    @Published var repositoryOperation: RepositoryOperationState?
    @Published var repositoryURL: URL?
    @Published var openRepositories: [String] = []
    @Published var repositoryGroups = UserDefaults.standard.dictionary(forKey: "repositoryGroups") as? [String: String] ?? [:]
    private let persistsSession: Bool
    let commitHistory: CommitMessageHistory
    private var accessedURL: URL?
    private var fileObserver: RepositoryFileObserver?
    private var filesystemRefresh: Task<Void, Never>?
    private var filesystemRefreshing = false
    private var filesystemPending = false
    private var automaticRefreshTask: Task<Void, Never>?
    private var automaticRefreshVersion = UUID()
    private(set) var applicationActive = true
    private var lastAutomaticRefresh = Date.distantPast
    private var activationTask: Task<Void, Never>?
    private var activationVersion = UUID()
    private let sessionKey = "repositorySession.v1"
    private var session = RepositorySession()
    private var sessionObserver: AnyCancellable?
    private var commandObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var lastSavedSession: Data?
    var isRestoringViewState = false
    let followsCurrentBranch: Bool
    private let usesCheckedHistoryScope: Bool
    private let presentationCache: RepositoryPresentationCache?
    private var lastMainHistoryHead: String?
    init(persistsSession: Bool = true, followsCurrentBranch: Bool? = nil, usesCheckedHistoryScope: Bool = false,
         commitHistoryDefaults: UserDefaults = .standard, presentationCache: RepositoryPresentationCache? = nil) {
        self.persistsSession = persistsSession
        self.presentationCache = presentationCache ?? (persistsSession ? .shared : nil)
        self.commitHistory = CommitMessageHistory(defaults: commitHistoryDefaults)
        self.followsCurrentBranch = followsCurrentBranch ?? persistsSession
        self.usesCheckedHistoryScope = usesCheckedHistoryScope
        Self.stores.add(self)
        if !persistsSession, let main = Self.stores.allObjects.first(where: { $0.persistsSession }) {
            applicationActive = main.applicationActive
        }
        if persistsSession { showMergedCommits = UserDefaults.standard.bool(forKey: "history.workspaceShowMergedCommits") }
        failureObserver = NotificationCenter.default.publisher(for: OperationFailure.notification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let event = notification.object as? OperationFailure.Event,
                      event.repository.map({ $0 == self.repositoryURL }) ?? self.persistsSession else { return }
                self.report(GitError(event.message))
                if !self.commandLog.prefix(3).contains(where: { $0.error == event.message }) {
                    self.commandLog.insert(GitCommandLog.applicationFailure(directory: event.repository ?? self.repositoryURL, message: event.message), at: 0)
                    if self.commandLog.count > 300 { self.commandLog.removeLast() }
                }
            }
        commandObserver = NotificationCenter.default.publisher(for: GitCommandLog.notification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let record = notification.object as? GitCommandRecord,
                      self.repositoryURL == nil || self.repositoryURL?.path == record.directory || self.openingRepositoryPath == record.directory || (record.userInitiated && record.operationID == self.currentUserOperationID) else { return }
                if record.userInitiated {
                    self.userCommandLog.insert(record, at: 0)
                    if self.userCommandLog.count > 1000 { self.userCommandLog.removeLast(self.userCommandLog.count - 1000) }
                    return
                }
                self.commandLog.insert(record, at: 0)
                if self.commandLog.count > 300 { self.commandLog.removeLast(self.commandLog.count - 300) }
            }
        guard persistsSession else { return }
        let recovery = RepositorySession.recover(primary: UserDefaults.standard.data(forKey: sessionKey), backup: UserDefaults.standard.data(forKey: sessionKey + ".backup"))
        session = recovery.session; openRepositories = AuvGitPreferences.restoreRepositories ? session.openRepositories : []; lastSavedSession = recovery.source
        if let corrupt = recovery.corruptPrimary { UserDefaults.standard.set(corrupt, forKey: sessionKey + ".corrupt") }
        sessionObserver = objectWillChange.debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] _ in self?.flushSession() }
    }
    /// A Log window owns this transient store, not the main workspace session.
    func closeTransientSession() {
        guard !persistsSession else { return }
        cancelAutomaticRefresh()
        projectPreparationTask?.cancel(); projectPreparationTask = nil
        recentSyncTask?.cancel(); recentSyncTask = nil
        activationTask?.cancel(); activationTask = nil
        openingTask?.cancel(); openingTask = nil; openingVersion = UUID()
        fileObserver = nil
        filesystemRefresh?.cancel(); filesystemRefresh = nil
        searchTask?.cancel(); searchTask = nil
        diffTask?.cancel(); diffTask = nil
        repoVersion = UUID(); historyVersion = UUID(); detailVersion = UUID(); diffVersion = UUID()
        accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = nil
        repository = nil; repositoryURL = nil; localUnpushedCommitHashes = nil; recentCommitMessages = []
    }
    private func captureViewState() -> RepositoryViewState {
        var value = RepositoryViewState()
        value.commitMessage = commitMessage; value.amend = amend; value.historySearch = historySearch; value.historyAuthor = historyAuthor
        value.historyPath = historyPath; value.historyRef = historyRef; value.selectedPaths = selectedPaths
        value.selectedCommit = selectedCommit; value.selectedCommitPath = selectedCommitPath; value.mode = mode; value.fileFilter = fileFilter
        value.stagedDiff = stagedDiff; value.ignoreWhitespace = ignoreWhitespace
        return value
    }
    func flushSession() {
        if !persistsSession, let owner = workspaceProjects?.sessions.first, owner !== self {
            owner.flushSession()
            return
        }
        guard persistsSession, !isRestoringViewState, repositoryURL != nil || AuvGitPreferences.restoreRepositories else { return }
        if let path = repositoryURL?.path { session.repositories[path] = captureViewState() }
        if let workspaceProjects {
            for store in workspaceProjects.sessions where !store.isRestoringViewState {
                if let path = store.repositoryURL?.path { session.repositories[path] = store.captureViewState() }
            }
            session.openRepositories = Array(Set(workspaceProjects.sessions.flatMap(\.openRepositories))).sorted()
            session.activeRepository = workspaceProjects.active.repositoryURL?.path
            if let data = try? session.encoded(), data != lastSavedSession {
                if let previous = lastSavedSession { UserDefaults.standard.set(previous, forKey: sessionKey + ".backup") }
                UserDefaults.standard.set(data, forKey: sessionKey); lastSavedSession = data
            }
            return
        }
        session.openRepositories = openRepositories; session.activeRepository = repositoryURL?.path ?? (openRepositories.isEmpty ? nil : session.activeRepository)
        if let data = try? session.encoded(), data != lastSavedSession { if let previous = lastSavedSession { UserDefaults.standard.set(previous, forKey: sessionKey + ".backup") }; UserDefaults.standard.set(data, forKey: sessionKey); lastSavedSession = data }
    }
    private func applyViewState(_ value: RepositoryViewState) {
        commitMessage = value.commitMessage; amend = value.amend; historySearch = value.historySearch; historyAuthor = value.historyAuthor
        historyPath = followsCurrentBranch ? nil : value.historyPath; historyRef = followsCurrentBranch ? nil : value.historyRef; selectedPaths = value.selectedPaths
        selectedCommit = value.selectedCommit; selectedCommitPath = value.selectedCommitPath; mode = persistsSession ? "workspace" : value.mode; fileFilter = value.fileFilter
        stagedDiff = value.stagedDiff; ignoreWhitespace = value.ignoreWhitespace
    }
    func closeRepositoryTab(_ path: String) {
        guard !isBusy else { return }
        if repositoryURL?.path == path { session.repositories[path] = captureViewState() }
        historyMemoryCache.removeValue(forKey: path)
        openRepositories.removeAll { $0 == path }
        guard repositoryURL?.path == path else { flushSession(); return }
        cancelAutomaticRefresh()
        fileObserver = nil; filesystemRefresh?.cancel(); repository = nil; repositoryURL = nil
        files = []; commits = []; localUnpushedCommitHashes = nil; branches = []; stashes = []; commitFiles = []; selectedPaths = []; selectedCommit = nil; selectedCommitPath = nil
        commitMessage = ""; amend = false; recentCommitMessages = []; accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = nil
        let candidates = Array(openRepositories.reversed()); session.activeRepository = candidates.first; flushSession()
        guard workspaceProjects == nil || workspaceProjects?.active === self else { return }
        Task {
            for candidate in candidates {
                let url = URL(fileURLWithPath: candidate)
                let missing = await Task.detached(priority: .userInitiated) { Self.repositoryRootIsMissing(url) }.value
                guard repository == nil, !isBusy, pendingRepositoryPath == nil,
                      workspaceProjects == nil || workspaceProjects?.active === self else { return }
                if missing { continue }
                await open(url, promptsIfUnavailable: false)
                if (workspaceProjects?.active ?? self).repository != nil { return }
            }
        }
    }
    func setGroup(path: String, group: String) { repositoryGroups[path] = group; UserDefaults.standard.set(repositoryGroups, forKey: "repositoryGroups") }
    @Published var recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    @Published var repositoryChangeCounts: [String: Int] = [:]
    struct RepositorySyncState: Equatable { let ahead: Int?; let behind: Int?; let conflicts: Int }
    @Published var repositorySyncStates: [String: RepositorySyncState] = [:]
    private func publishRepositoryChangeCount(_ count: Int, path: String) {
        var targets = workspaceProjects?.sessions ?? [self]
        if !targets.contains(where: { $0 === self }) { targets.append(self) }
        for target in targets where target.repositoryChangeCounts[path] != count {
            target.repositoryChangeCounts[path] = count
        }
    }
    private func publishRepositorySyncState(_ state: RepositorySyncState, path: String) {
        var targets = workspaceProjects?.sessions ?? [self]
        if !targets.contains(where: { $0 === self }) { targets.append(self) }
        for target in targets where target.repositorySyncStates[path] != state {
            target.repositorySyncStates[path] = state
        }
    }
    let commandRecords = RepositoryCommandRecords()
    private var commandLog: [GitCommandRecord] {
        get { commandRecords.reads }
        set { commandRecords.reads = newValue }
    }
    @Published private var userOperationLog: [GitCommandRecord] = []
    private var userCommandLog: [GitCommandRecord] {
        get { commandRecords.userCommands }
        set { commandRecords.userCommands = newValue }
    }
    var operationLog: [GitCommandRecord] {
        let actions = userOperationLog.sorted { $0.date > $1.date }
        let details = (commandLog + userCommandLog).sorted { $0.date > $1.date }
        return actions + details
    }
    @Published private var latestOperationKey: String?
    @Published private var latestOperationName = ""
    var hasLatestOperation: Bool { latestOperationKey != nil }
    private var operationStarted = Date()
    private(set) var currentUserOperationID = UUID()
    @Published private(set) var liveProgress: NetworkProgress?
    private var progressOperationID: UUID?
    private var progressRepository: URL?
    var visibleProgress: NetworkProgress? { progressRepository == repositoryURL ? liveProgress : nil }
    var footerStatus: String {
        if let liveProgress, progressRepository == repositoryURL {
            let detail = Self.progressDetail(liveProgress.message)
            return detail.isEmpty ? status : detail
        }
        if !hasLatestOperation, error == nil, statusKey == "Refreshed · %@ changes · %@ staged" {
            return L10n.text("Refreshed", table: "OperationLog")
        }
        return displayStatus
    }
    static func progressDetail(_ message: String) -> String {
        if message.hasPrefix("remote: ") { return L10n.text("remote", table: "OperationLog") + ": " + progressDetail(String(message.dropFirst(8))) }
        guard let colon = message.firstIndex(of: ":") else { return L10n.text(message, table: "OperationLog") }
        return L10n.text(String(message[..<colon]), table: "OperationLog") + message[colon...]
    }
    var displayStatus: String {
        if let error { return hasLatestOperation ? status + ": " + error : error }
        return status
    }
    func commands(for operation: GitCommandRecord) -> [GitCommandRecord] {
        guard operation.command.isEmpty, let id = operation.operationID else { return [] }
        return userCommandLog.filter { $0.operationID == id }.sorted { $0.date < $1.date }
    }
    func beginUserOperation(_ name: String) {
        liveProgress = nil; progressOperationID = nil; progressRepository = nil
        currentUserOperationID = UUID(); operationStarted = Date(); latestOperationName = name; latestOperationKey = "%@…"; errorMessage = nil
    }
    func progressHandler(for repository: GitRepository, operationID: UUID) -> @Sendable (NetworkProgress) -> Void {
        progressOperationID = operationID; progressRepository = repository.url
        return { [weak self] event in
            Task { @MainActor in self?.receiveProgress(event, repository: repository, operationID: operationID) }
        }
    }
    func receiveProgress(_ event: NetworkProgress, repository: GitRepository, operationID: UUID) {
        guard progressOperationID == operationID, currentUserOperationID == operationID,
              self.repository === repository, isBusy else { return }
        liveProgress = event
    }
    func finishUserOperation(_ name: String, repository: GitRepository, failure: Error? = nil, reportInCurrentWindow: Bool = false) {
        liveProgress = nil; progressOperationID = nil; progressRepository = nil
        let cancelled = failure is CancellationError
        let message = cancelled ? nil : failure.map { GitCommandLog.redact($0.localizedDescription) }
        userOperationLog.insert(GitCommandLog.userOperation(directory: repository.url, name: name, started: operationStarted, error: message, cancelled: cancelled, operationID: currentUserOperationID), at: 0)
        if userOperationLog.count > 1000 { userOperationLog.removeLast(userOperationLog.count - 1000) }
        guard reportInCurrentWindow || self.repository === repository else { return }
        latestOperationName = name
        latestOperationKey = cancelled ? "%@ cancelled" : (failure == nil ? "%@ completed" : "%@ failed")
        if let failure, !cancelled { report(failure) }
    }
    @Published var files: [GitFile] = []
    @Published var filesGeneration = UUID()
    @Published var branches: [GitBranch] = []
    @Published var stashes: [GitStash] = []
    @Published var branch = ""
    @Published var commits: [GitCommit] = []
    @Published var localUnpushedCommitHashes: Set<String>?
    @Published var commitFiles: [GitCommitFile] = []
    @Published var selectedPaths: Set<String> = []
    @Published private(set) var automaticallySelectedPath: String?
    @Published private(set) var initialWorkspaceSelectionReady = false
    @Published var historyNavigationGeneration = UUID()
    @Published var historyStashRef: String?
    @Published var historyStashHash: String?
    private var activeDetailStashHash: String?
    private var stashUntrackedPaths = Set<String>()
    @Published var staticPreview: FileComparisonSnapshot?
    @Published var selectedCommit: String?
    @Published var selectedCommitPath: String?
    @Published var mode = "workspace"
    var showsWorkspaceTree = false
    @Published var stagedDiff = false
    @Published var ignoreWhitespace = false
    @Published private var diffRevisionFilename: String?
    @Published private var diffLeftRevision: String?
    @Published private var diffRightRevision: String?
    var diffLeftRevisionTitle: String? { formattedRevisionTitle(diffLeftRevision) }
    var diffRightRevisionTitle: String? { formattedRevisionTitle(diffRightRevision) }
    private func formattedRevisionTitle(_ revision: String?) -> String? {
        guard let revision, let name = diffRevisionFilename else { return nil }
        let title: String
        switch revision {
        case "$index": title = L10n.text("index", table: "Files")
        case "$worktree": title = L10n.text("workspace", table: "Files")
        case "$empty": title = historyRefinementText("Empty tree")
        default: title = revision
        }
        return name + " - " + title
    }
    @Published var diffText = ""
    @Published var conflictPreview: FileComparisonSnapshot?
    @Published private var diffTitleKey = "Select a file to view changes"
    @Published private var diffTitleArguments: [String] = []
    var diffTitle: String { L10n.text(diffTitleKey, arguments: diffTitleArguments.map { $0 as CVarArg }) }
    @Published var fileFilter = ""
    @Published var historySearch = ""
    @Published var historyAuthor = ""
    @Published var showMergedCommits = false
    @Published var historyPath: String?
    @Published var historyRef: String?
    @Published var checkedHistoryRefs: Set<String>?
    var visibleHistoryRemoteBranchNames: Set<String> {
        HistoryBranchScope.remoteBranchNames(in: followsCurrentBranch ? [] : checkedHistoryRefs ?? [], branches: branches)
    }
    @Published var historyPinnedCommit: String?
    @Published var commitMessage = ""
    @Published var recentCommitMessages: [String] = []
    @Published var workspaceCommitRequest: WorkspaceCommitRequest?
    @Published var amend = false
    @Published var isBusy = false
    @Published var loadingDiff = false
    @Published var loadingHistory = false
    @Published var hasMore = false
    @Published private var statusKey = "Open a Git repository to begin"
    @Published private var statusArguments: [String] = []
    var status: String { latestOperationKey.map { L10n.text($0, arguments: [operationName(latestOperationName)]) } ?? L10n.text(statusKey, arguments: statusArguments.map { operationName($0) as CVarArg }) }
    @Published private var errorMessage: String?
    @Published private(set) var workspaceStatusFailure: String?
    var error: String? {
        get { errorMessage.map(localizedError) }
        set { errorMessage = newValue }
    }
    @Published private var activityRecords: [(date: Date?, operation: String?, error: String?)] = []
    var activity: [String] {
        activityRecords.map { record in
            if let operation = record.operation, let date = record.date {
                return "\(date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale)))  " + L10n.text("%@ completed", arguments: [operationName(operation)])
            }
            return localizedError(record.error ?? "")
        }
    }
    private func setStatus(_ key: String, arguments: [String] = []) { if statusKey != key { statusKey = key }; if statusArguments != arguments { statusArguments = arguments } }
    private func setDiffTitle(_ key: String, arguments: [String] = []) { if diffTitleKey != key { diffTitleKey = key }; if diffTitleArguments != arguments { diffTitleArguments = arguments } }
    private func operationName(_ name: String) -> String { L10n.text(name) }
    private func localizedError(_ message: String) -> String {
        if let summary = GitFailureSummary.message(for: message, localize: { L10n.text($0, table: "OperationLog") }) { return summary }
        let owned = ["Git operation timed out after 120 seconds.", "Git exited but an external helper kept its output stream open.", "Git output exceeds the 32 MB display limit."]
        if owned.contains(message) { return L10n.text(message) }
        if message.hasPrefix("Git command failed ("), message.hasSuffix(").") {
            return L10n.text("Git command failed (%@).", arguments: [String(message.dropFirst(20).dropLast(2))])
        }
        return message
    }
    private var restored = false
    private var repoVersion = UUID()
    private var diffVersion = UUID()
    private var diffTask: Task<Void, Never>?
    private var historyVersion = UUID()
    private var selectFirstHistoryCommit = false
    private var historyMemoryCache: [String: HistoryMemorySnapshot] = [:]
    private var loadedHistoryScope: [String]?
    private var currentHistoryScope: [String] {
        [historySearch, historyAuthor, String(describing: historyPath), String(describing: historyRef),
         String(describing: historyPinnedCommit), String(describing: historyStashHash), String(showMergedCommits)]
        + (checkedHistoryRefs?.sorted() ?? [])
    }
    private var historyRestoreDepth: Int?
    private var openingFallback: (repository: GitRepository?, url: URL?, snapshot: HistoryMemorySnapshot)?
    private var publishedOpeningVersion: UUID?
    private var openingRepositoryPath: String?
    @Published private(set) var pendingRepositoryPath: String?
    struct UnavailableRepository: Identifiable, Equatable {
        let path: String
        var id: String { path }
    }
    @Published var unavailableRepository: UnavailableRepository?
    var highlightedRepositoryPath: String? { pendingRepositoryPath ?? repositoryURL?.path }
    private var openingVersion = UUID()
    private var openingTask: Task<Void, Never>?
    var canOpenRepository: Bool { workspaceProjects != nil || !isBusy || openingRepositoryPath != nil }
    private var recentSyncTask: Task<Void, Never>?
    private var recentSyncDate = Date.distantPast
    private var immediateRemoteSyncPaths: [String] = []
    var nextRemoteSync: [String: Date] = [:]
    private static let stores = NSHashTable<RepositoryStore>.weakObjects()
    private var refreshingRepository: URL?
    private var refreshReadVersion = UUID()
    private var displayedDiffIdentity: String?
    private var detailVersion = UUID()
    private var searchTask: Task<Void, Never>?
    private var historyLoadedCount = 0
    var selectedFile: GitFile? { files.first { $0.path == selectedPaths.sorted().first } }
    func usesStagedDiff(for file: GitFile) -> Bool {
        file.isStaged && (!file.isUnstaged || stagedDiff)
    }
    var effectiveStagedDiff: Bool { selectedFile.map { usesStagedDiff(for: $0) } ?? stagedDiff }
    var filteredFiles: [GitFile] { files.filter { fileFilter.isEmpty || AuvGitPreferences.matches($0.path, query: fileFilter) } }
    var stagedCount: Int { files.filter { $0.isStaged && !$0.isConflict }.count }

    func restore() async {
        guard !restored else { return }; restored = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--repo"), args.indices.contains(i + 1) {
            await open(URL(fileURLWithPath: args[i + 1]), promptsIfUnavailable: false)
        } else if AuvGitPreferences.restoreRepositories {
            let candidates = session.restorationCandidates().isEmpty ? recentPaths : session.restorationCandidates()
            var failures: [String] = []
            for path in candidates {
                await open(URL(fileURLWithPath: path), promptsIfUnavailable: false)
                if repository != nil { break }
                failures.append(path)
            }
            if !failures.isEmpty { errorMessage = sessionText("Unavailable repositories") + "\n" + failures.joined(separator: "\n") }
        }
    }
    private func defaultViewState() -> RepositoryViewState {
        var value = RepositoryViewState(); value.mode = persistsSession || followsCurrentBranch ? "workspace" : "history"; return value
    }
    func clearRecentRepositories() { recentPaths = []; UserDefaults.standard.removeObject(forKey: "recentRepositories"); workspaceProjects?.synchronizeProjectList(from: self) }
    private func registerRepositoryPaths(_ paths: [String]) {
        var added: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if !openRepositories.contains(where: { Self.sameRepositoryLocation(URL(fileURLWithPath: $0), url) }) { openRepositories.append(path) }
            if !recentPaths.contains(where: { Self.sameRepositoryLocation(URL(fileURLWithPath: $0), url) }) {
                recentPaths.append(path)
                added.append(path)
            }
        }
        if persistsSession { UserDefaults.standard.set(recentPaths, forKey: "recentRepositories") }
        workspaceProjects?.synchronizeProjectList(from: self)
        if !added.isEmpty {
            let owner = workspaceProjects?.sessions.first(where: { $0.persistsSession }) ?? self
            owner.refreshRecentRepositoryStates(addedPaths: added)
        }
    }
    func clearSessionDrafts() {
        session.repositories = [:]; commitMessage = ""; amend = false
        for suffix in ["", ".backup", ".corrupt"] { UserDefaults.standard.removeObject(forKey: sessionKey + suffix) }
        lastSavedSession = nil; flushSession()
    }
    func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L10n.text("Open Repository"); panel.message = L10n.text("Choose a Git repository folder")
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }
    @discardableResult
    func requestOpen(_ url: URL, promptsIfUnavailable: Bool = true) -> Task<Void, Never>? {
        if let workspaceProjects {
            return workspaceProjects.open(url, from: self, promptsIfUnavailable: promptsIfUnavailable)
        }
        return requestOpenInSession(url, promptsIfUnavailable: promptsIfUnavailable)
    }
    @discardableResult
    func requestOpenInSession(_ url: URL, promptsIfUnavailable: Bool = true) -> Task<Void, Never>? {
        guard canOpenRepository else { return nil }
        openingTask?.cancel()
        let version = UUID(); openingVersion = version
        let path = url.standardizedFileURL.path
        let task: Task<Void, Never>
        if !isBusy, let current = repositoryURL, current.standardizedFileURL.path != path, historyMemoryCache[path] == nil {
            task = Task {
                let same = await Task.detached(priority: .userInitiated) { Self.sameRepositoryLocation(url, current) }.value
                guard !Task.isCancelled, openingVersion == version, canOpenRepository else {
                    if openingVersion == version { openingTask = nil }
                    return
                }
                // Decode before changing observed state so a disk hit paints the target only once.
                if !same, let saved = await loadSavedPresentation(url) {
                    guard !Task.isCancelled, openingVersion == version, canOpenRepository else { return }
                    storeHistorySnapshot(saved, for: path, persist: false)
                }
                guard !Task.isCancelled, openingVersion == version, canOpenRepository else { return }
                beginOpeningPresentation(url, version: version, isCurrentLocation: same)
                await performOpen(url, version: version, promptsIfUnavailable: promptsIfUnavailable)
            }
        } else {
            beginOpeningPresentation(url, version: version, isCurrentLocation: repositoryURL?.standardizedFileURL.path == path)
            task = Task { await performOpen(url, version: version, promptsIfUnavailable: promptsIfUnavailable) }
        }
        openingTask = task
        return task
    }
    private func beginOpeningPresentation(_ url: URL, version: UUID, isCurrentLocation: Bool) {
        unavailableRepository = nil
        pendingRepositoryPath = url.path
        let path = url.standardizedFileURL.path
        if isBusy || !isCurrentLocation {
            cancelAutomaticRefresh()
            if openingFallback == nil { openingFallback = (repository, repositoryURL, currentHistorySnapshot()) }
            if let current = repositoryURL?.path, !isBusy {
                session.repositories[current] = captureViewState()
                cacheCurrentHistory(for: current)
            }
            flushSession()
            refreshReadVersion = UUID(); refreshingRepository = nil
            repoVersion = UUID(); historyVersion = UUID(); detailVersion = UUID(); diffVersion = UUID()
            diffTask?.cancel(); diffTask = nil; fileObserver = nil
            filesystemRefresh?.cancel(); searchTask?.cancel()
            openingRepositoryPath = url.path; isRestoringViewState = true; isBusy = true
            errorMessage = nil; latestOperationKey = nil; setStatus("Opening repository…")
            if let snapshot = historyMemoryCache[path] {
                repository = GitRepository(url: URL(fileURLWithPath: path)); repositoryURL = repository?.url
                restoreHistorySnapshot(snapshot)
                publishedOpeningVersion = version
            }
        }
    }
    func open(_ url: URL, promptsIfUnavailable: Bool = true) async {
        guard let task = requestOpen(url, promptsIfUnavailable: promptsIfUnavailable) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performOpen(_ url: URL, version: UUID, promptsIfUnavailable: Bool) async {
        guard openingVersion == version else { return }
        var selectedURL = url
        if let data = UserDefaults.standard.data(forKey: "bookmark:" + url.path) {
            var stale = false
            if let restored = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) { selectedURL = restored }
        }
        let accessed = selectedURL.startAccessingSecurityScopedResource()
        var completed = false
        defer { if !completed, accessed { selectedURL.stopAccessingSecurityScopedResource() } }
        let registered = recentPaths.contains(url.path) || openRepositories.contains(url.path) || repositoryURL?.path == url.path
        var missing = false
        if registered {
            let root = selectedURL
            missing = await Task.detached(priority: .userInitiated) { Self.repositoryRootIsMissing(root) }.value
        }
        guard openingVersion == version, !Task.isCancelled else {
            if openingVersion == version { restoreInterruptedOpening(); pendingRepositoryPath = nil; openingTask = nil }
            return
        }
        if registered, missing {
            restoreInterruptedOpening()
            pendingRepositoryPath = nil; openingTask = nil
            report(GitError("fatal: not a git repository (or any of the parent directories): .git"))
            if promptsIfUnavailable { unavailableRepository = UnavailableRepository(path: url.path) }
            return
        }
        if !isBusy, !isRestoringViewState, let repositoryURL, Self.sameRepositoryLocation(url, repositoryURL) {
            defer { if openingVersion == version { pendingRepositoryPath = nil; openingTask = nil } }
            await refreshFileStatus()
            return
        }
        if openingFallback == nil { openingFallback = (repository, repositoryURL, currentHistorySnapshot()) }
        let fallback = openingFallback!
        if let path = repositoryURL?.path, !isBusy {
            session.repositories[path] = captureViewState()
            cacheCurrentHistory(for: path)
        }
        if openingRepositoryPath != url.path {
            cancelAutomaticRefresh()
            flushSession()
            refreshReadVersion = UUID(); refreshingRepository = nil
            repoVersion = UUID(); historyVersion = UUID(); detailVersion = UUID(); diffVersion = UUID()
            diffTask?.cancel(); diffTask = nil
            fileObserver = nil; filesystemRefresh?.cancel(); searchTask?.cancel()
            openingRepositoryPath = url.path
            isRestoringViewState = true
            isBusy = true; errorMessage = nil; latestOperationKey = nil; setStatus("Opening repository…")
        }
        var needsWorkspaceComparison = false
        defer {
            if openingVersion == version {
                if !completed {
                    repository = fallback.repository; repositoryURL = fallback.url
                    restoreHistorySnapshot(fallback.snapshot)
                    if let root = fallback.url { observeRepository(root) }
                    if errorMessage == nil { setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)]) }
                }
                openingRepositoryPath = nil; pendingRepositoryPath = nil; isBusy = false
                isRestoringViewState = false; openingTask = nil; openingFallback = nil; flushSession()
                publishedOpeningVersion = nil
            }
        }
        do {
            guard !Task.isCancelled else { return }
            if historyMemoryCache[selectedURL.path] == nil, let saved = await loadSavedPresentation(selectedURL) {
                guard !Task.isCancelled, openingVersion == version else { return }
                storeHistorySnapshot(saved, for: selectedURL.path, persist: false)
            }
            var cachedPath: String? = historyMemoryCache[selectedURL.standardizedFileURL.path] != nil ? selectedURL.standardizedFileURL.path : nil
            if cachedPath == nil {
                let paths = Array(historyMemoryCache.keys), root = selectedURL
                cachedPath = await Task.detached(priority: .userInitiated) {
                    paths.first { Self.sameRepositoryLocation(URL(fileURLWithPath: $0), root) }
                }.value
                guard !Task.isCancelled, openingVersion == version else { return }
            }
            let repo: GitRepository
            if let cachedPath, let snapshot = historyMemoryCache[cachedPath] {
                // Publish the known root before validation; cached content stays read-only until fresh reads finish.
                repo = GitRepository(url: URL(fileURLWithPath: cachedPath))
                if publishedOpeningVersion != version {
                    repository = repo; repositoryURL = repo.url
                    restoreHistorySnapshot(snapshot)
                    automaticallySelectedPath = nil; initialWorkspaceSelectionReady = true
                }
                let validated = try await GitRepository.open(selectedURL)
                guard !Task.isCancelled, openingVersion == version else { return }
                guard Self.sameRepositoryLocation(validated.url, repo.url) else {
                    throw GitError("fatal: not a git repository (or any of the parent directories): .git")
                }
                needsWorkspaceComparison = await refreshOpeningRepository(repo, version: version)
                guard !Task.isCancelled, openingVersion == version else { return }
                guard repository != nil else { throw GitError(errorMessage ?? "Could not open repository") }
                if needsWorkspaceComparison { loadingDiff = true }
            } else {
                repo = try await GitRepository.open(selectedURL)
                guard !Task.isCancelled, openingVersion == version else { return }
                if registered, !Self.sameRepositoryLocation(repo.url, selectedURL) {
                    throw GitError("fatal: not a git repository (or any of the parent directories): .git")
                }
                let prepared = try await prepareRepositoryView(repo, viewState: session.repositories[repo.url.path] ?? session.repositories[url.path] ?? defaultViewState(),
                    loadsWorkspaceComparison: !followsCurrentBranch, includesTree: showsWorkspaceTree)
                defer { prepared.closeTransientSession() }
                guard !Task.isCancelled, openingVersion == version else { return }
                repository = repo; repositoryURL = repo.url
                restoreHistorySnapshot(prepared.currentHistorySnapshot())
                needsWorkspaceComparison = followsCurrentBranch && mode == "workspace" && selectedFile != nil
                loadingDiff = needsWorkspaceComparison
                automaticallySelectedPath = prepared.automaticallySelectedPath
                initialWorkspaceSelectionReady = prepared.initialWorkspaceSelectionReady
            }
            guard !Task.isCancelled, openingVersion == version else { return }
            accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = accessed ? selectedURL : nil
            completed = true; openingFallback = nil
            recentCommitMessages = commitHistory.messages(for: repo.url)
            registerRepositoryPaths([repo.url.path])
            if persistsSession, let data = try? selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(data, forKey: "bookmark:" + repo.url.path) }
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            openingRepositoryPath = nil; pendingRepositoryPath = nil; isBusy = false; isRestoringViewState = false
            cacheCurrentHistory(for: repo.url.path)
            observeRepository(repo.url)
            refreshRecentRepositoryStates()
            Self.stores.allObjects.first(where: { $0.persistsSession })?.refreshRecentRepositoryStates()
            if persistsSession { prepareRecentProjects() }
            if needsWorkspaceComparison {
                await loadDiff()
                guard !Task.isCancelled, openingVersion == version else { return }
                cacheCurrentHistory(for: repo.url.path)
            }
            if let worktrees = try? await repo.worktrees() {
                guard !Task.isCancelled, openingVersion == version else { return }
                var linkedPaths: [String] = []
                for worktree in worktrees where !worktree.isBare && !worktree.isPrunable {
                    guard let linked = try? await GitRepository.open(URL(fileURLWithPath: worktree.path)) else { continue }
                    guard !Task.isCancelled, openingVersion == version else { return }
                    linkedPaths.append(linked.url.path)
                }
                registerRepositoryPaths(linkedPaths)
            }
        } catch {
            if openingVersion == version, !Task.isCancelled, !(error is CancellationError) {
                report(error)
                if registered, promptsIfUnavailable {
                    let missing = await Task.detached(priority: .userInitiated) { Self.repositoryRootIsMissing(selectedURL) }.value
                    if missing, openingVersion == version, !Task.isCancelled { unavailableRepository = UnavailableRepository(path: url.path) }
                }
            }
        }
    }
    private func loadSavedPresentation(_ url: URL) async -> HistoryMemorySnapshot? {
        guard followsCurrentBranch, let presentationCache, let saved = await presentationCache.load(repository: url) else { return nil }
        var viewState = session.repositories[url.path] ?? defaultViewState()
        let request = WorkspaceFilePreparation(repository: url.path, files: saved.files, ignoredPaths: [], filter: viewState.fileFilter,
            filterCase: UserDefaults.standard.string(forKey: "preferences.filterCase") ?? "insensitive", category: .all,
            showHidden: UserDefaults.standard.object(forKey: "workspace.showHiddenFiles") as? Bool ?? true,
            showIgnored: false, sort: [.init(column: .path, ascending: true)])
        let prepared: WorkspaceFilePreparation.Result?
        if showsWorkspaceTree, saved.tree != nil, request.showHidden, request.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An unfiltered tree already has its rows; the files pane prepares counts and table rows independently.
            prepared = WorkspaceFilePreparationCache.shared.cached(request)
        } else {
            prepared = try? await Task.detached(priority: .userInitiated) { try WorkspaceFilePreparationCache.shared.prepare(request) }.value
        }
        if session.repositories[url.path] == nil {
            viewState.selectedCommit = saved.commits.first?.hash
            if let file = prepared?.rows.first?.file ?? saved.files.first(where: { $0.path == saved.diffFilename }) {
                viewState.selectedPaths = [file.path]
                viewState.stagedDiff = file.isStaged && !file.isUnstaged
            }
        }
        if let tree = saved.tree { WorkspaceTreeCache.shared.store(tree, for: url.path) }
        return HistoryMemorySnapshot(files: saved.files, filesGeneration: UUID(), branches: saved.branches, branch: saved.branch,
            stashes: saved.stashes, observedState: saved.observedState, historyState: saved.historyState, mainHistoryHead: saved.mainHistoryHead,
            historyScope: saved.historyScope, commits: saved.commits, loadedCount: saved.loadedCount, hasMore: saved.hasMore,
            localUnpushedCommitHashes: saved.localUnpushedCommitHashes, viewState: viewState, commitFiles: saved.commitFiles,
            diffText: saved.diffText, staticPreview: nil, conflictPreview: nil,
            diffIdentity: saved.diffText.isEmpty ? nil : saved.diffIdentity, diffFilename: saved.diffFilename, diffLeft: saved.diffLeft,
            diffRight: saved.diffRight, diffTitle: saved.diffTitle, diffArguments: saved.diffArguments, retainedBytes: saved.diffText.utf8.count,
            workspaceStatusFailure: saved.workspaceStatusFailure)
    }
    private func prepareRepositoryView(_ repo: GitRepository, viewState: RepositoryViewState, loadsWorkspaceComparison: Bool, includesTree: Bool) async throws -> RepositoryStore {
        let prepared = RepositoryStore(persistsSession: false, followsCurrentBranch: followsCurrentBranch, usesCheckedHistoryScope: usesCheckedHistoryScope)
        var completed = false
        defer { if !completed { prepared.closeTransientSession() } }
        prepared.repository = repo; prepared.repositoryURL = repo.url
        prepared.isRestoringViewState = true; prepared.isBusy = true
        prepared.showMergedCommits = showMergedCommits
        prepared.applyViewState(viewState)
        prepared.selectFirstHistoryCommit = followsCurrentBranch
        await prepared.refresh(opening: true, loadsWorkspaceComparison: loadsWorkspaceComparison)
        if !followsCurrentBranch, let hash = prepared.selectedCommit,
           (try? await repo.workflowRevision(hash)) != nil {
            let path = prepared.selectedCommitPath
            await prepared.loadCommitFiles()
            if let path, prepared.commitFiles.contains(where: { $0.path == path }) {
                prepared.selectedCommitPath = path; await prepared.loadDiff()
            }
        }
        try Task.checkCancellation()
        guard prepared.repository != nil else { throw GitError(prepared.errorMessage ?? "Could not open repository") }
        let request = WorkspaceFilePreparation(repository: repo.url.path, files: prepared.files, ignoredPaths: [], filter: prepared.fileFilter,
            filterCase: UserDefaults.standard.string(forKey: "preferences.filterCase") ?? "insensitive", category: .all,
            showHidden: UserDefaults.standard.object(forKey: "workspace.showHiddenFiles") as? Bool ?? true,
            showIgnored: false, sort: [.init(column: .path, ascending: true)])
        let rows = Task.detached(priority: .userInitiated) { try WorkspaceFilePreparationCache.shared.prepare(request) }
        _ = await withTaskCancellationHandler { try? await rows.value } onCancel: { rows.cancel() }
        try Task.checkCancellation()
        if includesTree, prepared.workspaceStatusFailure == nil {
            let nodes = try await repo.workspaceTree()
            try Task.checkCancellation()
            WorkspaceTreeCache.shared.store(nodes, for: repo.url.path)
        }
        completed = true
        return prepared
    }
    private var projectPreparationTask: Task<Void, Never>?
    @discardableResult
    func prepareRecentProjects() -> Task<Void, Never>? {
        guard followsCurrentBranch, applicationActive else { return nil }
        if let task = projectPreparationTask { return task }
        var seen = Set<String>()
        let paths = (Array(openRepositories.reversed()) + recentPaths).filter { seen.insert($0).inserted }
        projectPreparationTask = Task(priority: .utility) {
            defer { projectPreparationTask = nil }
            // Load every saved presentation before a slow Git read or comparison can delay another project.
            for path in paths where path != repositoryURL?.path && historyMemoryCache[path] == nil {
                guard !Task.isCancelled else { return }
                if let saved = await loadSavedPresentation(URL(fileURLWithPath: path)),
                   path != repositoryURL?.path, recentPaths.contains(path) || openRepositories.contains(path) {
                    storeHistorySnapshot(saved, for: path, persist: false)
                }
            }
            for path in paths {
                guard !Task.isCancelled else { return }
                if path == repositoryURL?.path || historyMemoryCache[path] != nil { continue }
                let url = URL(fileURLWithPath: path)
                let missing = await Task.detached(priority: .utility) { Self.repositoryRootIsMissing(url) }.value
                guard !missing else { continue }
                do {
                    try await GitCommandLog.$suppressRoutineReads.withValue(true) {
                        let repo = try await GitRepository.open(url)
                        guard Self.sameRepositoryLocation(repo.url, url) else { return }
                        let prepared = try await prepareRepositoryView(repo, viewState: session.repositories[path] ?? defaultViewState(), loadsWorkspaceComparison: false, includesTree: false)
                        defer { prepared.closeTransientSession() }
                        guard !Task.isCancelled, path != repositoryURL?.path, historyMemoryCache[path] == nil,
                              recentPaths.contains(path) || openRepositories.contains(path) else { return }
                        storeHistorySnapshot(prepared.currentHistorySnapshot(), for: path)
                    }
                } catch { /* Inactive project reads never interrupt the current project. */ }
                await Task.yield()
            }
            // Fill optional previews only after all primary lists can already switch.
            for path in paths {
                guard !Task.isCancelled else { return }
                guard path != repositoryURL?.path, let snapshot = historyMemoryCache[path],
                      snapshot.workspaceStatusFailure == nil else { continue }
                do {
                    try await GitCommandLog.$suppressRoutineReads.withValue(true) {
                        let repo = GitRepository(url: URL(fileURLWithPath: path))
                        let prepared = RepositoryStore(persistsSession: false, followsCurrentBranch: followsCurrentBranch, usesCheckedHistoryScope: usesCheckedHistoryScope)
                        defer { prepared.closeTransientSession() }
                        prepared.repository = repo; prepared.repositoryURL = repo.url
                        prepared.restoreHistorySnapshot(snapshot)
                        if snapshot.diffIdentity == nil { await prepared.loadDiff() }
                        if WorkspaceTreeCache.shared.nodes(for: path) == nil {
                            let nodes = try await repo.workspaceTree()
                            WorkspaceTreeCache.shared.store(nodes, for: path)
                        }
                        guard !Task.isCancelled, path != repositoryURL?.path,
                              recentPaths.contains(path) || openRepositories.contains(path) else { return }
                        storeHistorySnapshot(prepared.currentHistorySnapshot(), for: path)
                    }
                } catch { /* Optional previews do not prevent list presentation. */ }
            }
        }
        return projectPreparationTask
    }
    private func restoreInterruptedOpening() {
        guard let fallback = openingFallback else { return }
        repository = fallback.repository; repositoryURL = fallback.url
        restoreHistorySnapshot(fallback.snapshot)
        if let root = fallback.url { observeRepository(root) }
        openingFallback = nil; openingRepositoryPath = nil; isBusy = false; isRestoringViewState = false
    }
    private func observeRepository(_ root: URL) {
        let version = repoVersion
        Task { [self] in
            let repo = GitRepository(url: root)
            async let gitDirectory = repo.workflowRead(["rev-parse", "--absolute-git-dir"])
            async let commonPath = repo.workflowRead(["rev-parse", "--git-common-dir"])
            guard let paths = try? await (gitDirectory, commonPath), version == repoVersion, repositoryURL == root else { return }
            let gitPath = paths.0.trimmingCharacters(in: .newlines), common = paths.1.trimmingCharacters(in: .newlines)
            let commonURL = common.hasPrefix("/") ? URL(fileURLWithPath: common) : root.appendingPathComponent(common).standardizedFileURL
            fileObserver = RepositoryFileObserver(paths: Array(Set([root.path, gitPath, commonURL.path]))) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleFilesystemRefresh(root: root) }
            }
        }
    }
    private func refreshOpeningRepository(_ repository: GitRepository, version: UUID) async -> Bool {
        do {
            let freshFiles = try await repository.status()
            guard !Task.isCancelled, openingVersion == version else { return false }
            let state = try await repository.changeState(files: freshFiles)
            guard !Task.isCancelled, openingVersion == version else { return false }
            let needsComparison = followsCurrentBranch && mode == "workspace" &&
                (state != lastObservedState || displayedDiffIdentity != requestedDiffIdentity)
            if state.history == lastHistoryState { historyRestoreDepth = nil }
            await refresh(knownFiles: freshFiles, knownState: state, opening: true,
                          reuseMetadata: state.history == lastObservedState?.history, loadsWorkspaceComparison: !followsCurrentBranch)
            return needsComparison
        } catch {
            if openingVersion == version, !Task.isCancelled, !(error is CancellationError) {
                if !(await retainRepositoryWithUnreadableIndex(error, repository: repository)) { self.repository = nil; report(error) }
            }
            return false
        }
    }
    private func scheduleFilesystemRefresh(root: URL) {
        guard AuvGitPreferences.backgroundRefresh, applicationActive, repositoryURL == root else { return }
        if filesystemRefreshing { filesystemPending = true; return }
        guard filesystemRefresh == nil else { return }
        filesystemRefresh = Task {
            let delay = max(0, 0.3 - Date().timeIntervalSince(lastAutomaticRefresh))
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard AuvGitPreferences.backgroundRefresh, applicationActive, !Task.isCancelled, repositoryURL == root else {
                filesystemRefresh = nil; return
            }
            filesystemRefresh = nil
            if isBusy { return } // The active write ends with its own refresh.
            lastAutomaticRefresh = Date()
            filesystemRefreshing = true
            await refreshIfChanged()
            filesystemRefreshing = false
            if filesystemPending { filesystemPending = false; scheduleFilesystemRefresh(root: root) }
        }
    }
    static func setApplicationActiveForAllStores(_ active: Bool) {
        stores.allObjects.forEach { $0.setApplicationActive(active) }
    }
    static func checkRemoteUpdatesForActivePanel() {
        for store in stores.allObjects where store.persistsSession { store.refreshRecentRepositoryStates() }
    }
    static func pollAllRepositories() async {
        await withTaskGroup(of: Void.self) { group in
            for store in stores.allObjects {
                group.addTask { guard !Task.isCancelled else { return }; await store.pollForChanges() }
            }
        }
    }
    func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        let version = UUID(); activationVersion = version
        activationTask?.cancel(); activationTask = nil
        if !active {
            cancelAutomaticRefresh()
            recentSyncTask?.cancel(); projectPreparationTask?.cancel()
            filesystemRefresh?.cancel(); filesystemRefresh = nil; filesystemPending = false
            return
        }
        activationTask = Task {
            defer { if activationVersion == version { activationTask = nil } }
            guard !Task.isCancelled, applicationActive, AuvGitPreferences.backgroundRefresh else { return }
            lastPoll = Date(); lastAutomaticRefresh = Date()
            recentSyncDate = .distantPast
            await refreshIfChanged()
            guard !Task.isCancelled, applicationActive else { return }
            refreshRecentRepositoryStates()
            if persistsSession { prepareRecentProjects() }
        }
    }
    private var lastPoll = Date.distantPast
    func pollForChanges() async {
        guard applicationActive else { return }
        if persistsSession { refreshRecentRepositoryStates() }
        else { Self.checkRemoteUpdatesForActivePanel() }
        guard AuvGitPreferences.backgroundRefresh, Date().timeIntervalSince(lastPoll) >= max(30, AuvGitPreferences.pollInterval) else { return }
        lastPoll = Date(); await refreshIfChanged()
    }
    private var lastObservedState: RepositoryChangeState?
    private var lastHistoryState: String?
    private func cancelAutomaticRefresh() {
        guard let task = automaticRefreshTask else { return }
        automaticRefreshVersion = UUID()
        automaticRefreshTask = nil
        task.cancel()
        refreshReadVersion = UUID(); refreshingRepository = nil
    }
    func refreshIfChanged() async {
        guard applicationActive, !isBusy, !Task.isCancelled else { return }
        if let task = automaticRefreshTask { await task.value; return }
        guard let repository, refreshingRepository != repository.url else { return }
        let generation = UUID(); automaticRefreshVersion = generation
        // Keep the read cancellable after its filesystem debounce task has finished.
        let task = Task {
            defer { if automaticRefreshVersion == generation { automaticRefreshTask = nil } }
            await performAutomaticRefresh()
        }
        automaticRefreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performAutomaticRefresh() async {
        guard applicationActive, let repository, !isBusy, !Task.isCancelled, refreshingRepository != repository.url else { return }
        let version = repoVersion, readVersion = refreshReadVersion
        do {
            let (newFiles, state) = try await GitCommandLog.$suppressRoutineReads.withValue(true) {
                let newFiles = try await repository.status()
                guard applicationActive, !Task.isCancelled, version == repoVersion, readVersion == refreshReadVersion, !isBusy else { throw CancellationError() }
                applyFileStatus(newFiles)
                return try await (newFiles, repository.changeState(files: newFiles))
            }
            guard applicationActive, !Task.isCancelled, version == repoVersion, readVersion == refreshReadVersion, !isBusy, repositoryURL == repository.url, state != lastObservedState else { return }
            await refresh(knownFiles: newFiles, knownState: state)
        } catch { /* A canceled background read never becomes an operation error. */ }
    }
    func refresh(knownFiles: [GitFile]? = nil, knownState: RepositoryChangeState? = nil, opening: Bool = false, reuseMetadata: Bool = false, loadsWorkspaceComparison: Bool = true) async {
        guard let repository, (!isBusy || opening), refreshingRepository != repository.url else { return }
        refreshingRepository = repository.url; let version = repoVersion
        let refreshVersion = UUID(); refreshReadVersion = refreshVersion
        defer { if refreshReadVersion == refreshVersion { refreshingRepository = nil } }
        do {
            async let newFiles: [GitFile] = { if let knownFiles { return knownFiles }; return try await repository.status() }()
            let cachedBranches = branches, cachedBranch = branch
            async let newBranches = reuseMetadata ? cachedBranches : try await repository.branches()
            async let newBranch = reuseMetadata ? cachedBranch : try await repository.currentBranch()
            async let newStashes = repository.stashes()
            async let syncRead = GitCommandLog.$suppressRoutineReads.withValue(true) {
                try? await repository.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            }
            let fileStatus = try await newFiles
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            applyFileStatus(fileStatus)
            async let stateRead: RepositoryChangeState = { if let knownState { return knownState }; return try await repository.changeState(files: fileStatus) }()
            let cachedDiffIsCurrent = opening && knownState == lastObservedState && displayedDiffIdentity == requestedDiffIdentity
            let shouldLoadWorkspaceDiff = loadsWorkspaceComparison && mode == "workspace" && !cachedDiffIsCurrent
            async let workspaceDiff: Void = shouldLoadWorkspaceDiff ? loadDiff() : ()
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            publishRepositoryChangeCount(fileStatus.count, path: repository.url.path)
            let result = try await (fileStatus, newBranches, newBranch, newStashes)
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            if branches != result.1 { branches = result.1 }
            if branch != result.2 { branch = result.2 }
            if stashes != result.3 {
                lastHistoryState = nil
                if followsCurrentBranch { resetMainHistorySelection() }
                else if let selectedCommit, stashes.contains(where: { $0.hash == selectedCommit }), !result.3.contains(where: { $0.hash == selectedCommit }) {
                    self.selectedCommit = nil; selectedCommitPath = nil; commitFiles = []
                    historyStashHash = nil; historyStashRef = nil; selectFirstHistoryCommit = true
                }
                stashes = result.3; checkedHistoryRefs = nil
            }
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            let observedState = try await stateRead
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            repositoryOperation = observedState.operation
            recreatableConflicts = observedState.recreatableConflicts ?? []
            if followsCurrentBranch, !reuseMetadata {
                let head = result.2 + "|" + ((try? await repository.workflowRevision("HEAD")) ?? "")
                guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
                if lastMainHistoryHead != head {
                    lastMainHistoryHead = head; resetMainHistorySelection()
                }
            }
            if usesCheckedHistoryScope { configureCheckedHistoryRefs() }
            if lastHistoryState != observedState.history {
                await loadHistory(reset: true)
                if version == repoVersion, refreshReadVersion == refreshVersion { lastHistoryState = observedState.history }
            }
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            if opening, reuseMetadata, followsCurrentBranch, lastHistoryState == observedState.history { await loadCommitFiles() }
            if mode != "workspace", opening || observedState != lastObservedState { await loadDiff() }
            if version == repoVersion, refreshReadVersion == refreshVersion { lastObservedState = observedState }
            let syncText = await syncRead
            let syncCounts = syncText?.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) } ?? []
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            let syncState = RepositorySyncState(ahead: syncCounts.count == 2 ? syncCounts[0] : nil, behind: syncCounts.count == 2 ? syncCounts[1] : nil, conflicts: result.0.filter(\.isConflict).count)
            publishRepositorySyncState(syncState, path: repository.url.path)
            await workspaceDiff
            workspaceStatusFailure = nil
        } catch {
            if !Task.isCancelled, !(error is CancellationError), version == repoVersion, refreshReadVersion == refreshVersion {
                if !(await retainRepositoryWithUnreadableIndex(error, repository: repository)) { if opening { self.repository = nil }; report(error) }
            }
        }
    }
    private func retainRepositoryWithUnreadableIndex(_ error: Error, repository: GitRepository) async -> Bool {
        guard GitFailureSummary.key(for: error.localizedDescription) == "Git index is corrupt; workspace changes are unavailable." else { return false }
        let version = repoVersion
        async let refs = repository.branches()
        async let head = repository.currentBranch()
        async let stashList = repository.stashes()
        guard let metadata = try? await (refs, head, stashList), !Task.isCancelled, version == repoVersion,
              self.repository?.url == repository.url else { return false }
        branches = metadata.0; branch = metadata.1; stashes = metadata.2
        applyFileStatus([]); selectedPaths = []; clearDiff()
        workspaceStatusFailure = error.localizedDescription
        await loadHistory(reset: true)
        guard !Task.isCancelled, version == repoVersion, self.repository?.url == repository.url else { return false }
        report(error)
        return true
    }
    nonisolated static func sameRepositoryLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
    nonisolated static func repositoryRootIsMissing(_ url: URL) -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType != .typeDirectory && attributes[.type] as? FileAttributeType != .typeSymbolicLink { return true }
            _ = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(".git").path)
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
                || error.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(error.code)
        }
    }
    func removeRecentRepository(_ path: String) {
        guard !isBusy, workspaceProjects?.isBusy(path: path) != true else { return }
        let stores = workspaceProjects?.sessions ?? [self]
        // Every session participates in persistence; stale tabs must not resurrect a removed project.
        for store in stores {
            store.recentPaths.removeAll { $0 == path }
            store.openRepositories.removeAll { $0 == path }
            if store.unavailableRepository?.path == path { store.unavailableRepository = nil }
        }
        if persistsSession { UserDefaults.standard.set(recentPaths, forKey: "recentRepositories") }
        workspaceProjects?.synchronizeProjectList(from: self)
        unavailableRepository = nil
        for store in stores { store.closeRepositoryTab(path) }
        flushSession()
        if let presentationCache { Task { try? await presentationCache.remove(repository: URL(fileURLWithPath: path)) } }
    }
    private func applyFileStatus(_ newFiles: [GitFile]) {
        if files != newFiles { files = newFiles; filesGeneration = UUID() }
        let surviving = selectedPaths.intersection(Set(newFiles.map(\.path)))
        if surviving != selectedPaths { selectedPaths = surviving }
        if isRestoringViewState, selectedPaths.isEmpty {
            let showHidden = UserDefaults.standard.object(forKey: "workspace.showHiddenFiles") as? Bool ?? true
            if let first = filteredFiles.filter({ showHidden || !WorkspaceStatusFilter.isHiddenPath($0.path) })
                .min(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                selectedPaths = [first.path]
                automaticallySelectedPath = first.path
                stagedDiff = first.isStaged && !first.isUnstaged
            }
        }
        if isRestoringViewState { initialWorkspaceSelectionReady = true }
    }
    /// Re-selecting the current repository updates its files without reopening its history.
    func refreshFileStatus() async {
        guard let repository, !isBusy, refreshingRepository != repository.url else { return }
        let version = repoVersion
        let refreshVersion = UUID(); refreshReadVersion = refreshVersion
        refreshingRepository = repository.url
        defer { if refreshReadVersion == refreshVersion { refreshingRepository = nil } }
        do {
            let newFiles = try await repository.status()
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            applyFileStatus(newFiles)
            let state = try await repository.changeState(files: newFiles)
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            repositoryOperation = state.operation
            recreatableConflicts = state.recreatableConflicts ?? []
            if workspaceStatusFailure != nil { workspaceStatusFailure = nil; errorMessage = nil }
            publishRepositoryChangeCount(newFiles.count, path: repository.url.path)
            let previous = repositorySyncStates[repository.url.path]
            let sync = RepositorySyncState(ahead: previous?.ahead, behind: previous?.behind, conflicts: newFiles.filter(\.isConflict).count)
            publishRepositorySyncState(sync, path: repository.url.path)
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            if state != lastObservedState { await loadDiff() }
            if version == repoVersion, refreshReadVersion == refreshVersion, state.history == lastHistoryState { lastObservedState = state }
        } catch {
            if !Task.isCancelled, !(error is CancellationError), version == repoVersion, refreshReadVersion == refreshVersion {
                if !(await retainRepositoryWithUnreadableIndex(error, repository: repository)) { report(error) }
            }
        }
    }
    func stopBackgroundRepositorySync() {
        Self.stores.allObjects.forEach { $0.recentSyncTask?.cancel(); $0.projectPreparationTask?.cancel() }
    }
    func cancelBackgroundRepositorySync() async {
        let tasks = Self.stores.allObjects.flatMap { [$0.recentSyncTask, $0.projectPreparationTask].compactMap { $0 } }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
    func refreshRecentRepositoryStates(now: Date = Date(), addedPaths: [String] = []) {
        for path in addedPaths where !immediateRemoteSyncPaths.contains(path) { immediateRemoteSyncPaths.append(path) }
        let immediate = !immediateRemoteSyncPaths.isEmpty
        guard applicationActive, immediate || (persistsSession && AuvGitPreferences.backgroundRefresh), recentSyncTask == nil,
              !Self.stores.allObjects.contains(where: { $0.isBusy && $0.repositoryURL == nil }),
              immediate || now.timeIntervalSince(recentSyncDate) >= 30 else { return }
        recentSyncDate = now
        var seen = Set<String>()
        let paths = ([workspaceProjects?.active.repositoryURL?.path, repositoryURL?.path].compactMap { $0 } + openRepositories + recentPaths).filter { seen.insert($0).inserted }
        nextRemoteSync = nextRemoteSync.filter { paths.contains($0.key) }
        recentSyncTask = Task {
            // Populate every sidebar row from known refs before waiting on any
            // network request. A slow remote must not hide another project's updates.
            await withTaskGroup(of: Void.self) { group in
                var pending = paths.makeIterator()
                for _ in 0..<3 {
                    if let path = pending.next() {
                        group.addTask { await self.refreshRecentRepositoryLocalState(path: path) }
                    }
                }
                while await group.next() != nil {
                    if !Task.isCancelled, let path = pending.next() {
                        group.addTask { await self.refreshRecentRepositoryLocalState(path: path) }
                    }
                }
            }
            var remaining = immediate ? [] : paths
            while !immediateRemoteSyncPaths.isEmpty || !remaining.isEmpty {
                let isImmediate = !immediateRemoteSyncPaths.isEmpty
                let path = isImmediate ? immediateRemoteSyncPaths.removeFirst() : remaining.removeFirst()
                remaining.removeAll { $0 == path }
                guard applicationActive, !Task.isCancelled, isImmediate || AuvGitPreferences.backgroundRefresh else { break }
                // A write blocks its repository, not unrelated projects in the sidebar.
                guard !Self.stores.allObjects.contains(where: { $0.isBusy && ($0.repositoryURL == nil || $0.repositoryURL?.path == path) }) else { continue }
                guard (recentPaths + openRepositories + [repositoryURL?.path].compactMap { $0 }).contains(path) else { continue }
                let repo = GitRepository(url: URL(fileURLWithPath: path))
                if isImmediate || now >= (nextRemoteSync[path] ?? .distantPast) {
                    do {
                        let authentication = RemoteAuthenticationCoordinator()
                        let remotes = (try await repo.workflowRead(["remote"])).split(separator: "\n").map(String.init)
                        var credentials: [String: NetworkCredential] = [:]
                        for remote in remotes {
                            credentials[remote] = await authentication.savedCredential(for: repo, operation: .fetch, remoteName: remote)
                        }
                        try await repo.backgroundFetch(credentialsByRemote: credentials)
                        nextRemoteSync[path] = Date().addingTimeInterval(Double.random(in: 90...150))
                        for store in Self.stores.allObjects where store.repositoryURL == repo.url {
                            await store.refreshIfChanged()
                        }
                    } catch {
                        if Task.isCancelled { break }
                        nextRemoteSync[path] = Date().addingTimeInterval(300)
                    }
                }
                await refreshRecentRepositoryLocalState(path: path)
            }
            recentSyncTask = nil
        }
    }
    private func refreshRecentRepositoryLocalState(path: String) async {
        func mayPublish() -> Bool {
            applicationActive && !Task.isCancelled &&
            (recentPaths + openRepositories + [repositoryURL?.path].compactMap { $0 }).contains(path) &&
            !Self.stores.allObjects.contains(where: { $0.isBusy && ($0.repositoryURL == nil || $0.repositoryURL?.path == path) })
        }
        guard mayPublish() else { return }
        let repo = GitRepository(url: URL(fileURLWithPath: path))
        guard let files = try? await GitCommandLog.$suppressRoutineReads.withValue(true, operation: { try await repo.status() }) else { return }
        let text = try? await GitCommandLog.$suppressRoutineReads.withValue(true) {
            try await repo.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        }
        guard mayPublish() else { return }
        let counts = text?.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) } ?? []
        publishRepositoryChangeCount(files.count, path: path)
        publishRepositorySyncState(RepositorySyncState(ahead: counts.count == 2 ? counts[0] : nil,
            behind: counts.count == 2 ? counts[1] : nil, conflicts: files.filter(\.isConflict).count), path: path)
    }
    private func resetMainHistorySelection() {
        historyRef = nil; historyPath = nil; selectedCommit = nil; selectedCommitPath = nil; commitFiles = []
        selectFirstHistoryCommit = true; historyNavigationGeneration = UUID()
    }
    private func cacheCurrentHistory(for path: String) {
        guard lastObservedState != nil || workspaceStatusFailure != nil, !isBusy else { return }
        storeHistorySnapshot(currentHistorySnapshot(), for: path)
    }
    private func storeHistorySnapshot(_ snapshot: HistoryMemorySnapshot, for path: String, persist: Bool = true) {
        if historyMemoryCache[path] == nil, historyMemoryCache.count >= 32,
           let oldest = openRepositories.first(where: { $0 != path && historyMemoryCache[$0] != nil }) ?? historyMemoryCache.keys.first {
            historyMemoryCache.removeValue(forKey: oldest)
        }
        historyMemoryCache[path] = snapshot
        if persist, followsCurrentBranch, let presentationCache {
            let saved = RepositoryPresentationSnapshot(files: snapshot.files, branches: snapshot.branches, branch: snapshot.branch,
                stashes: snapshot.stashes, commits: snapshot.commits, commitFiles: snapshot.commitFiles,
                tree: WorkspaceTreeCache.shared.nodes(for: path), loadedCount: snapshot.loadedCount, hasMore: snapshot.hasMore,
                // Disk snapshots only present content; fresh validation supplies filesystem state.
                observedState: nil, historyState: snapshot.historyState, mainHistoryHead: snapshot.mainHistoryHead,
                historyScope: snapshot.historyScope, localUnpushedCommitHashes: snapshot.localUnpushedCommitHashes,
                diffText: snapshot.diffText, diffIdentity: snapshot.diffIdentity, diffFilename: snapshot.diffFilename,
                diffLeft: snapshot.diffLeft, diffRight: snapshot.diffRight, diffTitle: snapshot.diffTitle, diffArguments: snapshot.diffArguments,
                workspaceStatusFailure: snapshot.workspaceStatusFailure)
            Task { try? await presentationCache.save(saved, for: URL(fileURLWithPath: path)) }
        }
        while historyMemoryCache.count > 1 && (historyMemoryCache.values.reduce(0, { $0 + $1.files.count + $1.commits.count }) > 100_000
            || historyMemoryCache.values.reduce(0, { $0 + $1.retainedBytes }) > 128 * 1024 * 1024) {
            guard let oldest = historyMemoryCache.keys.first(where: { $0 != path && $0 != repositoryURL?.path }) else { break }
            historyMemoryCache.removeValue(forKey: oldest)
        }
    }
    private func currentHistorySnapshot() -> HistoryMemorySnapshot {
        let revisions = [staticPreview, conflictPreview].compactMap { $0 }.flatMap { [$0.head, $0.index, $0.worktree, $0.base, $0.ours, $0.theirs].compactMap { $0 } }
        return HistoryMemorySnapshot(
            files: files, filesGeneration: filesGeneration, branches: branches, branch: branch, stashes: stashes,
            observedState: lastObservedState, historyState: lastHistoryState, mainHistoryHead: lastMainHistoryHead,
            historyScope: loadedHistoryScope, commits: commits,
            loadedCount: historyLoadedCount,
            hasMore: hasMore,
            localUnpushedCommitHashes: localUnpushedCommitHashes,
            viewState: captureViewState(), commitFiles: commitFiles,
            diffText: diffText, staticPreview: staticPreview, conflictPreview: conflictPreview,
            diffIdentity: displayedDiffIdentity, diffFilename: diffRevisionFilename,
            diffLeft: diffLeftRevision, diffRight: diffRightRevision,
            diffTitle: diffTitleKey, diffArguments: diffTitleArguments,
            retainedBytes: diffText.utf8.count + revisions.reduce(0, { $0 + ($1.data?.count ?? 0) + ($1.text?.utf8.count ?? 0) }), workspaceStatusFailure: workspaceStatusFailure
        )
    }
    private func restoreHistorySnapshot(_ snapshot: HistoryMemorySnapshot) {
        workspaceStatusFailure = snapshot.workspaceStatusFailure
        if let failure = workspaceStatusFailure { report(GitError(failure)) }
        applyViewState(snapshot.viewState)
        automaticallySelectedPath = nil; initialWorkspaceSelectionReady = true
        checkedHistoryRefs = nil; historyPinnedCommit = nil; historyStashHash = nil; historyStashRef = nil
        commitFiles = snapshot.commitFiles
        diffText = snapshot.diffText; staticPreview = snapshot.staticPreview; conflictPreview = snapshot.conflictPreview
        displayedDiffIdentity = snapshot.diffIdentity; diffRevisionFilename = snapshot.diffFilename
        diffLeftRevision = snapshot.diffLeft; diffRightRevision = snapshot.diffRight
        setDiffTitle(snapshot.diffTitle, arguments: snapshot.diffArguments)
        loadingDiff = false; loadingHistory = false; selectFirstHistoryCommit = false
        files = snapshot.files; filesGeneration = snapshot.filesGeneration
        branches = snapshot.branches; branch = snapshot.branch; stashes = snapshot.stashes
        repositoryOperation = snapshot.observedState?.operation
        recreatableConflicts = snapshot.observedState?.recreatableConflicts ?? []
        lastObservedState = snapshot.observedState; lastHistoryState = snapshot.historyState; lastMainHistoryHead = snapshot.mainHistoryHead
        if usesCheckedHistoryScope { configureCheckedHistoryRefs() }
        commits = snapshot.commits
        historyLoadedCount = snapshot.loadedCount; hasMore = snapshot.hasMore
        localUnpushedCommitHashes = snapshot.localUnpushedCommitHashes
        if snapshot.historyScope == currentHistoryScope {
            loadedHistoryScope = snapshot.historyScope
        } else { lastHistoryState = nil; loadedHistoryScope = nil }
        historyRestoreDepth = snapshot.loadedCount
    }
    func setShowMergedCommits(_ value: Bool) {
        guard showMergedCommits != value else { return }
        showMergedCommits = value
        if persistsSession { UserDefaults.standard.set(value, forKey: "history.workspaceShowMergedCommits") }
        resetMainHistorySelection()
        Task { await loadHistory(reset: true) }
    }
    func configureCheckedHistoryRefs() {
        guard !followsCurrentBranch, let repositoryURL, checkedHistoryRefs == nil else { return }
        let available = Set(branches.map(HistoryBranchScope.branchRef)).union(stashes.map(HistoryBranchScope.stashRef)).union(["HEAD", HistoryBranchScope.recyclable, HistoryBranchScope.allStashes])
        checkedHistoryRefs = HistoryBranchScope.load(repository: repositoryURL).map { HistoryBranchScope.migrate($0, stashes: stashes).intersection(available) }
            ?? HistoryBranchScope.defaultRefs(branches: branches, branch: branch)
        if let checkedHistoryRefs { HistoryBranchScope.save(checkedHistoryRefs, repository: repositoryURL) }
    }
    func setHistoryBranchChecked(_ ref: String, checked: Bool) {
        configureCheckedHistoryRefs()
        let refs = HistoryBranchScope.setting(ref, checked: checked, in: checkedHistoryRefs ?? [], stashes: stashes)
        checkedHistoryRefs = refs
        if let repositoryURL { HistoryBranchScope.save(refs, repository: repositoryURL) }
        historyStashHash = nil; historyStashRef = nil; historyPath = nil; historyPinnedCommit = nil
        if historyRef?.hasPrefix("refs/tags/") == true { historyRef = ref }
        selectedCommit = nil; selectedCommitPath = nil; commitFiles = []
        selectFirstHistoryCommit = true; historyNavigationGeneration = UUID()
        Task { await loadHistory(reset: true) }
    }
    func loadHistory(reset: Bool) async {
        guard let repository else { return }
        if !reset, loadingHistory { return }
        let version = UUID(); historyVersion = version; loadingHistory = true
        let skip = reset ? 0 : historyLoadedCount
        let requestedCount = reset ? max(AuvGitPreferences.historyPageSize, historyRestoreDepth ?? 0) : AuvGitPreferences.historyPageSize
        do {
            let stashHashes: [String]
            if followsCurrentBranch { stashHashes = stashes.map(\.hash) }
            else if historyPinnedCommit == nil, historyStashHash == nil, historyRef?.hasPrefix("refs/tags/") != true {
                stashHashes = HistoryBranchScope.selectedStashHashes(checkedHistoryRefs ?? [HistoryBranchScope.allStashes], stashes: stashes)
            } else { stashHashes = [] }
            let rows = try await repository.log(limit: requestedCount + 1, skip: skip, search: historySearch, path: followsCurrentBranch ? nil : historyPath, ref: followsCurrentBranch ? "HEAD" : (historyPinnedCommit ?? historyRef), author: historyAuthor, firstParent: followsCurrentBranch && !showMergedCommits, refs: followsCurrentBranch || historyPinnedCommit != nil || historyStashHash != nil || historyRef?.hasPrefix("refs/tags/") == true ? nil : checkedHistoryRefs.map { HistoryBranchScope.revisionRefs($0, branches: branches, stashes: stashes) }, stashHashes: stashHashes, includeRecyclable: !followsCurrentBranch && historyPinnedCommit == nil && historyStashHash == nil && historyRef?.hasPrefix("refs/tags/") != true && checkedHistoryRefs?.contains(HistoryBranchScope.recyclable) == true)
            guard historyVersion == version else { return }
            let page = Array(rows.prefix(requestedCount))
            let existing = reset ? page : commits + page.filter { row in !commits.contains(where: { $0.hash == row.hash }) }
            let incoming: [GitCommit]
            var hasMoreIncoming = false
            if historyPinnedCommit == nil, historyStashHash == nil, historyPath == nil, historyRef?.hasPrefix("refs/tags/") != true {
                let incomingLimit = reset ? requestedCount : commits.count + requestedCount
                let incomingRows = try await repository.log(limit: incomingLimit + 1, search: historySearch, author: historyAuthor, refs: visibleHistoryRemoteBranchNames.map { "refs/remotes/" + $0 }.sorted(), incomingOnly: true)
                incoming = Array(incomingRows.prefix(incomingLimit))
                hasMoreIncoming = incomingRows.count > incomingLimit
            } else { incoming = [] }
            guard historyVersion == version else { return }
            let incomingHashes = Set(incoming.map(\.hash))
            let updatedCommits = incoming + existing.filter { !incomingHashes.contains($0.hash) }
            let unpushed = try await repository.unpublishedCommitHashes(in: updatedCommits)
            guard historyVersion == version else { return }
            if commits != updatedCommits { commits = updatedCommits }
            historyLoadedCount = skip + page.count
            hasMore = rows.count > requestedCount || hasMoreIncoming
            if reset { historyRestoreDepth = nil }
            localUnpushedCommitHashes = unpushed
            if reset, selectFirstHistoryCommit {
                selectFirstHistoryCommit = false; selectedCommit = updatedCommits.first?.hash
                await loadCommitFiles()
                guard !Task.isCancelled, historyVersion == version else { return }
            }
            if let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit }) {
                if !followsCurrentBranch, checkedHistoryRefs == nil || historyStashHash != nil, let selected = try? await repository.log(limit: 1, ref: selectedCommit).first, historyVersion == version { commits.append(selected) }
                else if !isRestoringViewState { self.selectedCommit = nil; commitFiles = []; selectedCommitPath = nil }
            }
            loadedHistoryScope = currentHistoryScope
            cacheCurrentHistory(for: repository.url.path)
        } catch { if !Task.isCancelled, !(error is CancellationError), historyVersion == version { report(error) } }
        if historyVersion == version { loadingHistory = false }
    }
    func showStashHistory(ref: String) {
        guard let repository else { return }
        Task {
            do {
                guard try await repository.stashes().contains(where: { $0.ref == ref }) else { throw GitError("Unknown stash reference") }
                let hash = try await repository.workflowRevision(ref)
                LogPresenter.show(repository: repository, ref: hash, selectedCommit: hash, stashCommit: hash, stashRef: ref, applyFilter: true)
            } catch { report(error) }
        }
    }
    func showHistory(path: String?, ref: String?) {
        historyPinnedCommit = nil
        historyStashHash = nil; historyStashRef = nil
        stashUntrackedPaths = []
        if persistsSession {
            guard let repository else { return }
            LogPresenter.show(repository: repository, path: path, ref: ref, applyFilter: true)
            return
        }
        selectFirstHistoryCommit = true
        historyPath = path; historyRef = HistoryReference.canonical(ref, branches: branches); historySearch = ""; historyAuthor = ""; selectedCommit = nil
        historyNavigationGeneration = UUID()
        commitFiles = []; selectedCommitPath = nil; mode = "history"
        Task { await loadHistory(reset: true) }
    }
    func scheduleSearch() {
        if !isRestoringViewState { selectedCommit = nil; selectedCommitPath = nil; commitFiles = [] }
        historyVersion = UUID(); searchTask?.cancel()
        searchTask = Task { try? await Task.sleep(nanoseconds: 250_000_000); guard !Task.isCancelled else { return }; await loadHistory(reset: true) }
    }
    func loadCommitFiles() async {
        guard mode == "history" else { return }
        let version = UUID(); detailVersion = version; commitFiles = []; selectedCommitPath = nil
        guard let repository, let selectedCommit else { await loadDiff(); return }
        do {
            let result: [GitCommitFile]
            activeDetailStashHash = historyStashHash == selectedCommit ? selectedCommit : stashes.first(where: { $0.hash == selectedCommit })?.hash
            if activeDetailStashHash == selectedCommit {
                let stash = try await StashHistory.files(repository: repository, hash: selectedCommit)
                guard detailVersion == version else { return }
                stashUntrackedPaths = stash.untracked
                result = stash.files
            } else { stashUntrackedPaths = []; result = try await repository.commitFiles(hash: selectedCommit) }
            guard detailVersion == version else { return }
            commitFiles = result; selectedCommitPath = result.first?.path
            await loadDiff()
        } catch { if detailVersion == version { report(error) } }
    }
    func comparisonRevision(for path: String) -> String? {
        guard let hash = selectedCommit else { return nil }
        return hash == activeDetailStashHash && stashUntrackedPaths.contains(path) ? hash + "^3" : hash
    }
    func loadDiff() async {
        guard !Task.isCancelled else { return }
        diffTask?.cancel()
        let task = Task { await performLoadDiff() }
        diffTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private var requestedDiffIdentity: String {
        (repositoryURL?.path ?? "") + "|" + mode + "|" + (mode == "history" ? (selectedCommit ?? "") + "|" + (selectedCommitPath ?? "") : (selectedFile?.path ?? "") + "|\(effectiveStagedDiff)") + "|\(ignoreWhitespace)"
    }
    var canMutateDisplayedDiff: Bool { workspaceStatusFailure == nil && pendingRepositoryPath == nil && !loadingDiff && displayedDiffIdentity == requestedDiffIdentity }
    private func clearDiff() {
        displayedDiffIdentity = nil
        diffText = ""; conflictPreview = nil; staticPreview = nil
        diffRevisionFilename = nil; diffLeftRevision = nil; diffRightRevision = nil
        loadingDiff = false
    }
    private func performLoadDiff() async {
        guard !Task.isCancelled else { return }
        let version = UUID(); diffVersion = version
        let identity = requestedDiffIdentity, requestedIgnoreWhitespace = ignoreWhitespace
        guard let repository else { clearDiff(); return }
        let target: DiffTarget, title: String, arguments: [String]
        let stashHash = mode == "history" && selectedCommit == activeDetailStashHash ? selectedCommit : nil
        let stashPath = selectedCommitPath
        let untrackedStash = selectedCommitPath.map { stashUntrackedPaths.contains($0) } ?? false
        let conflictPath = mode == "workspace" && selectedFile?.isConflict == true ? selectedFile?.path : nil
        if mode == "history" {
            guard let hash = selectedCommit, let path = selectedCommitPath else {
                clearDiff(); setDiffTitle("Select a commit and file to view changes"); return
            }
            target = .commit(hash: stashHash == nil ? hash : comparisonRevision(for: path) ?? hash, path: path)
            title = "%@  /  %@"; arguments = [String(hash.prefix(8)), path]
        } else {
            guard let file = selectedFile else { clearDiff(); setDiffTitle("Select a file to view changes"); return }
            let staged = usesStagedDiff(for: file)
            target = staged ? .staged(path: file.path) : .worktree(path: file.path, untracked: file.isUntracked)
            title = conflictPath != nil ? "%@  ·  Conflict" : staged ? "%@  ·  HEAD → Index" : "%@  ·  Index → Working Tree"
            arguments = [file.path]
        }
        loadingDiff = true
        do {
            let revisions = try await diffRevisionTitles(target: target, repository: repository)
            let text: String, preview: FileComparisonSnapshot?, conflict: FileComparisonSnapshot?
            if let conflictPath {
                let snapshot = try await repository.fileComparison(path: conflictPath)
                text = ""; preview = snapshot.requiresStaticPreview ? snapshot : nil
                conflict = snapshot.requiresStaticPreview ? nil : snapshot
            } else if let stashHash, let path = stashPath {
                let snapshot = try await repository.comparisonPreview(target: target)
                if snapshot.requiresStaticPreview { text = ""; preview = snapshot }
                else {
                    let raw = try await StashHistory.diff(repository: repository, hash: stashHash, path: path, untracked: untrackedStash)
                    text = try await snapshot.displayPatch(fallingBackFrom: raw, ignoreWhitespace: requestedIgnoreWhitespace)
                    preview = nil
                }
                conflict = nil
            } else {
                let result = try await repository.displayDiff(target: target, ignoreWhitespace: requestedIgnoreWhitespace)
                text = result.text; preview = result.preview; conflict = nil
            }
            guard !Task.isCancelled, diffVersion == version, self.repository === repository, requestedDiffIdentity == identity,
                  pendingRepositoryPath.map({ Self.sameRepositoryLocation(URL(fileURLWithPath: $0), repository.url) }) ?? true else { return }
            displayedDiffIdentity = identity
            if diffText != text { diffText = text }
            staticPreview = preview; conflictPreview = conflict
            diffRevisionFilename = revisions?.name; diffLeftRevision = revisions?.left; diffRightRevision = revisions?.right
            setDiffTitle(title, arguments: arguments)
        } catch { if !Task.isCancelled, diffVersion == version { report(error) } }
        if diffVersion == version { loadingDiff = false }
    }
    private func diffRevisionTitles(target: DiffTarget, repository: GitRepository) async throws -> (name: String, left: String, right: String)? {
        let path: String, left: String, right: String
        switch target {
        case let .staged(value):
            path = value; left = "HEAD"; right = "$index"
        case let .worktree(value, untracked):
            path = value; left = untracked ? "$empty" : "$index"; right = "$worktree"
        case let .commit(hash, value):
            path = value
            let commit: GitCommit?
            if let existing = commits.first(where: { $0.hash == hash }) { commit = existing }
            else { commit = try await repository.log(limit: 1, ref: hash).first }
            guard let commit else { return nil }
            left = commit.parents.first.map { String($0.prefix(8)) } ?? "$empty"; right = commit.shortHash
        }
        return ((path as NSString).lastPathComponent, left, right)
    }
    /// Local refs are advisory. This never contacts a remote or authorizes force push.
    func checkNetworkPreflight(_ operation: NetworkOperation, completion: @escaping (LocalNetworkPreflight?) -> Void) {
        guard let repository, workspaceStatusFailure == nil, !isBusy, pendingRepositoryPath == nil else { return }
        isBusy = true
        stopBackgroundRepositorySync()
        Task {
            let hint = try? await GitCommandLog.$suppressRoutineReads.withValue(true) {
                try await repository.localNetworkPreflight(operation)
            }
            guard self.repository === repository else { return }
            isBusy = false
            completion(hint)
        }
    }
    func operation(_ name: String, refreshFilesOnly: Bool = false, onFailure: ((Error) -> Void)? = nil, body: @escaping (GitRepository) async throws -> Void) {
        guard let repository, workspaceStatusFailure == nil, !isBusy, pendingRepositoryPath == nil else { return }
        cancelAutomaticRefresh()
        diffTask?.cancel(); diffTask = nil
        refreshReadVersion = UUID(); refreshingRepository = nil; diffVersion = UUID(); historyVersion = UUID()
        isBusy = true; beginUserOperation(name)
        let operationID = currentUserOperationID
        let progress = progressHandler(for: repository, operationID: operationID)
        Task {
            await cancelBackgroundRepositorySync()
            var failure: Error?
            do { try await GitCommandLog.$progress.withValue(progress) { try await GitCommandLog.$operationID.withValue(operationID) { try await GitCommandLog.$userInitiated.withValue(true) { try await body(repository) } } }; if !persistsSession { NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url) }; activityRecords.insert((Date(), name, nil), at: 0); setStatus("%@ completed", arguments: [name]) }
            catch { failure = error }
            finishUserOperation(name, repository: repository, failure: failure)
            isBusy = false
            if let failure { onFailure?(failure) }
            if refreshFilesOnly { await refreshFileStatus() }
            else { await refresh() }
        }
    }
    /// Runs against the captured sidebar target, even when another repository is active.
    func performRepositoryContextOperation(_ name: String, path: String, body: @escaping (GitRepository) async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        let target = GitRepository(url: URL(fileURLWithPath: path))
        let label = name + " · " + target.url.lastPathComponent
        isBusy = true; beginUserOperation(label)
        await cancelBackgroundRepositorySync()
        let operationID = currentUserOperationID
        let progress = progressHandler(for: target, operationID: operationID)
        var failure: Error?
        do {
            try await GitCommandLog.$progress.withValue(progress) { try await GitCommandLog.$operationID.withValue(operationID) {
                try await GitCommandLog.$userInitiated.withValue(true) { try await body(target) }
            } }
            activityRecords.insert((Date(), label, nil), at: 0)
            NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: target.url)
        } catch { failure = error }
        finishUserOperation(label, repository: target, failure: failure, reportInCurrentWindow: true)
        isBusy = false
        await refreshRepositoryContext(path: path)
        return failure == nil
    }
    func refreshRepositoryContext(path: String) async {
        if repositoryURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path { await refresh(); return }
        let target = GitRepository(url: URL(fileURLWithPath: path))
        guard let files = try? await target.status() else { return }
        let text = try? await target.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        let counts = text?.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) } ?? []
        publishRepositoryChangeCount(files.count, path: path)
        publishRepositorySyncState(RepositorySyncState(ahead: counts.count == 2 ? counts[0] : nil, behind: counts.count == 2 ? counts[1] : nil, conflicts: files.filter(\.isConflict).count), path: path)
    }
    var canStageSelection: Bool { repository != nil && !isBusy && !WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: selectedPaths).isEmpty }
    var canUnstageSelection: Bool { repository != nil && !isBusy && !WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: selectedPaths).isEmpty }
    func stageSelection() {
        let targets = WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: selectedPaths)
        let paths = files.filter { targets.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("暂存", refreshFilesOnly: true) { try await $0.stage(paths: paths) }
    }
    func unstageSelection() {
        let targets = WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: selectedPaths)
        let paths = files.filter { targets.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("取消暂存", refreshFilesOnly: true) { try await $0.unstage(paths: paths) }
    }
    func completeNetworkOperation(_ name: String, repository: GitRepository) {
        guard self.repository === repository else { return }
        errorMessage = nil
        finishUserOperation(name, repository: repository)
        activityRecords.insert((Date(), name, nil), at: 0)
        setStatus("%@ completed", arguments: [name])
        if !persistsSession { NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url) }
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let message = GitCommandLog.redact(error.localizedDescription)
        self.errorMessage = message
        setStatus("Operation failed"); activityRecords.insert((nil, nil, message), at: 0)
    }
}

@MainActor
final class AuvGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: RepositoryStore?
    private var refreshTimer: Timer?
    private var pollingTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        startRepositoryPolling()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    // The borderless shell hides the bootstrap SwiftUI window. App lifecycle
    // and periodic work must not depend on that scene's subscriptions staying live.
    func startRepositoryPolling(interval: TimeInterval = 30) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pollingTask == nil else { return }
                self.pollingTask = Task { [weak self] in
                    await RepositoryStore.pollAllRepositories()
                    self?.pollingTask = nil
                }
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        RepositoryStore.setApplicationActiveForAllStores(true)
    }
    func applicationDidResignActive(_ notification: Notification) {
        RepositoryStore.setApplicationActiveForAllStores(false)
    }
    @objc private func didWake(_ notification: Notification) {
        RepositoryStore.setApplicationActiveForAllStores(false)
        RepositoryStore.setApplicationActiveForAllStores(NSApp.isActive)
    }
    @objc private func windowBecameKey(_ notification: Notification) {
        RepositoryStore.checkRemoteUpdatesForActivePanel()
    }
    deinit { refreshTimer?.invalidate(); pollingTask?.cancel(); NSWorkspace.shared.notificationCenter.removeObserver(self); NotificationCenter.default.removeObserver(self) }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate(); pollingTask?.cancel()
        store?.stopBackgroundRepositorySync(); store?.flushSession()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ComparePresenter.hasUnsavedChanges || WorkspaceTextPreviewPresenter.hasUnsavedChanges else { store?.flushSession(); return .terminateNow }
        Task {
            let previewApproved = WorkspaceTextPreviewPresenter.prepareToTerminate()
            let approved = previewApproved ? await ComparePresenter.prepareToTerminate() : false
            if approved { self.store?.flushSession() }
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }
}
