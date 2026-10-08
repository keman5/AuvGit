import SwiftUI
import AppKit
import Combine
import GitCore
import RayGitLocalization

@main
struct RayGitApp: App {
    @NSApplicationDelegateAdaptor(RayGitApplicationDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()
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
        NotificationCenter.default.post(name: .rayGitWorkspaceShortcut, object: command.rawValue, userInfo: ["window": window])
    }
    var body: some Scene {
        WindowGroup {
            MainWindow(store: store)
                .nativeFocusRoot()
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 1000)
                .task { appDelegate.store = store; RayGitPreferences.applyAppearance(); await store.restore() }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in RayGitPreferences.applyAppearance() }
                .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in Task { await store.pollForChanges() } }
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
                .nativeFocusRoot()
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 860, height: 660)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class RepositoryStore: ObservableObject {
    @Published var repository: GitRepository?
    @Published var repositoryURL: URL?
    @Published var openRepositories: [String] = []
    @Published var repositoryGroups = UserDefaults.standard.dictionary(forKey: "repositoryGroups") as? [String: String] ?? [:]
    private let persistsSession: Bool
    private var accessedURL: URL?
    private var fileObserver: RepositoryFileObserver?
    private var filesystemRefresh: Task<Void, Never>?
    private var filesystemRefreshing = false
    private var filesystemPending = false
    private var checkingFilesystemState = false
    private let sessionKey = "repositorySession.v1"
    private var session = RepositorySession()
    private var sessionObserver: AnyCancellable?
    private var commandObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var lastSavedSession: Data?
    var isRestoringViewState = false
    let followsCurrentBranch: Bool
    private let usesCheckedHistoryScope: Bool
    private var lastMainHistoryHead: String?
    init(persistsSession: Bool = true, followsCurrentBranch: Bool? = nil, usesCheckedHistoryScope: Bool = false) {
        self.persistsSession = persistsSession
        self.followsCurrentBranch = followsCurrentBranch ?? persistsSession
        self.usesCheckedHistoryScope = usesCheckedHistoryScope
        Self.stores.add(self)
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
        session = recovery.session; openRepositories = RayGitPreferences.restoreRepositories ? session.openRepositories : []; lastSavedSession = recovery.source
        if let corrupt = recovery.corruptPrimary { UserDefaults.standard.set(corrupt, forKey: sessionKey + ".corrupt") }
        sessionObserver = objectWillChange.debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] _ in self?.flushSession() }
    }
    /// A Log window owns this transient store, not the main workspace session.
    func closeTransientSession() {
        guard !persistsSession else { return }
        openingTask?.cancel(); openingTask = nil; openingVersion = UUID()
        fileObserver = nil
        filesystemRefresh?.cancel(); filesystemRefresh = nil
        searchTask?.cancel(); searchTask = nil
        diffTask?.cancel(); diffTask = nil
        repoVersion = UUID(); historyVersion = UUID(); detailVersion = UUID(); diffVersion = UUID()
        accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = nil
        repository = nil; repositoryURL = nil
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
        guard persistsSession, !isRestoringViewState, repositoryURL != nil || RayGitPreferences.restoreRepositories else { return }
        if let path = repositoryURL?.path { session.repositories[path] = captureViewState() }
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
        openRepositories.removeAll { $0 == path }
        guard repositoryURL?.path == path else { flushSession(); return }
        fileObserver = nil; filesystemRefresh?.cancel(); repository = nil; repositoryURL = nil
        files = []; commits = []; branches = []; stashes = []; commitFiles = []; selectedPaths = []; selectedCommit = nil; selectedCommitPath = nil
        commitMessage = ""; amend = false; accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = nil
        let candidates = Array(openRepositories.reversed()); session.activeRepository = candidates.first; flushSession()
        Task {
            for candidate in candidates {
                await open(URL(fileURLWithPath: candidate))
                if repository != nil { return }
            }
        }
    }
    func setGroup(path: String, group: String) { repositoryGroups[path] = group; UserDefaults.standard.set(repositoryGroups, forKey: "repositoryGroups") }
    @Published var recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    @Published var repositoryChangeCounts: [String: Int] = [:]
    struct RepositorySyncState: Equatable { let ahead: Int?; let behind: Int?; let conflicts: Int }
    @Published var repositorySyncStates: [String: RepositorySyncState] = [:]
    @Published private var commandLog: [GitCommandRecord] = []
    @Published private var userOperationLog: [GitCommandRecord] = []
    @Published private var userCommandLog: [GitCommandRecord] = []
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
            return status + " · " + detail
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
    @Published var historyPinnedCommit: String?
    @Published var commitMessage = ""
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
    private var openingRepositoryPath: String?
    @Published private(set) var pendingRepositoryPath: String?
    var highlightedRepositoryPath: String? { pendingRepositoryPath ?? repositoryURL?.path }
    private var openingVersion = UUID()
    private var openingTask: Task<Void, Never>?
    var canOpenRepository: Bool { !isBusy || openingRepositoryPath != nil }
    private var recentSyncTask: Task<Void, Never>?
    private var recentSyncDate = Date.distantPast
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
    var filteredFiles: [GitFile] { files.filter { fileFilter.isEmpty || RayGitPreferences.matches($0.path, query: fileFilter) } }
    var stagedCount: Int { files.filter { $0.isStaged && !$0.isConflict }.count }

    func restore() async {
        guard !restored else { return }; restored = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--repo"), args.indices.contains(i + 1) {
            await open(URL(fileURLWithPath: args[i + 1]))
        } else if RayGitPreferences.restoreRepositories {
            let candidates = session.restorationCandidates().isEmpty ? recentPaths : session.restorationCandidates()
            var failures: [String] = []
            for path in candidates {
                await open(URL(fileURLWithPath: path))
                if repository != nil { break }
                failures.append(path)
            }
            if !failures.isEmpty { errorMessage = sessionText("Unavailable repositories") + "\n" + failures.joined(separator: "\n") }
        }
    }
    private func defaultViewState() -> RepositoryViewState {
        var value = RepositoryViewState(); value.mode = persistsSession ? "workspace" : "history"; return value
    }
    func clearRecentRepositories() { recentPaths = []; UserDefaults.standard.removeObject(forKey: "recentRepositories") }
    private func registerRepositoryPaths(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if !openRepositories.contains(where: { Self.sameRepositoryLocation(URL(fileURLWithPath: $0), url) }) { openRepositories.append(path) }
            if !recentPaths.contains(where: { Self.sameRepositoryLocation(URL(fileURLWithPath: $0), url) }) { recentPaths.append(path) }
        }
        if persistsSession { UserDefaults.standard.set(recentPaths, forKey: "recentRepositories") }
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
    func requestOpen(_ url: URL) -> Task<Void, Never>? {
        guard canOpenRepository else { return nil }
        pendingRepositoryPath = url.path
        openingTask?.cancel()
        let version = UUID(); openingVersion = version
        let task = Task {
            await Task.yield()
            await performOpen(url, version: version)
        }
        openingTask = task
        return task
    }
    func open(_ url: URL) async {
        guard let task = requestOpen(url) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performOpen(_ url: URL, version: UUID) async {
        guard openingVersion == version else { return }
        defer {
            if openingVersion == version {
                if openingRepositoryPath != nil { isBusy = false }
                openingRepositoryPath = nil; pendingRepositoryPath = nil; isRestoringViewState = false; openingTask = nil; flushSession()
            }
        }
        guard !Task.isCancelled else { return }
        if !isBusy, !isRestoringViewState, let repositoryURL, Self.sameRepositoryLocation(url, repositoryURL) {
            await refreshFileStatus()
            return
        }
        refreshReadVersion = UUID(); refreshingRepository = nil
        repoVersion = UUID(); historyVersion = UUID(); detailVersion = UUID(); diffVersion = UUID()
        diffTask?.cancel(); diffTask = nil
        openingRepositoryPath = url.path
        if let path = repositoryURL?.path { session.repositories[path] = captureViewState() }
        flushSession()
        isRestoringViewState = true
        isBusy = true; errorMessage = nil; latestOperationKey = nil; setStatus("Opening repository…")
        fileObserver = nil; filesystemRefresh?.cancel(); searchTask?.cancel()
        repository = nil; repositoryURL = nil
        files = []; branches = []; branch = ""; commits = []; commitFiles = []; stashes = []
        selectedPaths = []; automaticallySelectedPath = nil; initialWorkspaceSelectionReady = false; selectedCommit = nil; selectedCommitPath = nil
        commitMessage = ""; amend = false
        clearDiff(); setDiffTitle("Select a file to view changes")
        loadingHistory = false
        do {
            var selectedURL = url
            if let data = UserDefaults.standard.data(forKey: "bookmark:" + url.path) { var stale = false; if let restored = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) { selectedURL = restored } }
            let accessed = selectedURL.startAccessingSecurityScopedResource()
            let repo: GitRepository
            do { repo = try await GitRepository.open(selectedURL) } catch { if accessed { selectedURL.stopAccessingSecurityScopedResource() }; throw error }
            guard !Task.isCancelled, openingVersion == version else { if accessed { selectedURL.stopAccessingSecurityScopedResource() }; return }
            accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = accessed ? selectedURL : nil
            if persistsSession, let data = try? selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(data, forKey: "bookmark:" + repo.url.path) }
            registerRepositoryPaths([repo.url.path])
            if let worktrees = try? await repo.worktrees() {
                var linkedPaths: [String] = []
                for worktree in worktrees where !worktree.isBare && !worktree.isPrunable {
                    guard let linked = try? await GitRepository.open(URL(fileURLWithPath: worktree.path)) else { continue }
                    linkedPaths.append(linked.url.path)
                }
                registerRepositoryPaths(linkedPaths)
            }
            let root = repo.url
            diffTask?.cancel(); diffTask = nil
            repoVersion = UUID(); diffVersion = UUID(); detailVersion = UUID(); historyVersion = UUID()
            repository = repo; repositoryURL = root
            fileObserver = nil; filesystemRefresh?.cancel()
            async let gitDirectoryRead = repo.workflowRead(["rev-parse", "--absolute-git-dir"])
            async let commonPathRead = repo.workflowRead(["rev-parse", "--git-common-dir"])
            lastObservedState = nil; lastHistoryState = nil; lastMainHistoryHead = nil; checkedHistoryRefs = nil; historyPinnedCommit = nil
            let restoredView = session.repositories[root.path] ?? session.repositories[url.path] ?? defaultViewState()
            applyViewState(restoredView)
            if followsCurrentBranch { selectFirstHistoryCommit = true; selectedCommit = nil; selectedCommitPath = nil; historyNavigationGeneration = UUID() }
            openingRepositoryPath = nil; isBusy = false
            async let refreshed: Void = refresh()
            let gitDirectory = try await gitDirectoryRead.trimmingCharacters(in: .newlines)
            guard !Task.isCancelled, openingVersion == version else { return }
            let commonPath = try await commonPathRead.trimmingCharacters(in: .newlines)
            guard !Task.isCancelled, openingVersion == version else { return }
            let commonURL = commonPath.hasPrefix("/") ? URL(fileURLWithPath: commonPath) : root.appendingPathComponent(commonPath).standardizedFileURL
            fileObserver = RepositoryFileObserver(paths: Array(Set([root.path, gitDirectory, commonURL.path]))) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleFilesystemRefresh(root: root) }
            }
            await refreshed
            guard !Task.isCancelled, openingVersion == version else { return }
            refreshRecentRepositoryStates()
            if let hash = restoredView.selectedCommit, !followsCurrentBranch, (try? await repo.workflowRevision(hash)) != nil {
                guard !Task.isCancelled, openingVersion == version else { return }
                selectedCommit = hash; await loadCommitFiles()
                guard !Task.isCancelled, openingVersion == version else { return }
                if let path = restoredView.selectedCommitPath, commitFiles.contains(where: { $0.path == path }) { selectedCommitPath = path; await loadDiff() }
            }
        } catch { if openingVersion == version, !Task.isCancelled, !(error is CancellationError) { report(error) } }
    }
    private func scheduleFilesystemRefresh(root: URL) {
        guard RayGitPreferences.backgroundRefresh, repositoryURL == root else { return }
        if filesystemRefreshing { filesystemPending = true; return }
        // FSEvents already coalesces bursts; do not add another debounce.
        // Clear the task before Git so new events never cancel an active read.
        filesystemRefresh?.cancel()
        filesystemRefresh = Task {
            guard RayGitPreferences.backgroundRefresh, !Task.isCancelled, repositoryURL == root else { return }
            filesystemRefresh = nil
            if isBusy { return } // The active write ends with its own refresh.
            filesystemRefreshing = true
            await refreshIfChanged()
            filesystemRefreshing = false
            if filesystemPending { filesystemPending = false; await refreshIfChanged() }
        }
    }
    private var lastPoll = Date.distantPast
    func pollForChanges() async {
        refreshRecentRepositoryStates()
        guard RayGitPreferences.backgroundRefresh, Date().timeIntervalSince(lastPoll) >= RayGitPreferences.pollInterval else { return }
        lastPoll = Date(); await refreshIfChanged()
    }
    private var lastObservedState: RepositoryChangeState?
    private var lastHistoryState: String?
    func refreshIfChanged() async {
        guard let repository, !isBusy, !checkingFilesystemState else { return }
        let version = repoVersion, readVersion = refreshReadVersion
        checkingFilesystemState = true
        defer { checkingFilesystemState = false }
        do {
            let (newFiles, state) = try await GitCommandLog.$suppressRoutineReads.withValue(true) {
                let newFiles = try await repository.status()
                guard version == repoVersion, readVersion == refreshReadVersion, !isBusy else { throw CancellationError() }
                applyFileStatus(newFiles)
                return try await (newFiles, repository.changeState(files: newFiles))
            }
            guard version == repoVersion, readVersion == refreshReadVersion, !isBusy, repositoryURL == repository.url, state != lastObservedState else { return }
            await refresh(knownFiles: newFiles, knownState: state)
        } catch { /* A canceled background read never becomes an operation error. */ }
    }
    func refresh(knownFiles: [GitFile]? = nil, knownState: RepositoryChangeState? = nil) async {
        guard let repository, !isBusy, refreshingRepository != repository.url else { return }
        refreshingRepository = repository.url; let version = repoVersion
        let refreshVersion = UUID(); refreshReadVersion = refreshVersion
        defer { if refreshReadVersion == refreshVersion { refreshingRepository = nil } }
        do {
            async let newFiles: [GitFile] = { if let knownFiles { return knownFiles }; return try await repository.status() }()
            async let newBranches = repository.branches()
            async let newBranch = repository.currentBranch()
            async let newStashes = repository.stashes()
            async let syncRead = GitCommandLog.$suppressRoutineReads.withValue(true) {
                try? await repository.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            }
            let fileStatus = try await newFiles
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            applyFileStatus(fileStatus)
            async let stateRead: RepositoryChangeState = { if let knownState { return knownState }; return try await repository.changeState(files: fileStatus) }()
            async let workspaceDiff: Void = mode == "workspace" ? loadDiff() : ()
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            if repositoryChangeCounts[repository.url.path] != fileStatus.count { repositoryChangeCounts[repository.url.path] = fileStatus.count }
            let result = try await (fileStatus, newBranches, newBranch, newStashes)
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            if branches != result.1 { branches = result.1 }
            if branch != result.2 { branch = result.2 }
            if stashes != result.3 { stashes = result.3 }
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            let observedState = try await stateRead
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            if followsCurrentBranch {
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
            if mode != "workspace", observedState != lastObservedState { await loadDiff() }
            if version == repoVersion, refreshReadVersion == refreshVersion { lastObservedState = observedState }
            let syncText = await syncRead
            let syncCounts = syncText?.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) } ?? []
            guard !Task.isCancelled, version == repoVersion, refreshReadVersion == refreshVersion else { return }
            let syncState = RepositorySyncState(ahead: syncCounts.count == 2 ? syncCounts[0] : nil, behind: syncCounts.count == 2 ? syncCounts[1] : nil, conflicts: result.0.filter(\.isConflict).count)
            if repositorySyncStates[repository.url.path] != syncState { repositorySyncStates[repository.url.path] = syncState }
            await workspaceDiff
        } catch { if !Task.isCancelled, !(error is CancellationError), version == repoVersion, refreshReadVersion == refreshVersion { report(error) } }
    }
    static func sameRepositoryLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
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
            if repositoryChangeCounts[repository.url.path] != newFiles.count { repositoryChangeCounts[repository.url.path] = newFiles.count }
            let previous = repositorySyncStates[repository.url.path]
            let sync = RepositorySyncState(ahead: previous?.ahead, behind: previous?.behind, conflicts: newFiles.filter(\.isConflict).count)
            if previous != sync { repositorySyncStates[repository.url.path] = sync }
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            if state != lastObservedState { await loadDiff() }
            if version == repoVersion, refreshReadVersion == refreshVersion, state.history == lastHistoryState { lastObservedState = state }
        } catch { if !Task.isCancelled, !(error is CancellationError), version == repoVersion, refreshReadVersion == refreshVersion { report(error) } }
    }
    func stopBackgroundRepositorySync() {
        Self.stores.allObjects.forEach { $0.recentSyncTask?.cancel() }
    }
    func cancelBackgroundRepositorySync() async {
        let tasks = Self.stores.allObjects.compactMap(\.recentSyncTask)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
    func refreshRecentRepositoryStates(now: Date = Date()) {
        guard persistsSession, RayGitPreferences.backgroundRefresh, recentSyncTask == nil,
              !Self.stores.allObjects.contains(where: { $0.isBusy }), now.timeIntervalSince(recentSyncDate) > 30 else { return }
        recentSyncDate = now
        var seen = Set<String>()
        let paths = (recentPaths + openRepositories + [repositoryURL?.path].compactMap { $0 }).filter { seen.insert($0).inserted }
        nextRemoteSync = nextRemoteSync.filter { paths.contains($0.key) }
        recentSyncTask = Task {
            for path in paths {
                guard !Task.isCancelled, RayGitPreferences.backgroundRefresh, !Self.stores.allObjects.contains(where: { $0.isBusy }) else { break }
                guard (recentPaths + openRepositories + [repositoryURL?.path].compactMap { $0 }).contains(path) else { continue }
                let repo = GitRepository(url: URL(fileURLWithPath: path))
                if now >= (nextRemoteSync[path] ?? .distantPast) {
                    do {
                        try await repo.backgroundFetch()
                        nextRemoteSync[path] = Date().addingTimeInterval(Double.random(in: 90...150))
                    } catch {
                        if Task.isCancelled { break }
                        nextRemoteSync[path] = Date().addingTimeInterval(300)
                    }
                }
                guard !Task.isCancelled, let files = try? await GitCommandLog.$suppressRoutineReads.withValue(true, operation: { try await repo.status() }) else { continue }
                let text = try? await GitCommandLog.$suppressRoutineReads.withValue(true) { try await repo.workflowRead(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) }
                guard !Task.isCancelled, RayGitPreferences.backgroundRefresh,
                      (recentPaths + openRepositories + [repositoryURL?.path].compactMap { $0 }).contains(path) else { continue }
                let counts = text?.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) } ?? []
                if repositoryChangeCounts[path] != files.count { repositoryChangeCounts[path] = files.count }
                let state = RepositorySyncState(ahead: counts.count == 2 ? counts[0] : nil, behind: counts.count == 2 ? counts[1] : nil, conflicts: files.filter(\.isConflict).count)
                if repositorySyncStates[path] != state { repositorySyncStates[path] = state }
            }
            recentSyncTask = nil
        }
    }
    private func resetMainHistorySelection() {
        historyRef = nil; historyPath = nil; selectedCommit = nil; selectedCommitPath = nil; commitFiles = []
        selectFirstHistoryCommit = true; historyNavigationGeneration = UUID()
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
        let version = UUID(); historyVersion = version; loadingHistory = true
        let skip = reset ? 0 : historyLoadedCount
        do {
            let stashHashes: [String]
            if followsCurrentBranch { stashHashes = stashes.map(\.hash) }
            else if historyPinnedCommit == nil, historyStashHash == nil, historyRef?.hasPrefix("refs/tags/") != true {
                stashHashes = HistoryBranchScope.selectedStashHashes(checkedHistoryRefs ?? [HistoryBranchScope.allStashes], stashes: stashes)
            } else { stashHashes = [] }
            let rows = try await repository.log(limit: RayGitPreferences.historyPageSize, skip: skip, search: historySearch, path: followsCurrentBranch ? nil : historyPath, ref: followsCurrentBranch ? "HEAD" : (historyPinnedCommit ?? historyRef), author: historyAuthor, firstParent: followsCurrentBranch && !showMergedCommits, refs: followsCurrentBranch || historyPinnedCommit != nil || historyStashHash != nil || historyRef?.hasPrefix("refs/tags/") == true ? nil : checkedHistoryRefs.map { HistoryBranchScope.revisionRefs($0, branches: branches, stashes: stashes) }, stashHashes: stashHashes, includeRecyclable: !followsCurrentBranch && historyPinnedCommit == nil && historyStashHash == nil && historyRef?.hasPrefix("refs/tags/") != true && checkedHistoryRefs?.contains(HistoryBranchScope.recyclable) == true)
            guard historyVersion == version else { return }
            let updatedCommits = reset ? rows : commits + rows.filter { row in !commits.contains(where: { $0.hash == row.hash }) }
            if commits != updatedCommits { commits = updatedCommits }; historyLoadedCount = skip + rows.count; hasMore = rows.count == RayGitPreferences.historyPageSize
            if reset, selectFirstHistoryCommit {
                selectFirstHistoryCommit = false; selectedCommit = rows.first?.hash
                await loadCommitFiles()
                guard !Task.isCancelled, historyVersion == version else { return }
            }
            if let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit }) {
                if !followsCurrentBranch, checkedHistoryRefs == nil || historyStashHash != nil, let selected = try? await repository.log(limit: 1, ref: selectedCommit).first, historyVersion == version { commits.append(selected) }
                else if !isRestoringViewState { self.selectedCommit = nil; commitFiles = []; selectedCommitPath = nil }
            }
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
    var canMutateDisplayedDiff: Bool { pendingRepositoryPath == nil && !loadingDiff && displayedDiffIdentity == requestedDiffIdentity }
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
        guard let repository, !isBusy, pendingRepositoryPath == nil else { return }
        isBusy = true
        Task {
            await cancelBackgroundRepositorySync()
            let hint = try? await GitCommandLog.$suppressRoutineReads.withValue(true) {
                try await repository.localNetworkPreflight(operation)
            }
            guard self.repository === repository else { return }
            isBusy = false
            completion(hint)
        }
    }
    func operation(_ name: String, onFailure: ((Error) -> Void)? = nil, body: @escaping (GitRepository) async throws -> Void) {
        guard let repository, !isBusy, pendingRepositoryPath == nil else { return }
        diffTask?.cancel(); diffTask = nil
        refreshReadVersion = UUID(); refreshingRepository = nil; diffVersion = UUID(); historyVersion = UUID()
        isBusy = true; beginUserOperation(name)
        let operationID = currentUserOperationID
        let progress = progressHandler(for: repository, operationID: operationID)
        Task {
            await cancelBackgroundRepositorySync()
            var failure: Error?
            do { try await GitCommandLog.$progress.withValue(progress) { try await GitCommandLog.$operationID.withValue(operationID) { try await GitCommandLog.$userInitiated.withValue(true) { try await body(repository) } } }; if !persistsSession { NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url) }; activityRecords.insert((Date(), name, nil), at: 0); setStatus("%@ completed", arguments: [name]) }
            catch { failure = error }
            finishUserOperation(name, repository: repository, failure: failure)
            isBusy = false
            if let failure { onFailure?(failure) }
            await refresh()
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
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: target.url)
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
        repositoryChangeCounts[path] = files.count
        repositorySyncStates[path] = RepositorySyncState(ahead: counts.count == 2 ? counts[0] : nil, behind: counts.count == 2 ? counts[1] : nil, conflicts: files.filter(\.isConflict).count)
    }
    var canStageSelection: Bool { repository != nil && !isBusy && !WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: selectedPaths).isEmpty }
    var canUnstageSelection: Bool { repository != nil && !isBusy && !WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: selectedPaths).isEmpty }
    func stageSelection() {
        let targets = WorkspaceFileActionTargets.paths(for: .stage, files: files, selection: selectedPaths)
        let paths = files.filter { targets.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("暂存") { try await $0.stage(paths: paths) }
    }
    func unstageSelection() {
        let targets = WorkspaceFileActionTargets.paths(for: .unstage, files: files, selection: selectedPaths)
        let paths = files.filter { targets.contains($0.path) }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("取消暂存") { try await $0.unstage(paths: paths) }
    }
    func completeNetworkOperation(_ name: String, repository: GitRepository) {
        guard self.repository === repository else { return }
        errorMessage = nil
        finishUserOperation(name, repository: repository)
        activityRecords.insert((Date(), name, nil), at: 0)
        setStatus("%@ completed", arguments: [name])
        if !persistsSession { NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url) }
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let message = GitCommandLog.redact(error.localizedDescription)
        self.errorMessage = message
        setStatus("Operation failed"); activityRecords.insert((nil, nil, message), at: 0)
    }
}

@MainActor
final class RayGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: RepositoryStore?
    func applicationWillTerminate(_ notification: Notification) { store?.stopBackgroundRepositorySync(); store?.flushSession() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ComparePresenter.hasUnsavedChanges else { store?.flushSession(); return .terminateNow }
        Task { let approved = await ComparePresenter.prepareToTerminate(); if approved { self.store?.flushSession() }; sender.reply(toApplicationShouldTerminate: approved) }
        return .terminateLater
    }
}
