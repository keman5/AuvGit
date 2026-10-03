import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

@main
struct RayGitApp: App {
    @NSApplicationDelegateAdaptor(RayGitApplicationDelegate.self) private var appDelegate
    @StateObject private var store = RepositoryStore()
    @AppStorage(L10n.preferenceKey) private var languageCode = AppLanguage.system.rawValue
    var body: some Scene {
        WindowGroup {
            MainWindow(store: store)
                .environment(\.locale, L10n.locale)
                .id(languageCode)
                .frame(minWidth: 1120, minHeight: 760)
                .task { await store.restore() }
                .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in Task { await store.refreshIfChanged() } }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Open Repository…")) { store.chooseRepository() }.keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Refresh Repository")) { Task { await store.refresh() } }.keyboardShortcut("r")
                    .disabled(store.repository == nil || store.isBusy)
                Button(L10n.text("Stage Selected Files")) { store.stageSelection() }.keyboardShortcut("t")
                    .disabled(store.selectedPaths.isEmpty || store.isBusy)
            }
        }
        Settings {
            Form {
                Picker(L10n.text("Language", table: "Language"), selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }
            }
            .padding(24)
            .frame(width: 360)
            .environment(\.locale, L10n.locale)
        }
    }
}

@MainActor
final class RepositoryStore: ObservableObject {
    @Published var repository: GitRepository?
    @Published var repositoryURL: URL?
    @Published var recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    @Published var files: [GitFile] = []
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
    @Published private var diffTitleKey = "Select a file to view changes"
    @Published private var diffTitleArguments: [String] = []
    var diffTitle: String { L10n.text(diffTitleKey, arguments: diffTitleArguments.map { $0 as CVarArg }) }
    @Published var fileFilter = ""
    @Published var historySearch = ""
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
    var selectedFile: GitFile? { files.first { $0.path == selectedPaths.sorted().first } }
    var filteredFiles: [GitFile] { files.filter { fileFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(fileFilter) } }
    var stagedCount: Int { files.filter(\.isStaged).count }

    func restore() async {
        guard !restored else { return }; restored = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--repo"), args.indices.contains(i + 1) {
            await open(URL(fileURLWithPath: args[i + 1]))
        } else if let path = recentPaths.first { await open(URL(fileURLWithPath: path)) }
    }
    func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L10n.text("Open Repository"); panel.message = L10n.text("Choose a Git repository folder")
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }
    func open(_ url: URL) async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; setStatus("Opening repository…")
        do {
            let repo = try await GitRepository.open(url)
            let root = repo.url
            repoVersion = UUID(); diffVersion = UUID(); detailVersion = UUID(); historyVersion = UUID()
            repository = repo; repositoryURL = root
            files = []; branches = []; commits = []; commitFiles = []; stashes = []
            selectedPaths = []; selectedCommit = nil; selectedCommitPath = nil; diffText = ""
            commitMessage = ""; amend = false; historySearch = ""; historyPath = nil; historyRef = nil
            recentPaths.removeAll { $0 == root.path }; recentPaths.insert(root.path, at: 0)
            recentPaths = Array(recentPaths.prefix(12)); UserDefaults.standard.set(recentPaths, forKey: "recentRepositories")
            isBusy = false; await refresh()
        } catch { report(error); isBusy = false }
    }
    private var lastObservedState = ""
    func refreshIfChanged() async {
        guard let repository, !isBusy else { return }
        do {
            let status = try await repository.workflowRead(["status", "--porcelain=v1", "-z"])
            let refs = (try? await repository.workflowRead(["show-ref", "--head"])) ?? ""
            let state = status + refs
            guard state != lastObservedState else { return }; lastObservedState = state; await refresh()
        } catch { /* Empty repositories have no refs; explicit refresh remains available. */ }
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
            files = result.0; branches = result.1; branch = result.2; stashes = result.3
            selectedPaths.formIntersection(Set(files.map(\.path)))
            setStatus("Refreshed · %@ changes · %@ staged", arguments: [String(files.count), String(stagedCount)])
            await loadHistory(reset: true)
            await loadDiff()
        } catch { report(error) }
    }
    func loadHistory(reset: Bool) async {
        guard let repository else { return }
        let version = UUID(); historyVersion = version; loadingHistory = true
        let skip = reset ? 0 : commits.count
        do {
            let rows = try await repository.log(limit: 200, skip: skip, search: historySearch, path: historyPath, ref: historyRef)
            guard historyVersion == version else { return }
            commits = reset ? rows : commits + rows; hasMore = rows.count == 200
            if let selectedCommit, !commits.contains(where: { $0.hash == selectedCommit }) { self.selectedCommit = nil; commitFiles = []; selectedCommitPath = nil }
        } catch { if historyVersion == version { report(error) } }
        if historyVersion == version { loadingHistory = false }
    }
    func showHistory(path: String?, ref: String?) {
        historyPath = path; historyRef = ref; historySearch = ""; selectedCommit = nil
        commitFiles = []; selectedCommitPath = nil; mode = "history"
        Task { await loadHistory(reset: true) }
    }
    func scheduleSearch() {
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
        let version = UUID(); diffVersion = version; diffText = ""
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
        self.errorMessage = error.localizedDescription
        setStatus("Operation failed"); activityRecords.insert((nil, nil, error.localizedDescription), at: 0)
    }
}

@MainActor
final class RayGitApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ComparePresenter.hasUnsavedChanges else { return .terminateNow }
        Task { let approved = await ComparePresenter.prepareToTerminate(); sender.reply(toApplicationShouldTerminate: approved) }
        return .terminateLater
    }
}
