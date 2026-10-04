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
    @AppStorage("shortcut.open") private var openKey = "o"
    @AppStorage("shortcut.refresh") private var refreshKey = "r"
    @AppStorage("shortcut.stage") private var stageKey = "t"
    @AppStorage("shortcut.commit") private var commitKey = "k"
    private var configuredShortcuts: [String] { ShortcutRules.normalized([openKey, refreshKey, stageKey, commitKey]) }
    var body: some Scene {
        WindowGroup {
            MainWindow(store: store)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 1000)
                .task { appDelegate.store = store; RayGitPreferences.applyAppearance(); await store.restore() }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in RayGitPreferences.applyAppearance() }
                .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in Task { await store.pollForChanges() } }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Open Repository…")) { store.chooseRepository() }.keyboardShortcut(KeyEquivalent(configuredShortcuts[0].first ?? "o"))
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Refresh Repository")) { Task { await store.refresh() } }.keyboardShortcut(KeyEquivalent(configuredShortcuts[1].first ?? "r"))
                    .disabled(store.repository == nil || store.isBusy)
                Button(L10n.text("Stage Selected Files")) { store.stageSelection() }.keyboardShortcut(KeyEquivalent(configuredShortcuts[2].first ?? "t"))
                    .disabled(store.selectedPaths.isEmpty || store.isBusy)
                Button(compareText("Commit")) { store.commit() }.keyboardShortcut(KeyEquivalent(configuredShortcuts[3].first ?? "k"))
                    .disabled(store.repository == nil || store.isBusy || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        Settings {
            PreferencesWindow(store: store)
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
    private var accessedURL: URL?
    private var fileObserver: RepositoryFileObserver?
    private var filesystemRefresh: Task<Void, Never>?
    private var filesystemRefreshing = false
    private var filesystemPending = false
    private var checkingFilesystemState = false
    private let sessionKey = "repositorySession.v1"
    private var session = RepositorySession()
    private var sessionObserver: AnyCancellable?
    private var lastSavedSession: Data?
    var isRestoringViewState = false
    init() {
        let recovery = RepositorySession.recover(primary: UserDefaults.standard.data(forKey: sessionKey), backup: UserDefaults.standard.data(forKey: sessionKey + ".backup"))
        session = recovery.session; openRepositories = RayGitPreferences.restoreRepositories ? session.openRepositories : []; lastSavedSession = recovery.source
        if let corrupt = recovery.corruptPrimary { UserDefaults.standard.set(corrupt, forKey: sessionKey + ".corrupt") }
        sessionObserver = objectWillChange.debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] _ in self?.flushSession() }
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
        guard !isRestoringViewState, repositoryURL != nil || RayGitPreferences.restoreRepositories else { return }
        if let path = repositoryURL?.path { session.repositories[path] = captureViewState() }
        session.openRepositories = openRepositories; session.activeRepository = repositoryURL?.path ?? (openRepositories.isEmpty ? nil : session.activeRepository)
        if let data = try? session.encoded(), data != lastSavedSession { if let previous = lastSavedSession { UserDefaults.standard.set(previous, forKey: sessionKey + ".backup") }; UserDefaults.standard.set(data, forKey: sessionKey); lastSavedSession = data }
    }
    private func applyViewState(_ value: RepositoryViewState) {
        commitMessage = value.commitMessage; amend = value.amend; historySearch = value.historySearch; historyAuthor = value.historyAuthor
        historyPath = value.historyPath; historyRef = value.historyRef; selectedPaths = value.selectedPaths
        selectedCommit = value.selectedCommit; selectedCommitPath = value.selectedCommitPath; mode = value.mode; fileFilter = value.fileFilter
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
    @Published var files: [GitFile] = []
    @Published var filesGeneration = UUID()
    @Published var branches: [GitBranch] = []
    @Published var stashes: [GitStash] = []
    @Published var branch = ""
    @Published var commits: [GitCommit] = []
    @Published var commitFiles: [GitCommitFile] = []
    @Published var selectedPaths: Set<String> = []
    @Published var selectedCommit: String?
    @Published var selectedCommitPath: String?
    @Published var mode = "workspace"
    @Published var stagedDiff = false
    @Published var ignoreWhitespace = false
    @Published var diffText = ""
    @Published var conflictPreview: FileComparisonSnapshot?
    @Published private var diffTitleKey = "Select a file to view changes"
    @Published private var diffTitleArguments: [String] = []
    var diffTitle: String { L10n.text(diffTitleKey, arguments: diffTitleArguments.map { $0 as CVarArg }) }
    @Published var fileFilter = ""
    @Published var historySearch = ""
    @Published var historyAuthor = ""
    @Published var historyPath: String?
    @Published var historyRef: String?
    @Published var commitMessage = ""
    @Published var amend = false
    @Published var isBusy = false
    @Published var loadingDiff = false
    @Published var loadingHistory = false
    @Published var hasMore = false
    @Published private var statusKey = "Open a Git repository to begin"
    @Published private var statusArguments: [String] = []
    var status: String { L10n.text(statusKey, arguments: statusArguments.map { operationName($0) as CVarArg }) }
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
    private func setStatus(_ key: String, arguments: [String] = []) { statusKey = key; statusArguments = arguments }
    private func setDiffTitle(_ key: String, arguments: [String] = []) { diffTitleKey = key; diffTitleArguments = arguments }
    private func operationName(_ name: String) -> String { L10n.text(name) }
    private func localizedError(_ message: String) -> String {
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
    private var historyVersion = UUID()
    private var detailVersion = UUID()
    private var searchTask: Task<Void, Never>?
    private var historyLoadedCount = 0
    var selectedFile: GitFile? { files.first { $0.path == selectedPaths.sorted().first } }
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
        var value = RepositoryViewState(); value.mode = RayGitPreferences.defaultMode; return value
    }
    func clearRecentRepositories() { recentPaths = []; UserDefaults.standard.removeObject(forKey: "recentRepositories") }
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
    func open(_ url: URL) async {
        guard !isBusy else { return }
        flushSession()
        isRestoringViewState = true
        defer { isRestoringViewState = false; flushSession() }
        isBusy = true; errorMessage = nil; setStatus("Opening repository…")
        do {
            var selectedURL = url
            if let data = UserDefaults.standard.data(forKey: "bookmark:" + url.path) { var stale = false; if let restored = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) { selectedURL = restored } }
            let accessed = selectedURL.startAccessingSecurityScopedResource()
            let repo: GitRepository
            do { repo = try await GitRepository.open(selectedURL) } catch { if accessed { selectedURL.stopAccessingSecurityScopedResource() }; throw error }
            accessedURL?.stopAccessingSecurityScopedResource(); accessedURL = accessed ? selectedURL : nil
            if let data = try? selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(data, forKey: "bookmark:" + repo.url.path) }
            if !openRepositories.contains(repo.url.path) { openRepositories.append(repo.url.path) }
            let root = repo.url
            repoVersion = UUID(); diffVersion = UUID(); detailVersion = UUID(); historyVersion = UUID()
            repository = repo; repositoryURL = root
            fileObserver = nil; filesystemRefresh?.cancel()
            let gitDirectory = try await repo.workflowRead(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
            lastObservedState = nil; lastHistoryState = nil
            let commonPath = try await repo.workflowRead(["rev-parse", "--git-common-dir"]).trimmingCharacters(in: .newlines)
            let commonURL = commonPath.hasPrefix("/") ? URL(fileURLWithPath: commonPath) : root.appendingPathComponent(commonPath).standardizedFileURL
            fileObserver = RepositoryFileObserver(paths: Array(Set([root.path, gitDirectory, commonURL.path]))) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleFilesystemRefresh(root: root) }
            }
            files = []; branches = []; commits = []; commitFiles = []; stashes = []
            selectedPaths = []; selectedCommit = nil; selectedCommitPath = nil; diffText = ""; conflictPreview = nil
            let restoredView = session.repositories[root.path] ?? session.repositories[url.path] ?? defaultViewState()
            applyViewState(restoredView)
            if !recentPaths.contains(root.path) {
                recentPaths.append(root.path)
                UserDefaults.standard.set(recentPaths, forKey: "recentRepositories")
            }
            isBusy = false; await refresh()
            if let hash = restoredView.selectedCommit, (try? await repo.workflowRevision(hash)) != nil {
                selectedCommit = hash; await loadCommitFiles()
                if let path = restoredView.selectedCommitPath, commitFiles.contains(where: { $0.path == path }) { selectedCommitPath = path; await loadDiff() }
            }
        } catch { report(error); isBusy = false }
    }
    private func scheduleFilesystemRefresh(root: URL) {
        guard RayGitPreferences.backgroundRefresh, repositoryURL == root else { return }
        if filesystemRefreshing { filesystemPending = true; return }
        // This reference belongs only to the sleeping debounce task. Clear it
        // before starting Git so a new event never cancels an active refresh.
        filesystemRefresh?.cancel()
        filesystemRefresh = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
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
        guard RayGitPreferences.backgroundRefresh, Date().timeIntervalSince(lastPoll) >= RayGitPreferences.pollInterval else { return }
        lastPoll = Date(); await refreshIfChanged()
    }
    private var lastObservedState: RepositoryChangeState?
    private var lastHistoryState: String?
    func refreshIfChanged() async {
        guard let repository, !isBusy, !checkingFilesystemState else { return }
        let version = repoVersion
        checkingFilesystemState = true
        defer { checkingFilesystemState = false }
        do {
            let files = try await repository.status()
            let state = try await repository.changeState(files: files)
            guard version == repoVersion, repositoryURL == repository.url, state != lastObservedState else { return }
            await refresh()
        } catch { /* A canceled background read never becomes an operation error. */ }
    }
    func refresh() async {
        guard let repository, !isBusy else { return }
        isBusy = true; let version = repoVersion
        defer { if version == repoVersion { isBusy = false } }
        do {
            async let newFiles = repository.status()
            async let newBranches = repository.branches()
            async let newBranch = repository.currentBranch()
            async let newStashes = repository.stashes()
            let result = try await (newFiles, newBranches, newBranch, newStashes)
            guard version == repoVersion else { return }
            repositoryChangeCounts[repository.url.path] = result.0.count
            files = result.0; filesGeneration = UUID(); branches = result.1; branch = result.2; stashes = result.3
            selectedPaths.formIntersection(Set(files.map(\.path)))
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            let observedState = try await repository.changeState(files: files)
            guard version == repoVersion else { return }
            if lastHistoryState != observedState.history {
                await loadHistory(reset: true)
                if version == repoVersion { lastHistoryState = observedState.history }
            }
            await loadDiff()
            if version == repoVersion { lastObservedState = observedState }
        } catch { report(error) }
    }
    func loadHistory(reset: Bool) async {
        guard let repository else { return }
        let version = UUID(); historyVersion = version; loadingHistory = true
        let skip = reset ? 0 : historyLoadedCount
        do {
            let rows = try await repository.log(limit: RayGitPreferences.historyPageSize, skip: skip, search: historySearch, path: historyPath, ref: historyRef, author: historyAuthor)
            guard historyVersion == version else { return }
            commits = reset ? rows : commits + rows.filter { row in !commits.contains(where: { $0.hash == row.hash }) }; historyLoadedCount = skip + rows.count; hasMore = rows.count == RayGitPreferences.historyPageSize
            if let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit }) {
                if let selected = try? await repository.log(limit: 1, ref: selectedCommit).first, historyVersion == version { commits.append(selected) }
                else if !isRestoringViewState { self.selectedCommit = nil; commitFiles = []; selectedCommitPath = nil }
            }
        } catch { if historyVersion == version { report(error) } }
        if historyVersion == version { loadingHistory = false }
    }
    func showHistory(path: String?, ref: String?) {
        historyPath = path; historyRef = ref; historySearch = ""; selectedCommit = nil
        commitFiles = []; selectedCommitPath = nil; mode = "history"
        Task { await loadHistory(reset: true) }
    }
    func scheduleSearch() {
        if !isRestoringViewState { selectedCommit = nil; selectedCommitPath = nil; commitFiles = [] }
        historyVersion = UUID(); searchTask?.cancel()
        searchTask = Task { try? await Task.sleep(nanoseconds: 250_000_000); guard !Task.isCancelled else { return }; await loadHistory(reset: true) }
    }
    func loadCommitFiles() async {
        let version = UUID(); detailVersion = version; commitFiles = []; selectedCommitPath = nil
        guard let repository, let selectedCommit else { await loadDiff(); return }
        do {
            let result = try await repository.commitFiles(hash: selectedCommit)
            guard detailVersion == version else { return }
            commitFiles = result; selectedCommitPath = result.first?.path
            await loadDiff()
        } catch { if detailVersion == version { report(error) } }
    }
    func loadDiff() async {
        let version = UUID(); diffVersion = version; diffText = ""; conflictPreview = nil
        guard let repository else { loadingDiff = false; return }
        let target: DiffTarget
        if mode == "history" {
            guard let selectedCommit, let path = selectedCommitPath else { setDiffTitle("Select a commit and file to view changes"); loadingDiff = false; return }
            target = .commit(hash: selectedCommit, path: path); setDiffTitle("%@  /  %@", arguments: [String(selectedCommit.prefix(8)), path])
        } else {
            guard let file = selectedFile else { setDiffTitle("Select a file to view changes"); loadingDiff = false; return }
            target = stagedDiff ? .staged(path: file.path) : .worktree(path: file.path, untracked: file.isUntracked)
            setDiffTitle(stagedDiff ? "%@  ·  HEAD → Index" : "%@  ·  Index → Working Tree", arguments: [file.path])
        }
        loadingDiff = true
        do {
            if mode == "workspace", let file = selectedFile, file.isConflict {
                let snapshot = try await repository.fileComparison(path: file.path)
                guard diffVersion == version else { return }
                conflictPreview = snapshot
                setDiffTitle("%@  ·  Conflict", arguments: [file.path])
                loadingDiff = false
                return
            }
            let text = try await repository.diff(target: target, ignoreWhitespace: ignoreWhitespace)
            guard diffVersion == version else { return }; diffText = text
        } catch { if diffVersion == version { report(error) } }
        if diffVersion == version { loadingDiff = false }
    }
    func operation(_ name: String, body: @escaping (GitRepository) async throws -> Void) {
        guard let repository, !isBusy else { return }
        isBusy = true; errorMessage = nil; setStatus("%@…", arguments: [name])
        Task {
            do { try await body(repository); activityRecords.insert((Date(), name, nil), at: 0); setStatus("%@ completed", arguments: [name]) }
            catch { report(error) }
            isBusy = false; await refresh()
        }
    }
    func stageSelection() {
        let paths = files.filter { selectedPaths.contains($0.path) && !$0.isConflict }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("暂存") { try await $0.stage(paths: paths) }
    }
    func unstageSelection() {
        let paths = files.filter { selectedPaths.contains($0.path) && !$0.isConflict }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }; operation("取消暂存") { try await $0.unstage(paths: paths) }
    }
    func commit() {
        let message = commitMessage; let amend = amend
        operation(amend ? "修订提交" : "提交") { repo in
            try await repo.commit(message: message, amend: amend)
            await MainActor.run { self.commitMessage = ""; self.amend = false }
        }
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        self.errorMessage = error.localizedDescription
        setStatus("Operation failed"); activityRecords.insert((nil, nil, error.localizedDescription), at: 0)
    }
}

@MainActor
final class RayGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: RepositoryStore?
    func applicationWillTerminate(_ notification: Notification) { store?.flushSession() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ComparePresenter.hasUnsavedChanges else { store?.flushSession(); return .terminateNow }
        Task { let approved = await ComparePresenter.prepareToTerminate(); if approved { self.store?.flushSession() }; sender.reply(toApplicationShouldTerminate: approved) }
        return .terminateLater
    }
}
