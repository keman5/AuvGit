import SwiftUI
import AppKit
import Combine
import GitCore
import RayGitLocalization

func interactionText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Interactions", arguments: arguments)
}
func compareText(_ key: String, _ arguments: CVarArg...) -> String {
    let text = L10n.text(key, table: "Compare", arguments: arguments)
    return text == key ? L10n.text(key, table: "CompareExtras", arguments: arguments) : text
}
extension Notification.Name { static let rayGitWorktreeChanged = Notification.Name("RayGitWorktreeChanged") }

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
        let commands = session.editingCommands
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
        case .worktree(let value, _), .staged(let value): path = value
        default: path = nil
        }
        session = path.map { FileCompareSession(repository: repository, path: $0) }
        let window = FileCompareWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.compareSession = session
        if let path {
            let fileURL = repository.url.appendingPathComponent(path).standardizedFileURL
            window.title = fileURL.path
            window.representedURL = fileURL
        } else { window.title = title + " — " + interactionText("File Compare") }
        window.minSize = NSSize(width: 1050, height: 600)
        window.isReleasedWhenClosed = false
        if let session { window.contentView = NSHostingView(rootView: FileCompareContent(session: session, searchOptions: searchOptions, replacement: replacement, initialLine: initialLine, initialPaneID: initialPaneID)) }
        else { window.contentView = NSHostingView(rootView: CompareWindowContent(title: title, repository: repository, target: target, stash: stash)) }
        super.init(window: window); window.delegate = self; window.center()
        observer = session?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.window?.isDocumentEdited = self?.session?.isDirty == true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func askToClose() -> NSApplication.ModalResponse {
        let alert = NSAlert(); alert.messageText = compareText("Save changes before closing?")
        alert.informativeText = session?.path ?? ""
        alert.addButton(withTitle: compareText("Save")); alert.addButton(withTitle: compareText("Discard Draft")); alert.addButton(withTitle: compareText("Cancel"))
        let response = alert.runModal()
        // runModal ends the modal session; explicitly remove its window before
        // the compare window closes and releases its hosting controller.
        alert.window.orderOut(nil)
        alert.window.close()
        return response
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session else { return true }
        guard !session.isBusy else { return false }
        guard session.isDirty && !discardClose else { return true }
        switch askToClose() {
        case .alertFirstButtonReturn:
            Task { if await session.save() { sender.performClose(nil) } }; return false
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
    let editingCommands = ComparisonEditingCommands()
    var usesPatchLayout = false
    // Comparison sources stay fixed until the user explicitly reloads.
    @Published var snapshot: FileComparisonSnapshot?
    @Published private(set) var latestSnapshot: FileComparisonSnapshot?
    @Published var savedWorktree: FileRevisionContent?
    @Published var draft = ""
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
    var isDirty: Bool { (savedWorktree?.text != nil || snapshot?.worktree.text != nil) && draft != (savedWorktree?.text ?? "") }
    var canEdit: Bool { savedWorktree?.isEditable == true }
    init(repository: GitRepository, path: String) { self.repository = repository; self.path = path }
    func reload() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let snapshot = try await repository.fileComparison(path: path)
            self.snapshot = snapshot
            latestSnapshot = snapshot
            let working = preferredEncoding.map { snapshot.worktree.reinterpreting(as: $0) } ?? snapshot.worktree
            let indexed = preferredEncoding.map { snapshot.index.reinterpreting(as: $0) } ?? snapshot.index
            savedWorktree = working; draft = working.text ?? ""; indexDraft = indexed.text ?? ""
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
        if replacingDraft { draft = working.text ?? "" }
        await reloadPatch()
    }
    func reinterpret(as encoding: ComparisonEncoding) {
        guard !isBusy, !isDirty, let savedWorktree else { return }
        preferredEncoding = encoding
        let working = savedWorktree.reinterpreting(as: encoding)
        self.savedWorktree = working
        draft = working.text ?? ""
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
        do {
            let before = try await repository.fileComparison(path: path)
            guard sameRevision(before.worktree, expected), latestSnapshot.map({ sameIndexAndSources(before, $0) }) ?? true else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            let saved = try await repository.saveWorktree(path: path, text: draft, expected: expected,
                format: preferredEncoding.map { ComparisonTextFormat(encoding: $0, lineEnding: ComparisonTextDecoder.format(of: expected.data ?? Data(), encoding: preferredEncoding).lineEnding) })
            // Saving changes the clean baseline; it is not a new editor document.
            savedWorktree = saved
            let current = try await repository.fileComparison(path: path)
            guard sameRevision(current.worktree, saved), latestSnapshot.map({ sameIndexAndSources(current, $0) }) ?? true else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            latestSnapshot = current
            await reloadPatch(); status = compareText("Saved editor drafts")
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
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
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func applySelection(_ lines: Set<Int>) async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await repository.applyPartialStaging(partial, selectedLines: lines)
            try await refreshExpectations()
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func autoMerge() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let snapshot, let base = snapshot.base?.text, let ours = snapshot.ours?.text, let theirs = snapshot.theirs?.text else { return }
        do { draft = try await MergePreview.create(base: base, ours: ours, theirs: theirs).text } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
    func stage(resolve: Bool) async {
        guard !isBusy else { return }
        if isDirty { guard await save() else { return } }
        guard let expected = savedWorktree, let latestSnapshot else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let current = try await repository.fileComparison(path: path)
            guard sameRevision(current.worktree, expected), sameIndexAndSources(current, latestSnapshot) else {
                throw GitError("The index or working tree changed. Reload before partial staging.")
            }
            let resolving = resolve || snapshot?.isConflict == true
            if resolving { try await repository.markResolved(path: path, expected: expected, encoding: preferredEncoding) }
            else { try await repository.stage(paths: [path]) }
            try await refreshExpectations()
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
            status = compareText(resolving ? "Marked resolved and staged" : "Staged working tree file")
        } catch { self.error = compareText(OperationFailure.message(error, repository: repository.url)) }
    }
}

private struct FileCompareContent: View {
    @ObservedObject var session: FileCompareSession
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
    @State private var changeNavigation = 0
    @State private var confirmReload = false
    @State private var cursor = ComparisonCursorStatus(line: 1, column: 1, selectedCharacters: 0)
    @State private var showBase = false
    @StateObject private var resolver = ComparisonResolverState()
    @ObservedObject private var editingCommands: ComparisonEditingCommands
    @State private var conflictLayout = "all"
    @State private var confirmMerge = false
    @State private var showConflictHelp = false
    @State private var pendingVersion: String?
    @State private var confirmVersion = false
    init(session: FileCompareSession, searchOptions: ComparisonSearchOptions? = nil, replacement: String = "", initialLine: Int? = nil, initialPaneID: String = "worktree") {
        self.session = session
        self.initialPaneID = initialPaneID
        _pendingInitialLine = State(initialValue: initialLine)
        _searchOptions = State(initialValue: searchOptions ?? ComparisonSearchOptions())
        _replacement = State(initialValue: replacement)
        _showSearch = State(initialValue: searchOptions != nil)
        self.editingCommands = session.editingCommands
        let preference = UserDefaults.standard.string(forKey: "editor.comparisonLayoutMode") ?? "automatic"
        _layout = State(initialValue: ["automatic", "two", "three", "patch"].contains(preference) ? preference : "automatic")
        session.usesPatchLayout = preference == "patch"
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
                    if let snapshot = session.snapshot, !isStaticDocument,
                       [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).contains(where: \.exceedsPreviewLimit),
                       [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).allSatisfy({ !$0.exists || (!$0.isBinary && (!$0.exceedsPreviewLimit || $0.canStreamText)) }) {
                StreamingComparisonView(repository: session.repository, path: session.path, initialSearchOptions: searchOptions, initialReplacement: replacement, compact: compact, searchRequested: showSearch, onSearchClosed: { showSearch = false }, changeNavigation: changeNavigation, searchNavigation: navigation, onCursorChange: { cursor = $0 })
            } else if let snapshot = session.snapshot, snapshot.requiresStaticPreview {
                StaticComparisonView(snapshot: snapshot)
            } else if let snapshot = session.snapshot, [snapshot.head.data?.count ?? 0, snapshot.index.data?.count ?? 0, snapshot.worktree.data?.count ?? 0, snapshot.base?.data?.count ?? 0, snapshot.ours?.data?.count ?? 0, snapshot.theirs?.data?.count ?? 0].max()! > 2 * 1024 * 1024 {
                PagedComparisonView(snapshot: snapshot, layout: layout, baseline: baseline, showBase: showBase, initialSearchOptions: searchOptions, initialReplacement: replacement, compact: compact, searchRequested: showSearch, onSearchClosed: { showSearch = false }, changeNavigation: changeNavigation, searchNavigation: navigation, onCursorChange: { cursor = $0 })
            } else if session.snapshot != nil {
                ComparisonEditor(columns: columns, wrapLines: wrapLines, showLineNumbers: showNumbers, synchronizeScroll: synchronize, search: searchOptions.query, navigation: navigation, changeNavigation: changeNavigation, onEdit: { id, text in if id == "worktree" { session.draft = text } }, languagePath: session.path, resolver: session.snapshot?.isConflict == true ? resolver : nil, onCursorChange: { cursor = $0 }, editingCommands: editingCommands, scrollsToFirstChangeOnOpen: true, searchOptions: searchOptions)
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
                CompareBasePanel(column: column("base", "Base (Stage 1)", base), wraps: wrapLines, numbers: showNumbers, expanded: $showBase)
            }
            Divider()
            HStack {
                if session.isBusy { ProgressView().controlSize(.mini) }
                Text(session.isDirty ? compareText("Unsaved changes") : session.savedWorktree?.unavailableReason.map { compareText($0) } ?? session.status)
                Spacer()
                Text(session.preferredEncoding?.rawValue ?? session.savedWorktree?.data.map { ComparisonTextDecoder.format(of: $0).encoding.rawValue } ?? "").foregroundStyle(.secondary)
                if let data = session.savedWorktree?.data { Text(ComparisonTextDecoder.format(of: data).lineEnding.rawValue.uppercased()).foregroundStyle(.secondary) }
                if session.snapshot != nil { Text(designCompareText("%d versions", columns.count)).foregroundStyle(.secondary) }
                Text(designCompareText("Line %d, column %d", cursor.line, cursor.column)).foregroundStyle(.secondary)
                Text(designCompareText("%d selected", cursor.selectedCharacters)).foregroundStyle(.secondary)
                if session.snapshot?.isConflict == true {
                    Button(compareText("Cancel")) { NSApp.keyWindow?.performClose(nil) }
                    Button(compareText("Save & Mark Resolved")) { Task { await session.stage(resolve: true) } }
                        .buttonStyle(.borderedProminent).disabled(session.isBusy || !session.canEdit || ConflictDraft.hasConflictMarkers(in: session.draft))
                }
            }.font(.caption).padding(.horizontal, 14).frame(height: session.snapshot?.isConflict == true ? 52 : 34).rayGitChrome()
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
            .alert(compareText("Replace working tree draft with auto merge?"), isPresented: $confirmMerge) {
                Button(compareText("Auto Merge"), role: .destructive) { Task { await session.autoMerge() } }
                Button(compareText("Cancel"), role: .cancel) {}
            }
            .alert(compareText("Replace unsaved draft with selected version?"), isPresented: $confirmVersion) {
                Button(compareText("Replace Draft"), role: .destructive) { if let pendingVersion { session.draft = pendingVersion }; pendingVersion = nil }
                Button(compareText("Cancel"), role: .cancel) { pendingVersion = nil }
            } message: { Text(compareText("This replaces the entire editor draft. Disk and index are unchanged until you save or mark resolved.")) }
            .alert(compareText("Discard unsaved changes and reload?"), isPresented: $confirmReload) {
                Button(compareText("Reload"), role: .destructive) { Task { await session.reload() } }
                Button(compareText("Cancel"), role: .cancel) {}
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
            Task { await session.stage(resolve: session.snapshot?.isConflict == true) }
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
            compact = false; navigation += command == .compareFindNext ? 1 : -1
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
    private var searchMatches: [NSRange] { (try? ComparisonSearch.matches(in: session.draft, options: searchOptions).get()) ?? [] }
    private var searchError: String? {
        if let replacementError { return replacementError }
        if case .failure(let error) = ComparisonSearch.matches(in: session.draft, options: searchOptions) { return comparisonSearchText("Invalid regular expression") + ": " + error.localizedDescription }
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
        }.controlSize(.small).rayGitChrome()
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
                        if snapshot.isConflict { versionButton("Ours", snapshot.ours); versionButton("Theirs", snapshot.theirs); versionButton("Base", snapshot.base) }
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
                Text(compareText("Patch")).tag("patch")
            }.pickerStyle(.menu).labelsHidden().frame(width: 115, height: 24).accessibilityLabel(compareText("Layout"))
            if resolvedLayout == "two" && session.snapshot?.isConflict != true {
                Picker(compareText("Baseline"), selection: $baseline) { Text("HEAD").tag("head"); Text(compareText("Index")).tag("index") }
                    .labelsHidden().frame(width: 65, height: 24).accessibilityLabel(compareText("Baseline"))
            }
            Button { showSearch.toggle() } label: { ComparisonToolbarIcon(name: "magnifyingglass") }.buttonStyle(ComparisonToolbarButtonStyle())
                .help(comparisonSearchText("Search and replace")).accessibilityLabel(comparisonSearchText("Search and replace"))
                .popover(isPresented: Binding(get: { showSearch && supportsNativeComparison }, set: { showSearch = $0 }), arrowEdge: .bottom) {
                    ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: searchMatches.count, matchIndex: editingCommands.searchCurrent,
                        canReplace: session.canEdit && !session.isBusy && layout != "patch", onNavigate: { forward in
                            compact = false; navigation += forward ? 1 : -1
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
            if session.snapshot?.isConflict != true {
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
                .popover(isPresented: $showConflictHelp, arrowEdge: .bottom) {
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
                if session.isDirty { pendingVersion = text; confirmVersion = true } else { session.draft = text }
            }
        }.disabled((session.preferredEncoding.flatMap { version?.reinterpreting(as: $0) } ?? version)?.text == nil)
    }
    private func column(_ id: String, _ name: String, _ revision: FileRevisionContent?, editable: Bool = false) -> ComparisonEditorColumn {
        let revision = session.preferredEncoding.flatMap { encoding in revision?.reinterpreting(as: encoding) } ?? revision
        let keepsTextSurface = editable && session.snapshot?.worktree.text != nil
        let message = revision?.text != nil || keepsTextSurface ? nil : (revision?.unavailableReason.map { compareText($0) } ?? (revision?.exists == true ? nil : compareText("File does not exist in this version")))
        return ComparisonEditorColumn(id: id, title: URL(fileURLWithPath: session.path).lastPathComponent + " — " + compareText(name), text: editable ? session.draft : (revision?.text ?? ""), isEditable: editable && id == "worktree" && session.canEdit && !session.isBusy, message: message, detail: editable ? (session.isDirty ? compareText("Unsaved changes") : designCompareText("Editable")) : revision?.objectID.map { String($0.prefix(8)) } ?? designCompareText("Read-only"), preservesUndo: editable && id == "worktree")
    }
    private var columns: [ComparisonEditorColumn] {
        guard let snapshot = session.snapshot else { return [] }
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
                let snapshot = try await repository.comparisonPreview(target: target)
                guard token == version else { return }
                preview = snapshot.requiresStaticPreview ? snapshot : nil
                if snapshot.requiresStaticPreview { output = "" }
                else {
                    let raw = try await repository.diff(target: target, ignoreWhitespace: ignoreWhitespace)
                    output = try await snapshot.displayPatch(fallingBackFrom: raw, ignoreWhitespace: ignoreWhitespace)
                }
            }
            else { output = "" }
            guard token == version else { return }; text = output
        } catch { if token == version { self.error = OperationFailure.message(error, repository: repository.url) } }
        if token == version { isLoading = false }
    }
}
