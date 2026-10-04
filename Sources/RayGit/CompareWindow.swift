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
    static func show(title: String, repository: GitRepository, target: DiffTarget? = nil, stash: String? = nil) {
        let id = UUID()
        let controller = CompareController(title: title, repository: repository, target: target, stash: stash) { controllers.removeValue(forKey: id) }
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
    init(title: String, repository: GitRepository, target: DiffTarget?, stash: String?, closed: @escaping () -> Void) {
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
        if let session { window.contentView = NSHostingView(rootView: FileCompareContent(session: session)) }
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
        } catch { self.error = compareText(error.localizedDescription) }
    }
    func reloadPatch() async {
        patchGeneration += 1
        let generation = patchGeneration, unstage = unstagePartial
        do {
            let partial = try await repository.partialStaging(path: path, unstage: unstage)
            let patch = try await repository.diff(target: .worktree(path: path, untracked: latestSnapshot?.index.exists == false && latestSnapshot?.isConflict == false), ignoreWhitespace: ignoreWhitespace)
            guard generation == patchGeneration else { return }
            self.partial = partial; self.patch = patch
        } catch { if generation == patchGeneration { self.error = compareText(error.localizedDescription) } }
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
        } catch { self.error = compareText(error.localizedDescription); return false }
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
        } catch { self.error = compareText(error.localizedDescription) }
    }
    func applySelection(_ lines: Set<Int>) async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await repository.applyPartialStaging(partial, selectedLines: lines)
            try await refreshExpectations()
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
        } catch { self.error = compareText(error.localizedDescription) }
    }
    func autoMerge() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let snapshot, let base = snapshot.base?.text, let ours = snapshot.ours?.text, let theirs = snapshot.theirs?.text else { return }
        do { draft = try await MergePreview.create(base: base, ours: ours, theirs: theirs).text } catch { self.error = compareText(error.localizedDescription) }
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
        } catch { self.error = compareText(error.localizedDescription) }
    }
}

private struct FileCompareContent: View {
    @ObservedObject var session: FileCompareSession
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @State private var layout = "automatic"
    @State private var baseline = "index"
    @State private var previousEditorLayout = "automatic"
    @AppStorage("editor.wrapLines") private var wrapLines = false
    @AppStorage("editor.showLineNumbers") private var showNumbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronize = true
    @State private var search = ""
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
    init(session: FileCompareSession) {
        self.session = session
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
            if let error = session.error {
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { session.error = nil } label: { Image(systemName: "xmark") } }.font(.caption).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(Color.orange.opacity(0.1))
            }
            ZStack {
                Group {
                    if let snapshot = session.snapshot, [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).contains(where: { $0.exists && $0.data == nil && $0.unavailableReason == "Files larger than 2 MB are read-only." }) {
                StreamingComparisonView(repository: session.repository, path: session.path)
            } else if let snapshot = session.snapshot, MediaCompareView.supports(snapshot) {
                MediaCompareView(snapshot: snapshot)
            } else if let snapshot = session.snapshot, [snapshot.head.data?.count ?? 0, snapshot.index.data?.count ?? 0, snapshot.worktree.data?.count ?? 0, snapshot.base?.data?.count ?? 0, snapshot.ours?.data?.count ?? 0, snapshot.theirs?.data?.count ?? 0].max()! > 2 * 1024 * 1024 {
                PagedComparisonView(snapshot: snapshot, layout: layout, baseline: baseline, showBase: showBase)
            } else if session.snapshot != nil {
                ComparisonEditor(columns: columns, wrapLines: wrapLines, showLineNumbers: showNumbers, synchronizeScroll: synchronize, search: search, navigation: navigation, changeNavigation: changeNavigation, onEdit: { id, text in if id == "worktree" { session.draft = text } }, languagePath: session.path, resolver: session.snapshot?.isConflict == true ? resolver : nil, onCursorChange: { cursor = $0 }, editingCommands: editingCommands, scrollsToFirstChangeOnOpen: true)
            } else { Spacer(); if session.isBusy { ProgressView() } else { Text(compareText("No file loaded")).foregroundStyle(.secondary) }; Spacer() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(layout == "patch" ? 0 : 1)
                    .allowsHitTesting(layout != "patch").accessibilityHidden(layout == "patch")
                if layout == "patch" {
                    VStack(spacing: 0) {
                        if session.isDirty { Text(compareText("Patch shows saved disk content; save to update it")).font(.caption).foregroundStyle(.orange).padding(6) }
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
        }.environment(\.locale, L10n.locale)
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
        HStack(spacing: 8) {
            comparisonToolbar
            HStack(spacing: 8) {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.repository.url.appendingPathComponent(session.path).path, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help(designCompareText("Copy path")).accessibilityLabel(designCompareText("Copy path"))
                if session.isDirty { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange).help(compareText("Unsaved changes")).accessibilityLabel(compareText("Unsaved changes")) }
                Button { if session.isDirty { confirmReload = true } else { Task { await session.reload() } } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(session.isBusy).help(compareText("Reload")).accessibilityLabel(compareText("Reload"))
                Button { editingCommands.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).help(designCompareText("Undo")).accessibilityLabel(designCompareText("Undo"))
                    .disabled(session.isBusy || layout == "patch" || !editingCommands.canUndo)
                Button { editingCommands.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).help(designCompareText("Redo")).accessibilityLabel(designCompareText("Redo"))
                    .disabled(session.isBusy || layout == "patch" || !editingCommands.canRedo)
                Menu {
                    if let snapshot = session.snapshot {
                        if snapshot.isConflict { versionButton("Ours", snapshot.ours); versionButton("Theirs", snapshot.theirs); versionButton("Base", snapshot.base) }
                        else { versionButton("HEAD", snapshot.head); versionButton("Index", snapshot.index) }
                    }
                } label: { Image(systemName: "doc.badge.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                    .help(compareText("Use Version")).accessibilityLabel(compareText("Use Version"))
                    .disabled(!session.canEdit || session.isBusy || layout == "patch")
                if let snapshot = session.snapshot {
                    ExternalComparisonButton(snapshot: snapshot, resultText: session.draft, resultEncoding: session.preferredEncoding, onResult: { session.pendingExternalResult = $0 })
                        .font(.system(size: 11)).fixedSize()
                }
                ComparisonExtrasMenu(session: session)
                Button(compareText("Save")) { Task { await session.save() } }.keyboardShortcut("s")
                    .fixedSize().layoutPriority(1).disabled(!session.isDirty || session.isBusy)
                if session.snapshot?.isConflict != true {
                    Button(compareText("Save & Stage")) { Task { await session.stage(resolve: false) } }
                        .buttonStyle(.borderedProminent).fixedSize().layoutPriority(1).disabled(session.isBusy || !session.canEdit)
                }
            }.fixedSize()
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 32)
    }
    private var comparisonToolbar: some View {
        HStack(spacing: 7) {
            Picker(compareText("Layout"), selection: $layout) {
                Text(compareText("Automatic")).tag("automatic")
                Text(compareText("Two Columns")).tag("two")
                Text(compareText("Three Columns")).tag("three")
                Text(compareText("Patch")).tag("patch")
            }.pickerStyle(.menu).labelsHidden().frame(width: 135).accessibilityLabel(compareText("Layout"))
            if resolvedLayout == "two" && session.snapshot?.isConflict != true {
                Picker(compareText("Baseline"), selection: $baseline) { Text("HEAD").tag("head"); Text(compareText("Index")).tag("index") }
                    .labelsHidden().frame(width: 80).accessibilityLabel(compareText("Baseline"))
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(compareText("Find in files"), text: $search).textFieldStyle(.plain).onSubmit { navigation += 1 }
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(.horizontal, 7).frame(minWidth: 120, idealWidth: 160, maxWidth: 180).frame(height: 24).rayGitInputSurface()
                .accessibilityLabel(compareText("Find in files"))
            Button { if search.isEmpty { changeNavigation -= 1 } else { navigation -= 1 } } label: { Image(systemName: "arrow.up") }
                .help(search.isEmpty ? compareText("Previous change") : compareText("Previous match"))
                .accessibilityLabel(search.isEmpty ? compareText("Previous change") : compareText("Previous match")).disabled(layout == "patch")
            Button { if search.isEmpty { changeNavigation += 1 } else { navigation += 1 } } label: { Image(systemName: "arrow.down") }
                .help(search.isEmpty ? compareText("Next change") : compareText("Next match"))
                .accessibilityLabel(search.isEmpty ? compareText("Next change") : compareText("Next match")).disabled(layout == "patch")
            CompareDisplayButton(title: designCompareText("Sync"), symbol: "link", enabled: $synchronize)
            CompareDisplayButton(title: designCompareText("Wrap"), symbol: "text.alignleft", enabled: $wrapLines)
            CompareDisplayButton(title: designCompareText("Lines"), symbol: "list.number", enabled: $showNumbers)
            Spacer(minLength: 0)
            if session.snapshot?.isConflict != true {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    .help(designCompareText("HEAD ← Index ← Working Tree"))
                    .accessibilityLabel(designCompareText("HEAD ← Index ← Working Tree"))
            }
        }.frame(height: 32)
    }
    private var conflictToolbar: some View {
        HStack(spacing: 8) {
            ConflictResolverToolbar(state: resolver, blocks: ConflictDraft.blocks(in: session.draft), enabled: session.canEdit && !session.isBusy && layout != "patch", malformed: ConflictDraft.blocks(in: session.draft).isEmpty && ConflictDraft.hasConflictMarkers(in: session.draft))
            Picker(resolverText("Resolver layout"), selection: $conflictLayout) {
                Text(resolverText("Ours + Result")).tag("left")
                Text(resolverText("All three")).tag("all")
                Text(resolverText("Result + Theirs")).tag("right")
            }.pickerStyle(.menu).labelsHidden().frame(width: 145).accessibilityLabel(resolverText("Resolver layout"))
            Button(compareText("Auto Merge")) { if session.isDirty { confirmMerge = true } else { Task { await session.autoMerge() } } }
                .fixedSize().disabled(session.isBusy)
            Button { showConflictHelp.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(compareText("Conflict: edit the result, save, then mark resolved")).accessibilityLabel(compareText("Conflict: edit the result, save, then mark resolved"))
                .popover(isPresented: $showConflictHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(compareText("Conflict: edit the result, save, then mark resolved")).fontWeight(.semibold)
                        Text(resolverText("Ours = Stage 2; Theirs = Stage 3. During rebase, Ours is the upstream side."))
                        Text(compareText("Choices change the draft only. Save, then mark resolved to stage it."))
                    }.font(.callout).padding(16).frame(width: 340)
                }
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 32)
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
        return ComparisonEditorColumn(id: id, title: compareText(name), text: editable ? session.draft : (revision?.text ?? ""), isEditable: editable && id == "worktree" && session.canEdit && !session.isBusy, message: message, detail: editable ? (session.isDirty ? compareText("Unsaved changes") : designCompareText("Editable")) : revision?.objectID.map { String($0.prefix(8)) } ?? designCompareText("Read-only"), preservesUndo: editable && id == "worktree")
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
    @State private var error: String?
    @State private var isLoading = true
    @State private var version = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(repository.url.lastPathComponent).foregroundStyle(.secondary); Spacer()
                Toggle(interactionText("Ignore Whitespace"), isOn: $ignoreWhitespace).disabled(stash != nil)
                Button(interactionText("Refresh")) { Task { await reload() } }
            }.font(.caption).padding(10)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
            DiffPane(text: text, title: title, isLoading: isLoading)
        }.environment(\.locale, L10n.locale).task { await reload() }
            .onChange(of: ignoreWhitespace) { _, _ in Task { await reload() } }.onDisappear { version = UUID() }
    }
    private func reload() async {
        let token = UUID(); version = token; isLoading = true; error = nil
        do {
            let output: String
            if let stash { output = try await repository.stashDiff(ref: stash) }
            else if let target { output = try await repository.diff(target: target, ignoreWhitespace: ignoreWhitespace) }
            else { output = "" }
            guard token == version else { return }; text = output
        } catch { if token == version { self.error = error.localizedDescription } }
        if token == version { isLoading = false }
    }
}
