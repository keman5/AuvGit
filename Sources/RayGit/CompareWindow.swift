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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title + " — " + interactionText("File Compare")
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
        return alert.runModal()
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
    @Published var snapshot: FileComparisonSnapshot?
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
    var isDirty: Bool { savedWorktree?.text != nil && draft != savedWorktree?.text }
    var canEdit: Bool { savedWorktree?.isEditable == true }
    init(repository: GitRepository, path: String) { self.repository = repository; self.path = path }
    func reload() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let snapshot = try await repository.fileComparison(path: path)
            self.snapshot = snapshot
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
            let patch = try await repository.diff(target: .worktree(path: path, untracked: snapshot?.index.exists == false && snapshot?.isConflict == false), ignoreWhitespace: ignoreWhitespace)
            guard generation == patchGeneration else { return }
            self.partial = partial; self.patch = patch
        } catch { if generation == patchGeneration { self.error = compareText(error.localizedDescription) } }
    }
    @discardableResult
    func save() async -> Bool {
        guard !isBusy, let expected = savedWorktree else { return false }
        if !isDirty { return true }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            if draft != expected.text && canEdit {
                let saved = try await repository.saveWorktree(path: path, text: draft, expected: expected, format: preferredEncoding.map { ComparisonTextFormat(encoding: $0, lineEnding: ComparisonTextDecoder.format(of: expected.data ?? Data(), encoding: preferredEncoding).lineEnding) })
                savedWorktree = saved; draft = saved.text ?? ""
            }
            snapshot = try await repository.fileComparison(path: path)
            indexDraft = displayIndex?.text ?? ""
            await reloadPatch(); status = compareText("Saved editor drafts")
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
            return true
        } catch { self.error = compareText(error.localizedDescription); return false }
    }
    func unstageFile() async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true
        do {
            let current = try await repository.fileComparison(path: path)
            guard current.index.data == partial.file.index.data else { throw GitError("The index changed. Reload before saving to the index.") }
            try await repository.unstage(paths: [path])
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
            isBusy = false; await reload()
        } catch { self.error = compareText(error.localizedDescription); isBusy = false }
    }
    func applySelection(_ lines: Set<Int>) async {
        guard !isBusy, !isDirty, let partial else { return }
        isBusy = true; error = nil
        do { try await repository.applyPartialStaging(partial, selectedLines: lines); NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url); isBusy = false; await reload() }
        catch { self.error = compareText(error.localizedDescription); isBusy = false }
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
        guard let expected = savedWorktree else { return }
        isBusy = true; error = nil
        do {
            if resolve || snapshot?.isConflict == true { try await repository.markResolved(path: path, expected: expected, encoding: preferredEncoding) }
            else {
                let current = try await repository.fileComparison(path: path)
                guard current.worktree.data == expected.data, current.index.data == snapshot?.index.data else { throw GitError("The index or working tree changed. Reload before partial staging.") }
                try await repository.stage(paths: [path])
            }
            NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
            isBusy = false; await reload(); status = compareText(resolve ? "Marked resolved and staged" : "Staged working tree file")
        } catch { self.error = compareText(error.localizedDescription); isBusy = false }
    }
}

private struct FileCompareContent: View {
    @ObservedObject var session: FileCompareSession
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @State private var layout = "automatic"
    @State private var baseline = "index"
    @AppStorage("editor.wrapLines") private var wrapLines = false
    @AppStorage("editor.showLineNumbers") private var showNumbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronize = true
    @State private var search = ""
    @State private var navigation = 0
    @State private var changeNavigation = 0
    @State private var confirmReload = false
    @State private var showBase = false
    @StateObject private var resolver = ComparisonResolverState()
    @State private var conflictLayout = "all"
    @State private var confirmMerge = false
    @State private var pendingVersion: String?
    @State private var confirmVersion = false
    init(session: FileCompareSession) {
        self.session = session
        let preference = UserDefaults.standard.string(forKey: "editor.comparisonLayoutMode") ?? "automatic"
        _layout = State(initialValue: ["automatic", "two", "three", "patch"].contains(preference) ? preference : "automatic")
    }
    private var resolvedLayout: String {
        layout == "automatic" ? (session.snapshot?.presentation.layout == .three ? "three" : "two") : layout
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = session.error {
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { session.error = nil } label: { Image(systemName: "xmark") } }.font(.caption).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(Color.orange.opacity(0.1))
            }
            if session.snapshot?.isConflict == true {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(compareText("Conflict: edit the result, save, then mark resolved"), systemImage: "arrow.triangle.merge")
                        Spacer()
                        Toggle(compareText("Show merge base"), isOn: $showBase).toggleStyle(.checkbox)
                    }
                    ConflictResolverToolbar(state: resolver, blocks: ConflictDraft.blocks(in: session.draft), enabled: session.canEdit && !session.isBusy && layout != "patch", malformed: ConflictDraft.blocks(in: session.draft).isEmpty && ConflictDraft.hasConflictMarkers(in: session.draft))
                    HStack {
                        Picker(resolverText("Resolver layout"), selection: $conflictLayout) {
                            Text(resolverText("Ours + Result")).tag("left")
                            Text(resolverText("All three")).tag("all")
                            Text(resolverText("Result + Theirs")).tag("right")
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                        Spacer()
                    }
                    Text(resolverText("Ours = Stage 2; Theirs = Stage 3. During rebase, Ours is the upstream side.")).foregroundStyle(.secondary)
                    Text(compareText("Choices change the draft only. Save, then mark resolved to stage it.")).foregroundStyle(.secondary)
                }.font(.caption).controlSize(.small).padding(8).background(Color.orange.opacity(0.1))
            }
            if layout == "patch" {
                if session.isDirty { Text(compareText("Patch shows saved disk content; save to update it")).font(.caption).foregroundStyle(.orange).padding(6) }
                PartialStagingPane(session: session)
            } else if let snapshot = session.snapshot, [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap({ $0 }).contains(where: { $0.exists && $0.data == nil && $0.unavailableReason == "Files larger than 2 MB are read-only." }) {
                StreamingComparisonView(repository: session.repository, path: session.path)
            } else if let snapshot = session.snapshot, MediaCompareView.supports(snapshot) {
                MediaCompareView(snapshot: snapshot)
            } else if let snapshot = session.snapshot, [snapshot.head.data?.count ?? 0, snapshot.index.data?.count ?? 0, snapshot.worktree.data?.count ?? 0, snapshot.base?.data?.count ?? 0, snapshot.ours?.data?.count ?? 0, snapshot.theirs?.data?.count ?? 0].max()! > 2 * 1024 * 1024 {
                PagedComparisonView(snapshot: snapshot, layout: layout, baseline: baseline, showBase: showBase)
            } else if session.snapshot != nil {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(compareText("Find in files"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .onSubmit { navigation += 1 }
                    Button { navigation -= 1 } label: { Image(systemName: "chevron.up") }.help(compareText("Previous match")).disabled(search.isEmpty)
                    Button { navigation += 1 } label: { Image(systemName: "chevron.down") }.help(compareText("Next match")).disabled(search.isEmpty)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle") } }
                    Spacer(minLength: 0)
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
                Divider()
                ComparisonEditor(columns: columns, wrapLines: wrapLines, showLineNumbers: showNumbers, synchronizeScroll: synchronize, search: search, navigation: navigation, changeNavigation: changeNavigation, onEdit: { id, text in if id == "worktree" { session.draft = text } }, languagePath: session.path, resolver: session.snapshot?.isConflict == true ? resolver : nil)
            } else { Spacer(); if session.isBusy { ProgressView() } else { Text(compareText("No file loaded")).foregroundStyle(.secondary) }; Spacer() }
            Divider()
            HStack {
                if session.isBusy { ProgressView().controlSize(.mini) }
                Text(session.isDirty ? compareText("Unsaved changes") : session.savedWorktree?.unavailableReason.map { compareText($0) } ?? session.status)
                Spacer()
                Text(session.preferredEncoding?.rawValue ?? session.savedWorktree?.data.map { ComparisonTextDecoder.format(of: $0).encoding.rawValue } ?? "").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 12).frame(height: 28)
        }.environment(\.locale, L10n.locale)
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
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(session.path).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(session.path)
                if session.isDirty { Circle().fill(.orange).frame(width: 7, height: 7) }
                Spacer()
                if session.snapshot?.isConflict == true { Button(compareText("Auto Merge")) { if session.draft != session.savedWorktree?.text { confirmMerge = true } else { Task { await session.autoMerge() } } }.disabled(session.isBusy) }
                Button(compareText("Reload")) { if session.isDirty { confirmReload = true } else { Task { await session.reload() } } }.disabled(session.isBusy)
                Button(compareText("Save")) { Task { await session.save() } }.keyboardShortcut("s").disabled(!session.isDirty || session.isBusy)
                Button(compareText(session.snapshot?.isConflict == true ? "Save & Mark Resolved" : "Save & Stage")) { Task { await session.stage(resolve: session.snapshot?.isConflict == true) } }.buttonStyle(.borderedProminent).disabled(session.isBusy || !session.canEdit)
            }
            HStack(spacing: 8) {
                Picker(compareText("Layout"), selection: $layout) {
                    Text(compareText("Automatic")).tag("automatic")
                    Text(compareText("Two Columns")).tag("two")
                    Text(compareText("Three Columns")).tag("three")
                    Text(compareText("Patch")).tag("patch")
                }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
                if layout == "two" && session.snapshot?.isConflict != true {
                    Picker(compareText("Baseline"), selection: $baseline) { Text("HEAD").tag("head"); Text(compareText("Index")).tag("index") }.labelsHidden().fixedSize(horizontal: true, vertical: false)
                }
                Button { changeNavigation -= 1 } label: { Image(systemName: "arrow.up") }.help(compareText("Previous change")).disabled(layout == "patch")
                Button { changeNavigation += 1 } label: { Image(systemName: "arrow.down") }.help(compareText("Next change")).disabled(layout == "patch")
                Menu(compareText("Use Version")) {
                    if let snapshot = session.snapshot {
                        if snapshot.isConflict {
                            versionButton("Ours", snapshot.ours); versionButton("Theirs", snapshot.theirs); versionButton("Base", snapshot.base)
                        } else { versionButton("HEAD", snapshot.head); versionButton("Index", snapshot.index) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().disabled(!session.canEdit || session.isBusy || layout == "patch")
                if let snapshot = session.snapshot { ExternalComparisonButton(snapshot: snapshot, resultText: session.draft, resultEncoding: session.preferredEncoding, onResult: { session.pendingExternalResult = $0 }) }
                ComparisonExtrasMenu(session: session)
                Menu(compareText("Display")) {
                    Toggle(compareText("Wrap Lines"), isOn: $wrapLines)
                    Toggle(compareText("Line Numbers"), isOn: $showNumbers)
                    Toggle(compareText("Synchronized Scrolling"), isOn: $synchronize)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 0)
            }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
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
        let message = revision?.text != nil ? nil : (revision?.unavailableReason.map { compareText($0) } ?? (revision?.exists == true ? nil : compareText("File does not exist in this version")))
        return ComparisonEditorColumn(id: id, title: compareText(name), text: editable ? session.draft : (revision?.text ?? ""), isEditable: editable && id == "worktree" && session.canEdit && !session.isBusy, message: message)
    }
    private var columns: [ComparisonEditorColumn] {
        guard let snapshot = session.snapshot else { return [] }
        if snapshot.isConflict {
            let left = column(showBase ? "base" : "ours", showBase ? "Base (Stage 1)" : "Ours (Stage 2)", showBase ? snapshot.base : snapshot.ours)
            let result = column("worktree", session.canEdit ? "Merge Result (Editable)" : "Merge Result (Read-only)", session.savedWorktree, editable: true)
            let right = column("theirs", "Theirs (Stage 3)", snapshot.theirs)
            if conflictLayout == "left" { return [left, result] }
            if conflictLayout == "right" { return [result, right] }
            return [left, result, right]
        }
        let title = resolvedLayout == "three" ? (session.canEdit ? "Merge Result (Editable)" : "Merge Result (Read-only)") : (session.canEdit ? "Working Tree (Editable)" : "Working Tree (Read-only)")
        let working = column("worktree", title, session.savedWorktree, editable: true)
        if resolvedLayout == "two" {
            let useHead = layout == "automatic" ? snapshot.presentation.leftRevision == .head : baseline == "head"
            return [useHead ? column("head", "HEAD", snapshot.head) : column("index", "Index", snapshot.index), working]
        }
        return [column("head", "HEAD", snapshot.head), working, column("index", "Index", snapshot.index)]
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
