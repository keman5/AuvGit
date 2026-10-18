import SwiftUI
import AppKit
import Combine
import GitCore
import AuvGitLocalization

func interactionText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Interactions", arguments: arguments)
}
func compareText(_ key: String, _ arguments: CVarArg...) -> String {
    let text = L10n.text(key, table: "Compare", arguments: arguments)
    return text == key ? L10n.text(key, table: "CompareExtras", arguments: arguments) : text
}
extension Notification.Name { static let auvGitWorktreeChanged = Notification.Name("AuvGitWorktreeChanged") }

@MainActor
enum ComparePresenter {
    private static var controllers: [UUID: CompareController] = [:]
    static func show(title: String, repository: GitRepository, target: DiffTarget? = nil, stash: String? = nil, searchOptions: ComparisonSearchOptions? = nil, replacement: String = "", initialLine: Int? = nil, initialPaneID: String = "worktree") {
        let id = UUID()
        let controller = CompareController(title: title, repository: repository, target: target, stash: stash, searchOptions: searchOptions, replacement: replacement, initialLine: initialLine, initialPaneID: initialPaneID) { controllers.removeValue(forKey: id) }
        controllers[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    static var hasUnsavedChanges: Bool { controllers.values.contains { $0.session?.isDirty == true || $0.session?.isBusy == true } }
    static func prepareToTerminate() async -> Bool {
        for controller in Array(controllers.values) {
            guard let session = controller.session else { continue }
            if session.isBusy { return false }
            guard session.isDirty else { continue }
            controller.window?.makeKeyAndOrderFront(nil)
            switch controller.askToClose() {
            case .alertFirstButtonReturn: if !(await session.save()) { return false }
            case .alertSecondButtonReturn: break
            default: return false
            }
        }
        return true
    }
}

@MainActor
private final class FileCompareWindow: NSWindow {
    weak var compareSession: FileCompareSession?
    private func handleEditorUndoKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "z",
              modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
              attachedSheet == nil, let session = compareSession, !session.isBusy, !session.usesPatchLayout else { return false }
        // Search and other form fields own their native undo stack. Only the
        // comparison document's history is routed through these window commands.
        if let text = firstResponder as? NSTextView, text.isFieldEditor { return false }
        if firstResponder is NSTextField { return false }
        let commands = session.activeEditingCommands
        if modifiers.contains(.shift) {
            guard commands.canRedo else { return false }
            commands.redo()
        } else {
            guard commands.canUndo else { return false }
            commands.undo()
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditorUndoKey(event) || super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if handleEditorUndoKey(event) { return }
        super.sendEvent(event)
    }
}

@MainActor
private final class CompareController: NSWindowController, NSWindowDelegate {
    private let closed: () -> Void
    let session: FileCompareSession?
    private var observer: AnyCancellable?
    private var discardClose = false
    init(title: String, repository: GitRepository, target: DiffTarget?, stash: String?, searchOptions: ComparisonSearchOptions? = nil, replacement: String = "", initialLine: Int? = nil, initialPaneID: String = "worktree", closed: @escaping () -> Void) {
        self.closed = closed
        let path: String?
        switch target {
        case .worktree(let value, _), .staged(let value), .commit(_, let value): path = value
        default: path = nil
        }
        session = path.map { FileCompareSession(repository: repository, path: $0, target: target) }
        let window = FileCompareWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.compareSession = session
        if let path {
            let fileURL = repository.url.appendingPathComponent(path).standardizedFileURL
            window.title = fileURL.path
            window.representedURL = fileURL
        } else { window.title = title + " — " + interactionText("File Compare") }
        window.minSize = NSSize(width: 1050, height: 600)
        window.isReleasedWhenClosed = false
        if let session { window.contentView = NSHostingView(rootView: FileCompareContent(session: session, onResolved: { [weak window] in window?.performClose(nil) }, searchOptions: searchOptions, replacement: replacement, initialLine: initialLine, initialPaneID: initialPaneID).nativeFocusRoot().background(WindowFrameStyle())) }
        else { window.contentView = NSHostingView(rootView: CompareWindowContent(title: title, repository: repository, target: target, stash: stash).nativeFocusRoot().background(WindowFrameStyle())) }
        WindowFrameAppearance.clip(window)
        super.init(window: window); window.delegate = self; window.center()
        observer = session?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.window?.isDocumentEdited = self?.session?.isDirty == true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func askToClose() -> NSApplication.ModalResponse {
        let message = session.map { $0.closeMessage } ?? ""
        return DialogAppearance.confirmClose(title: compareText("Save changes before closing?"), message: message,
                                      save: compareText("Save"), discard: compareText("Discard Draft"), cancel: compareText("Cancel"))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session else { return true }
        guard !session.isBusy else { return false }
        guard session.isDirty && !discardClose else { return true }
        switch askToClose() {
        case .alertFirstButtonReturn:
            Task { if await session.save() { discardClose = true; sender.performClose(nil) } }; return false
        case .alertSecondButtonReturn: discardClose = true; return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { closed() }
}

@MainActor
final class FileCompareSession: ObservableObject {
    let repository: GitRepository
    let path: String
    let target: DiffTarget?
    let editingCommands = ComparisonEditingCommands()
    let baseEditingCommands = ComparisonEditingCommands()
    var activeEditingCommands: ComparisonEditingCommands { activePaneID == "base" ? baseEditingCommands : editingCommands }
    var usesPatchLayout = false
    // Comparison sources stay fixed until the user explicitly reloads.
    @Published var snapshot: FileComparisonSnapshot?
    @Published private(set) var latestSnapshot: FileComparisonSnapshot?
    @Published var savedWorktree: FileRevisionContent?
    @Published var draft = ""
    @Published private(set) var versionDrafts: [String: String] = [:]
    @Published var activePaneID = "worktree"
    @Published private(set) var historicalWorktree: FileRevisionContent?
    private var draftBaseline = ""
    private var versionBaselines: [String: String] = [:]
    @Published var indexDraft = ""
    @Published var partial: PartialStagingSnapshot?
    @Published var unstagePartial = false
    private var patchGeneration = 0
    @Published var isBusy = false
    @Published var error: String?
    @Published var status = ""
    @Published var patch = ""
    @Published var ignoreWhitespace = false
    @Published var preferredEncoding: ComparisonEncoding?
    @Published var pendingExternalResult: String?
    var displayIndex: FileRevisionContent? { snapshot.map { value in preferredEncoding.map { value.index.reinterpreting(as: $0) } ?? value.index } }
    var isDirty: Bool { !dirtyPaneIDs.isEmpty }
    var canEdit: Bool { savedWorktree?.isEditable == true || (savedWorktree?.exists == false && revisions.values.contains(where: { $0.isEditable })) }
    var isHistorical: Bool { if case .commit = target { return true }; return false }
    private var revisions: [String: FileRevisionContent] {
        guard let snapshot else { return [:] }
        var result = ["head": snapshot.head, "index": snapshot.index, "worktree": snapshot.worktree]
        if let historicalWorktree { result["current"] = historicalWorktree }
        for (id, revision) in [("base", snapshot.base), ("ours", snapshot.ours), ("theirs", snapshot.theirs)] { if let revision { result[id] = revision } }
        return result
    }
    func text(in id: String) -> String { id == "worktree" ? draft : versionDrafts[id] ?? "" }
    func isDirty(_ id: String) -> Bool { id == "worktree" ? draft != draftBaseline : versionDrafts[id] != versionBaselines[id] }
    func canEdit(_ id: String) -> Bool {
        guard canEdit, let revision = revisions[id] else { return false }
        return (preferredEncoding.map { revision.reinterpreting(as: $0) } ?? revision).isEditable || !revision.exists
    }
    func edit(_ id: String, text: String) {
        guard canEdit(id), !isBusy else { return }
        activePaneID = id
        if id == "worktree" { draft = text } else { versionDrafts[id] = text }
    }
    var dirtyPaneIDs: [String] { (["worktree"] + versionDrafts.keys.sorted()).filter { isDirty($0) } }
    var savingPaneID: String { isDirty(activePaneID) ? activePaneID : dirtyPaneIDs.first ?? activePaneID }
    var savingPaneTitle: String {
        switch savingPaneID {
        case "head": return isHistorical ? historyRevisionTitle + "~1" : "HEAD"
        case "index": return compareText("Index")
        case "ours": return compareText("Ours (Stage 2)")
        case "theirs": return compareText("Theirs (Stage 3)")
        case "base": return compareText("Base (Stage 1)")
        case "current": return compareText("Working Tree")
        default: return isHistorical ? historyRevisionTitle : compareText("Working Tree")
        }
    }
    var historyRevisionTitle: String { if case .commit(let hash, _) = target { return String(hash.prefix(8)) }; return "" }
    var closeMessage: String {
        path + "\n\n" + compareText("Save Copy To Worktree Message", savingPaneTitle)
            + (dirtyPaneIDs.count > 1 ? "\n" + compareText("Other Drafts Discarded On Close") : "")
    }
    init(repository: GitRepository, path: String, target: DiffTarget? = nil) { self.repository = repository; self.path = path; self.target = target }
    func reload() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let current = try await repository.fileComparison(path: path)
            let snapshot: FileComparisonSnapshot
            if isHistorical, let target { snapshot = try await repository.comparisonPreview(target: target) } else { snapshot = current }
            self.snapshot = snapshot
            latestSnapshot = current
            let working = preferredEncoding.map { current.worktree.reinterpreting(as: $0) } ?? current.worktree
            let indexed = preferredEncoding.map { snapshot.index.reinterpreting(as: $0) } ?? snapshot.index
            savedWorktree = working
            historicalWorktree = isHistorical ? working : nil
            draft = (preferredEncoding.map { snapshot.worktree.reinterpreting(as: $0) } ?? snapshot.worktree).text ?? ""
            draftBaseline = draft; indexDraft = indexed.text ?? ""
            versionDrafts = revisions.filter { $0.key != "worktree" }.mapValues { revision in
                (preferredEncoding.map { revision.reinterpreting(as: $0) } ?? revision).text ?? ""
            }
            versionBaselines = versionDrafts; activePaneID = "worktree"
            await reloadPatch(); status = compareText("Loaded from disk")
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func reloadPatch() async {
        patchGeneration += 1
        let generation = patchGeneration, unstage = unstagePartial
        let comparison = latestSnapshot, ignore = ignoreWhitespace, repository = repository, path = path
        let untracked = comparison?.index.exists == false && comparison?.isConflict == false
        do {
            async let partial = repository.partialStaging(path: path, unstage: unstage, snapshot: comparison)
            async let patch = repository.diff(target: .worktree(path: path, untracked: untracked), ignoreWhitespace: ignore)
            let values = try await (partial, patch)
            guard generation == patchGeneration else { return }
            let displayed = try await comparison?.worktreeDisplayPatch(fallingBackFrom: values.1, ignoreWhitespace: ignore) ?? values.1
            guard generation == patchGeneration else { return }
            self.partial = values.0; self.patch = displayed
        } catch { if generation == patchGeneration { self.error = compareText(OperationFailure.message(error, repository: repository.url)) } }
    }
    private func sameRevision(_ a: FileRevisionContent?, _ b: FileRevisionContent?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.exists == b.exists && a.data == b.data && a.gitMode == b.gitMode && a.objectID == b.objectID
    }
    private func sameIndexAndSources(_ a: FileComparisonSnapshot, _ b: FileComparisonSnapshot) -> Bool {
        sameRevision(a.head, b.head) && sameRevision(a.index, b.index) && sameRevision(a.base, b.base)
            && sameRevision(a.ours, b.ours) && sameRevision(a.theirs, b.theirs)
    }
    /// Updates operation expectations, never the immutable comparison sources.
    /// Textual disk replacements flow through the existing editor as undoable edits.
    func refreshExpectations(replacingDraft: Bool = false, preservingIndexExpectation: Bool = false) async throws {
        let current = try await repository.fileComparison(path: path)
        guard replacingDraft || sameRevision(current.worktree, savedWorktree),
              !preservingIndexExpectation || latestSnapshot.map({ sameIndexAndSources(current, $0) }) ?? true else {
            throw GitError("The index or working tree changed. Reload before partial staging.")
        }
        latestSnapshot = current
        let working = preferredEncoding.map { current.worktree.reinterpreting(as: $0) } ?? current.worktree
        savedWorktree = working
        if replacingDraft {
            if isHistorical { versionDrafts["current"] = working.text ?? ""; versionBaselines["current"] = working.text ?? "" }
            else { draft = working.text ?? ""; draftBaseline = draft }
        }
        await reloadPatch()
    }
    func reinterpret(as encoding: ComparisonEncoding) {
        guard !isBusy, !isDirty, let savedWorktree else { return }
        preferredEncoding = encoding
        let working = savedWorktree.reinterpreting(as: encoding)
        self.savedWorktree = working
        draft = (isHistorical ? snapshot?.worktree.reinterpreting(as: encoding) : working)?.text ?? ""
        draftBaseline = draft
        versionDrafts = revisions.filter { $0.key != "worktree" }.mapValues { $0.reinterpreting(as: encoding).text ?? "" }
        versionBaselines = versionDrafts
    }
    @discardableResult
    func save() async -> Bool {
        guard !isBusy, let expected = savedWorktree else { return false }
        if !isDirty { return true }
        guard canEdit else {
            error = expected.unavailableReason.map { compareText($0) } ?? compareText("File does not exist in this version")
            return false
        }
        isBusy = true; error = nil
        defer { isBusy = false }
        let paneID = savingPaneID, value = text(in: savingPaneID), hadWorktreeDraft = isDirty("worktree"), hadCurrentDraft = isDirty("current")
        do {
            let before = try await repository.fileComparison(path: path)
            guard sameRevision(before.worktree, expected), latestSnapshot.map({ sameIndexAndSources(before, $0) }) ?? true else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            let formatData = expected.data ?? revisions[paneID]?.data ?? Data()
            let format = ComparisonTextDecoder.format(of: formatData, encoding: preferredEncoding)
            let saved = try await repository.saveWorktree(path: path, text: value, expected: expected,
                format: format, newFileMode: revisions[paneID]?.gitMode)
            // Saving changes the clean baseline; it is not a new editor document.
            savedWorktree = saved
            let current = try await repository.fileComparison(path: path)
            guard sameRevision(current.worktree, saved), latestSnapshot.map({ sameIndexAndSources(current, $0) }) ?? true else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            latestSnapshot = current
            if paneID == "worktree" { draftBaseline = value }
            else {
                versionBaselines[paneID] = value
                if !isHistorical, !hadWorktreeDraft { draft = value; draftBaseline = value }
            }
            if isHistorical, paneID != "current", !hadCurrentDraft { versionDrafts["current"] = value; versionBaselines["current"] = value }
            await reloadPatch(); status = compareText("Saved editor drafts")
            NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url)
            return true
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)); return false }
    }
    func unstageFile() async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let current = try await repository.fileComparison(path: path)
            guard sameRevision(current.index, partial.file.index), sameRevision(current.worktree, savedWorktree) else {
                throw GitError("The index changed. Reload before saving to the index.")
            }
            try await repository.unstage(paths: [path])
            try await refreshExpectations()
            NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url)
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func applySelection(_ lines: Set<Int>) async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await repository.applyPartialStaging(partial, selectedLines: lines)
            try await refreshExpectations()
            NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url)
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func autoMerge() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard snapshot?.base?.text != nil, snapshot?.ours?.text != nil, snapshot?.theirs?.text != nil else { return }
        do { draft = try await MergePreview.create(base: text(in: "base"), ours: text(in: "ours"), theirs: text(in: "theirs")).text; activePaneID = "worktree" } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    @discardableResult
    func stage(resolve: Bool) async -> Bool {
        guard !isBusy else { return false }
        if isDirty { guard await save() else { return false } }
        guard let expected = savedWorktree, let latestSnapshot else { return false }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let current = try await repository.fileComparison(path: path)
            guard sameRevision(current.worktree, expected), sameIndexAndSources(current, latestSnapshot) else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            let resolving = resolve || latestSnapshot.isConflict
            if resolving { try await repository.markResolved(path: path, expected: expected, encoding: preferredEncoding) }
            else { try await repository.stage(paths: [path]) }
            try await refreshExpectations()
            NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repository.url)
            status = compareText(resolving ? "Marked resolved and staged" : "Staged working tree file")
            return true
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)); return false }
    }
}

private struct FileCompareContent: View {
    @ObservedObject var session: FileCompareSession
    var onResolved: () -> Void = {}
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @State private var layout = "automatic"
    @State private var baseline = "index"
    @State private var previousEditorLayout = "automatic"
    @AppStorage("editor.wrapLines") private var wrapLines = false
    @AppStorage("editor.showLineNumbers") private var showNumbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronize = true
    @State private var searchOptions = ComparisonSearchOptions()
    @State private var replacement = ""
    @State private var showSearch = false
    @State private var replacementError: String?
    @State private var compact = false
    @State private var pendingInitialLine: Int?
    private let initialPaneID: String
    @State private var navigation = 0
    @State private var baseNavigation = 0
    @State private var changeNavigation = 0
    @State private var confirmReload = false
    @State private var cursor = ComparisonCursorStatus(line: 1, column: 1, selectedCharacters: 0)
    @State private var showBase = false
    @StateObject private var resolver = ComparisonResolverState()
    @ObservedObject private var primaryEditingCommands: ComparisonEditingCommands
    @ObservedObject private var baseEditingCommands: ComparisonEditingCommands
    private var editingCommands: ComparisonEditingCommands { session.activePaneID == "base" ? baseEditingCommands : primaryEditingCommands }
    @State private var conflictLayout = "all"
    @State private var confirmMerge = false
    @State private var showConflictHelp = false
    @State private var pendingVersion: String?
    @State private var confirmVersion = false
    init(session: FileCompareSession, onResolved: @escaping () -> Void = {}, searchOptions: ComparisonSearchOptions? = nil, replacement: String = "", initialLine: Int? = nil, initialPaneID: String = "worktree") {
        self.session = session
        self.onResolved = onResolved
        self.initialPaneID = initialPaneID
        _pendingInitialLine = State(initialValue: initialLine)
        _searchOptions = State(initialValue: searchOptions ?? ComparisonSearchOptions())
        _replacement = State(initialValue: replacement)
        _showSearch = State(initialValue: searchOptions != nil)
        self.primaryEditingCommands = session.editingCommands
        self.baseEditingCommands = session.baseEditingCommands
        let preference = UserDefaults.standard.string(forKey: "editor.comparisonLayoutMode") ?? "automatic"
        let initialLayout = session.isHistorical && preference == "patch" ? "automatic" : preference
        _layout = State(initialValue: ["automatic", "two", "three", "patch"].contains(initialLayout) ? initialLayout : "automatic")
        session.usesPatchLayout = initialLayout == "patch"
    }
    private var editorLayout: String { layout == "patch" ? previousEditorLayout : layout }
    private var resolvedLayout: String {
        let effective = editorLayout
        return effective == "automatic" ? (session.snapshot?.presentation.layout == .three ? "three" : "two") : effective
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ZStack {
                Group {
                    if let snapshot = session.snapshot, !session.isHistorical, !isStaticDocument,
                       [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).contains(where: \.exceedsPreviewLimit),
                       [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).allSatisfy({ !$0.exists || (!$0.isBinary && (!$0.exceedsPreviewLimit || $0.canStreamText)) }) {
                StreamingComparisonView(repository: session.repository, path: session.path, initialSearchOptions: searchOptions, initialReplacement: replacement, compact: compact, searchRequested: showSearch, onSearchClosed: { showSearch = false }, changeNavigation: changeNavigation, searchNavigation: navigation, onCursorChange: { cursor = $0 })
            } else if let snapshot = session.snapshot, snapshot.requiresStaticPreview {
                StaticComparisonView(snapshot: snapshot)
            } else if let snapshot = session.snapshot, [snapshot.head.data?.count ?? 0, snapshot.index.data?.count ?? 0, snapshot.worktree.data?.count ?? 0, snapshot.base?.data?.count ?? 0, snapshot.ours?.data?.count ?? 0, snapshot.theirs?.data?.count ?? 0].max()! > 2 * 1024 * 1024 {
                PagedComparisonView(snapshot: snapshot, layout: layout, baseline: baseline, showBase: showBase, initialSearchOptions: searchOptions, initialReplacement: replacement, compact: compact, searchRequested: showSearch, onSearchClosed: { showSearch = false }, changeNavigation: changeNavigation, searchNavigation: navigation, onCursorChange: { cursor = $0 })
            } else if session.snapshot != nil {
                ComparisonEditor(columns: columns, wrapLines: wrapLines, showLineNumbers: showNumbers, synchronizeScroll: synchronize, search: searchOptions.query, navigation: navigation, changeNavigation: changeNavigation, onEdit: session.edit, languagePath: session.path, resolver: session.snapshot?.isConflict == true ? resolver : nil, onCursorChange: { cursor = $0 }, onActivePaneChange: { session.activePaneID = $0 }, editingCommands: primaryEditingCommands, scrollsToFirstChangeOnOpen: true, searchOptions: searchOptions)
            } else { Spacer(); if session.isBusy { ProgressView() } else { Text(compareText("No file loaded")).foregroundStyle(.secondary) }; Spacer() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(layout == "patch" || showsCompact ? 0 : 1)
                    .allowsHitTesting(layout != "patch" && !showsCompact).accessibilityHidden(layout == "patch" || showsCompact)
                if showsCompact {
                    CompactComparisonView(columns: columns, conflict: session.snapshot?.isConflict == true, wraps: wrapLines, numbers: showNumbers, onReturnToEditor: { compact = false }, onRevealLine: { id, line in
                        compact = false
                        DispatchQueue.main.async { editingCommands.revealLine(paneID: id, number: line) }
                    })
                }
                if layout == "patch" {
                    VStack(spacing: 0) {
                        PartialStagingPane(session: session)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .layoutPriority(1)
            if session.snapshot?.isConflict == true, let base = session.snapshot?.base {
                Divider()
                CompareBasePanel(column: column("base", "Base (Stage 1)", base), wraps: wrapLines, numbers: showNumbers, expanded: $showBase, onEdit: session.edit, onActivePaneChange: { session.activePaneID = $0 }, editingCommands: baseEditingCommands, searchOptions: searchOptions, navigation: baseNavigation)
            }
            Divider()
            HStack {
                if session.isBusy { ProgressView().controlSize(.mini) }
                Text(session.isDirty ? compareText("Save Copy To Worktree Message", session.savingPaneTitle) : session.savedWorktree?.unavailableReason.map { compareText($0) } ?? session.status)
                Spacer()
                Text(session.preferredEncoding?.rawValue ?? session.savedWorktree?.data.map { ComparisonTextDecoder.format(of: $0).encoding.rawValue } ?? "").foregroundStyle(.secondary)
                if let data = session.savedWorktree?.data { Text(ComparisonTextDecoder.format(of: data).lineEnding.rawValue.uppercased()).foregroundStyle(.secondary) }
                if session.snapshot != nil { Text(designCompareText("%d versions", columns.count)).foregroundStyle(.secondary) }
                Text(designCompareText("Line %d, column %d", cursor.line, cursor.column)).foregroundStyle(.secondary)
                Text(designCompareText("%d selected", cursor.selectedCharacters)).foregroundStyle(.secondary)
                if session.snapshot?.isConflict == true {
                    Button(compareText("Cancel")) { NSApp.keyWindow?.performClose(nil) }
                    Button(compareText("Save")) { Task { _ = await session.save() } }
                        .disabled(session.isBusy || !session.isDirty || !session.canEdit)
                    Button(compareText("Save & Mark Resolved")) { Task { if await session.stage(resolve: true) { onResolved() } } }
                        .buttonStyle(.borderedProminent).disabled(session.isBusy || !session.canEdit || ConflictDraft.hasConflictMarkers(in: session.draft))
                }
            }.font(.caption).padding(.horizontal, 14).frame(height: session.snapshot?.isConflict == true ? 52 : 34).auvGitChrome()
        }.background(ComparisonKeyboardRegion(standalone: true, action: performShortcut))
            .buttonBorderShape(.roundedRectangle(radius: 6)).environment(\.locale, L10n.locale)
            .onChange(of: supportsNativeComparison) { _, supported in
                if supported, let line = pendingInitialLine {
                    pendingInitialLine = nil
                    DispatchQueue.main.async { editingCommands.revealLine(paneID: initialPaneID, number: line) }
                }
            }
            .onChange(of: compact) { _, value in if value { NSApp.keyWindow?.makeFirstResponder(nil) } }
            .onChange(of: searchOptions) { _, _ in replacementError = nil }
            .onChange(of: layout) { old, new in
                session.usesPatchLayout = new == "patch"
                if new == "patch" { previousEditorLayout = old == "patch" ? previousEditorLayout : old }
                else { previousEditorLayout = new }
            }
            .task { await session.reload() }
            .auvGitAlert(compareText("Replace working tree draft with auto merge?"), isPresented: $confirmMerge) {
                AuvGitAlertButton(compareText("Auto Merge"), role: .destructive) { Task { await session.autoMerge() } }
                AuvGitAlertButton(compareText("Cancel"), role: .cancel) {}
            }
            .auvGitAlert(compareText("Replace unsaved draft with selected version?"), isPresented: $confirmVersion) {
                AuvGitAlertButton(compareText("Replace Draft"), role: .destructive) { if let pendingVersion { session.edit("worktree", text: pendingVersion) }; pendingVersion = nil }
                AuvGitAlertButton(compareText("Cancel"), role: .cancel) { pendingVersion = nil }
            } message: { Text(compareText("This replaces the entire editor draft. Disk and index are unchanged until you save or mark resolved.")) }
            .auvGitAlert(compareText("Discard unsaved changes and reload?"), isPresented: $confirmReload) {
                AuvGitAlertButton(compareText("Reload"), role: .destructive) { Task { await session.reload() } }
                AuvGitAlertButton(compareText("Cancel"), role: .cancel) {}
            }
    }
    private func performShortcut(_ command: ShortcutCommand) -> Bool {
        guard !session.isBusy else { return false }
        switch command {
        case .compareReload:
            if session.isDirty { confirmReload = true } else { Task { await session.reload() } }
        case .compareSave:
            guard session.isDirty else { return false }; Task { await session.save() }
        case .compareStage:
            guard session.canEdit else { return false }
            if session.snapshot?.isConflict == true, ConflictDraft.hasConflictMarkers(in: session.draft) { return false }
            Task {
                let resolving = session.snapshot?.isConflict == true
                if await session.stage(resolve: resolving), resolving { onResolved() }
            }
        case .compareReplace:
            guard session.canEdit, supportsNativeComparison, layout != "patch" else { return false }; showSearch = true
        case .compareTakeLeft, .compareTakeRight:
            guard session.canEdit, supportsNativeComparison, layout != "patch", !compact else { return false }
            return editingCommands.takeBlock(fromLeft: command == .compareTakeLeft)
        case .compareNextConflict, .comparePreviousConflict:
            let blocks = ConflictDraft.blocks(in: session.draft)
            guard session.canEdit, supportsNativeComparison, layout != "patch", !compact, !blocks.isEmpty else { return false }
            let current = min(max(0, resolver.selectedBlock), blocks.count - 1)
            resolver.select?((current + (command == .compareNextConflict ? 1 : blocks.count - 1)) % blocks.count)
        case .compareFind:
            guard supportsTextComparison else { return false }; showSearch = true
        case .compareFindNext, .compareFindPrevious:
            guard supportsTextComparison, layout != "patch" else { return false }
            compact = false
            if session.activePaneID == "base" { baseNavigation += command == .compareFindNext ? 1 : -1 }
            else { navigation += command == .compareFindNext ? 1 : -1 }
        case .comparePreviousChange, .compareNextChange:
            guard supportsTextComparison, layout != "patch", !compact else { return false }
            changeNavigation += command == .compareNextChange ? 1 : -1
        case .compareCompact:
            guard supportsTextComparison, layout != "patch" else { return false }; compact.toggle()
        case .compareWrap: wrapLines.toggle()
        case .compareLines: showNumbers.toggle()
        case .compareSync: synchronize.toggle()
        default: return false
        }
        return true
    }
    private var isStaticDocument: Bool {
        ["pdf", "svg"].contains((session.path as NSString).pathExtension.lowercased())
    }
    private var supportsTextComparison: Bool {
        guard let snapshot = session.snapshot, !isStaticDocument else { return false }
        return [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap { $0 }.allSatisfy { !$0.exists || (!$0.isBinary && (!$0.exceedsPreviewLimit || $0.canStreamText)) }
    }
    private var supportsNativeComparison: Bool {
        guard let snapshot = session.snapshot, !snapshot.requiresStaticPreview else { return false }
        let revisions = [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap { $0 }
        return revisions.allSatisfy { ($0.data?.count ?? 0) <= 2 * 1024 * 1024 }
    }
    private var showsCompact: Bool { compact && layout != "patch" && supportsNativeComparison }
    private var searchError: String? {
        if let replacementError { return replacementError }
        if case .failure(let error) = ComparisonSearch.matches(in: "", options: searchOptions) { return comparisonSearchText("Invalid regular expression") + ": " + error.localizedDescription }
        return nil
    }
    private var controls: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                primaryToolbar
                ScrollView(.horizontal) { primaryToolbar.fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden)
            }.frame(height: 32)
            if session.snapshot?.isConflict == true {
                Divider()
                ViewThatFits(in: .horizontal) {
                    conflictToolbar
                    ScrollView(.horizontal) { conflictToolbar.fixedSize(horizontal: true, vertical: false) }
                        .scrollIndicators(.hidden)
                }.frame(height: 32)
            }
        }.controlSize(.small).auvGitChrome()
    }
    private var primaryToolbar: some View {
        HStack(spacing: 6) {
            comparisonToolbar
            if let error = session.error { FloatingNotice(message: error, guidance: noticeText("Review the file and reload the comparison before trying again. Save any draft you want to keep before reloading. The message remains available here until the next operation.")) }
            HStack(spacing: 6) {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.repository.url.appendingPathComponent(session.path).path, forType: .string) } label: { ComparisonToolbarIcon(name: "doc.on.doc") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(designCompareText("Copy path")).accessibilityLabel(designCompareText("Copy path"))
                if session.isDirty { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange).help(compareText("Unsaved changes")).accessibilityLabel(compareText("Unsaved changes")) }
                Button { if session.isDirty { confirmReload = true } else { Task { await session.reload() } } } label: { ComparisonToolbarIcon(name: "arrow.clockwise") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .disabled(session.isBusy).help(compareText("Reload")).accessibilityLabel(compareText("Reload"))
                Button { editingCommands.undo() } label: { ComparisonToolbarIcon(name: "arrow.uturn.backward") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(designCompareText("Undo")).accessibilityLabel(designCompareText("Undo"))
                    .disabled(session.isBusy || layout == "patch" || !editingCommands.canUndo)
                Button { editingCommands.redo() } label: { ComparisonToolbarIcon(name: "arrow.uturn.forward") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(designCompareText("Redo")).accessibilityLabel(designCompareText("Redo"))
                    .disabled(session.isBusy || layout == "patch" || !editingCommands.canRedo)
                Menu {
                    if let snapshot = session.snapshot {
                        if session.isHistorical { versionButton(session.historyRevisionTitle + "~1", snapshot.head); versionButton(session.historyRevisionTitle, snapshot.worktree) }
                        else if snapshot.isConflict { versionButton("Ours", snapshot.ours); versionButton("Theirs", snapshot.theirs); versionButton("Base", snapshot.base) }
                        else { versionButton("HEAD", snapshot.head); versionButton("Index", snapshot.index) }
                    }
                } label: { ComparisonToolbarIcon(name: "doc.badge.arrow.up") }.buttonStyle(ComparisonToolbarButtonStyle()).menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().frame(width: 22, height: 24)
                    .help(compareText("Use Version")).accessibilityLabel(compareText("Use Version"))
                    .disabled(!session.canEdit || session.isBusy || layout == "patch")
                if let snapshot = session.snapshot {
                    ExternalComparisonButton(snapshot: snapshot, iconOnly: true, resultText: session.draft, resultEncoding: session.preferredEncoding, onResult: { session.pendingExternalResult = $0 })
                        .font(.system(size: 11)).fixedSize()
                }
                ComparisonExtrasMenu(session: session).frame(height: 24)
                Button { Task { await session.save() } } label: { ComparisonToolbarIcon(name: "square.and.arrow.down") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .configuredShortcut(.compareSave, using: shortcuts).help(compareText("Save")).accessibilityLabel(compareText("Save"))
                    .fixedSize().layoutPriority(1).disabled(!session.isDirty || session.isBusy)
                if session.snapshot?.isConflict != true {
                    Button { Task { await session.stage(resolve: false) } } label: { ComparisonToolbarIcon(name: "tray.and.arrow.down") }.buttonStyle(ComparisonToolbarButtonStyle())
                        .help(compareText("Save & Stage")).accessibilityLabel(compareText("Save & Stage"))
                        .foregroundStyle(Color.accentColor).fixedSize().layoutPriority(1).disabled(session.isBusy || !session.canEdit)
                }
            }.fixedSize()
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22)).font(.system(size: 11)).padding(.horizontal, 12).frame(height: 32)
    }
    private var comparisonToolbar: some View {
        HStack(spacing: 6) {
            Picker(compareText("Layout"), selection: $layout) {
                Text(compareText("Automatic")).tag("automatic")
                Text(compareText("Two Columns")).tag("two")
                Text(compareText("Three Columns")).tag("three")
                if !session.isHistorical { Text(compareText("Patch")).tag("patch") }
            }.pickerStyle(.menu).labelsHidden().frame(width: 115, height: 24).accessibilityLabel(compareText("Layout"))
            if resolvedLayout == "two" && !session.isHistorical && session.snapshot?.isConflict != true {
                Picker(compareText("Baseline"), selection: $baseline) { Text("HEAD").tag("head"); Text(compareText("Index")).tag("index") }
                    .labelsHidden().frame(width: 65, height: 24).accessibilityLabel(compareText("Baseline"))
            }
            Button { showSearch.toggle() } label: { ComparisonToolbarIcon(name: "magnifyingglass") }.buttonStyle(ComparisonToolbarButtonStyle())
                .help(comparisonSearchText("Search and replace")).accessibilityLabel(comparisonSearchText("Search and replace"))
                .popover(isPresented: Binding(get: { showSearch && supportsNativeComparison }, set: { showSearch = $0 }), arrowEdge: .bottom) {
                    ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: editingCommands.searchTotal, matchIndex: editingCommands.searchCurrent,
                        canReplace: session.canEdit(session.activePaneID) && !session.isBusy && layout != "patch", onNavigate: { forward in
                            compact = false
                            if session.activePaneID == "base" { baseNavigation += forward ? 1 : -1 }
                            else { navigation += forward ? 1 : -1 }
                        }, onReplace: { all in
                            compact = false
                            replacementError = editingCommands.replaceSearch(options: searchOptions, replacement: replacement, all: all)
                        }, error: searchError, onClose: {
                            showSearch = false
                            DispatchQueue.main.async { editingCommands.focusEditor() }
                        })
                }.disabled(session.snapshot == nil || !supportsTextComparison)
            Button { compact.toggle() } label: { ComparisonToolbarIcon(name: "line.3.horizontal.decrease") }.buttonStyle(ComparisonToolbarButtonStyle())
                .help(comparisonSearchText("Compact differences")).accessibilityLabel(comparisonSearchText("Compact differences"))
                .foregroundStyle(compact ? Color.accentColor : Color.primary)
                .disabled(layout == "patch" || !supportsTextComparison)
            HStack(spacing: 2) {
                Button { changeNavigation -= 1 } label: { ComparisonToolbarIcon(name: "arrow.up") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(compareText("Previous change")).accessibilityLabel(compareText("Previous change")).disabled(layout == "patch" || compact)
                Button { changeNavigation += 1 } label: { ComparisonToolbarIcon(name: "arrow.down") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(compareText("Next change")).accessibilityLabel(compareText("Next change")).disabled(layout == "patch" || compact)
            }
            CompareDisplayButton(title: designCompareText("Sync"), symbol: "link", enabled: $synchronize)
            CompareDisplayButton(title: designCompareText("Wrap"), symbol: "text.alignleft", enabled: $wrapLines)
            CompareDisplayButton(title: designCompareText("Lines"), symbol: "list.number", enabled: $showNumbers)
            Spacer(minLength: 0)
            if session.snapshot?.isConflict != true && !session.isHistorical {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    .help(designCompareText("HEAD ← Index ← Working Tree"))
                    .accessibilityLabel(designCompareText("HEAD ← Index ← Working Tree"))
            }
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22)).frame(height: 32)
    }
    private var conflictToolbar: some View {
        HStack(spacing: 8) {
            ConflictResolverToolbar(state: resolver, blocks: ConflictDraft.blocks(in: session.draft), enabled: session.canEdit && !session.isBusy && layout != "patch", malformed: ConflictDraft.blocks(in: session.draft).isEmpty && ConflictDraft.hasConflictMarkers(in: session.draft))
            Picker(resolverText("Resolver layout"), selection: $conflictLayout) {
                Text(resolverText("Ours + Result")).tag("left")
                Text(resolverText("All three")).tag("all")
                Text(resolverText("Result + Theirs")).tag("right")
            }.pickerStyle(.menu).labelsHidden().frame(width: 145, height: 24).accessibilityLabel(resolverText("Resolver layout"))
            Button(compareText("Auto Merge")) { if session.isDirty { confirmMerge = true } else { Task { await session.autoMerge() } } }
                .fixedSize().disabled(session.isBusy)
            Button { showConflictHelp.toggle() } label: { ComparisonToolbarIcon(name: "info.circle") }.buttonStyle(ComparisonToolbarButtonStyle())
                .foregroundStyle(.secondary)
                .help(compareText("Conflict: edit the result, save, then mark resolved")).accessibilityLabel(compareText("Conflict: edit the result, save, then mark resolved"))
                .auvGitPopover(isPresented: $showConflictHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(compareText("Conflict: edit the result, save, then mark resolved")).fontWeight(.semibold)
                        Text(resolverText("Ours = Stage 2; Theirs = Stage 3. During rebase, Ours is the upstream side."))
                        Text(compareText("Choices change the draft only. Save, then mark resolved to stage it."))
                    }.font(.callout).padding(16).frame(width: 340)
                }
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22)).font(.system(size: 11)).padding(.horizontal, 12).frame(height: 32)
    }
    private func versionButton(_ name: String, _ version: FileRevisionContent?) -> some View {
        Button(compareText(name)) {
            let revision = session.preferredEncoding.flatMap { version?.reinterpreting(as: $0) } ?? version
            if let text = revision?.text {
                if session.isDirty("worktree") { pendingVersion = text; confirmVersion = true } else { session.edit("worktree", text: text) }
            }
        }.disabled((session.preferredEncoding.flatMap { version?.reinterpreting(as: $0) } ?? version)?.text == nil)
    }
    private func column(_ id: String, _ name: String, _ revision: FileRevisionContent?, editable: Bool = true) -> ComparisonEditorColumn {
        let revision = session.preferredEncoding.flatMap { encoding in revision?.reinterpreting(as: encoding) } ?? revision
        let keepsTextSurface = editable && session.canEdit(id)
        let message = revision?.text != nil || keepsTextSurface ? nil : (revision?.unavailableReason.map { compareText($0) } ?? (revision?.exists == true ? nil : compareText("File does not exist in this version")))
        let canEdit = editable && session.canEdit(id)
        return ComparisonEditorColumn(id: id, title: URL(fileURLWithPath: session.path).lastPathComponent + " — " + compareText(name), text: editable ? session.text(in: id) : (revision?.text ?? ""), isEditable: canEdit && !session.isBusy, message: message, detail: session.isDirty(id) ? compareText("Unsaved changes") : canEdit ? compareText("Editable Copy") : revision?.objectID.map { String($0.prefix(8)) } ?? designCompareText("Read-only"), preservesUndo: canEdit)
    }
    private var columns: [ComparisonEditorColumn] {
        guard let snapshot = session.snapshot else { return [] }
        if session.isHistorical {
            let sources = [column("head", session.historyRevisionTitle + "~1", snapshot.head), column("worktree", session.historyRevisionTitle, snapshot.worktree)]
            return resolvedLayout == "three" ? sources + [column("current", "Working Tree", session.historicalWorktree)] : sources
        }
        if snapshot.isConflict {
            let left = column("ours", "Ours (Stage 2)", snapshot.ours)
            let result = column("worktree", session.canEdit ? "Merge Result (Editable)" : "Merge Result (Read-only)", session.savedWorktree, editable: true)
            let right = column("theirs", "Theirs (Stage 3)", snapshot.theirs)
            if conflictLayout == "left" { return [left, result] }
            if conflictLayout == "right" { return [result, right] }
            return [left, result, right]
        }
        let title = session.canEdit ? "Working Tree (Editable)" : "Working Tree (Read-only)"
        let working = column("worktree", title, session.savedWorktree, editable: true)
        if resolvedLayout == "two" {
            let useHead = editorLayout == "automatic" ? snapshot.presentation.leftRevision == .head : baseline == "head"
            return [useHead ? column("head", "HEAD", snapshot.head) : column("index", "Index", snapshot.index), working]
        }
        return [column("head", "HEAD", snapshot.head), column("index", "Index", snapshot.index), working]
    }
}

private struct CompareWindowContent: View {
    let title: String
    let repository: GitRepository
    let target: DiffTarget?
    let stash: String?
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @State private var ignoreWhitespace = false
    @State private var text = ""
    @State private var preview: FileComparisonSnapshot?
    @State private var error: String?
    @State private var isLoading = true
    @State private var version = UUID()
    private var revisionTitles: (String?, String?) {
        switch target {
        case .commit(let hash, let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            let revision = String(hash.prefix(8))
            return (name + " — " + revision + "~1", name + " — " + revision)
        case .staged(let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (name + " — HEAD", name + " — " + compareText("Index"))
        case .worktree(let path, _):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (name + " — " + compareText("Index"), name + " — " + compareText("Working Tree"))
        case nil: return (nil, nil)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let error { FloatingNotice(message: error, guidance: noticeText("Check that the repository and selected revision are still available, then use Refresh to retry. The command below reports the current repository state without changing files or the index."), command: "git status --short") }
                Text(repository.url.lastPathComponent).foregroundStyle(.secondary); Spacer()
                Toggle(interactionText("Ignore Whitespace"), isOn: $ignoreWhitespace).disabled(stash != nil)
                Button(interactionText("Refresh")) { Task { await reload() } }
            }.font(.caption).padding(10)
            DiffPane(text: text, title: title, isLoading: isLoading, preview: preview, leftRevisionTitle: revisionTitles.0, rightRevisionTitle: revisionTitles.1, standaloneShortcuts: true)
        }.background(ComparisonKeyboardRegion(standalone: true, commands: [.compareReload]) { command in
            guard command == .compareReload, !isLoading else { return false }
            Task { await reload() }; return true
        }).buttonBorderShape(.roundedRectangle(radius: 6)).environment(\.locale, L10n.locale).task { await reload() }
            .onChange(of: ignoreWhitespace) { _, _ in Task { await reload() } }.onDisappear { version = UUID() }
    }
    private func reload() async {
        let token = UUID(); version = token; isLoading = true; error = nil; preview = nil
        do {
            let output: String
            if let stash { output = try await repository.stashDiff(ref: stash) }
            else if let target {
                let result = try await repository.displayDiff(target: target, ignoreWhitespace: ignoreWhitespace)
                guard token == version else { return }
                preview = result.preview
                output = result.text
            }
            else { output = "" }
            guard token == version else { return }; text = output
        } catch { if token == version { self.error = OperationFailure.message(error, repository: repository.url) } }
        if token == version { isLoading = false }
    }
}
