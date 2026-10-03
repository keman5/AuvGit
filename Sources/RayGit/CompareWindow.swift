import SwiftUI
import AppKit
import Combine
import GitCore
import RayGitLocalization

func interactionText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Interactions", arguments: arguments)
}
func compareText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Compare", arguments: arguments)
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
    @Published var isBusy = false
    @Published var error: String?
    @Published var status = ""
    @Published var patch = ""
    @Published var ignoreWhitespace = false
    var isDirty: Bool { (savedWorktree?.text != nil && draft != savedWorktree?.text) || (snapshot?.index.text != nil && indexDraft != snapshot?.index.text) }
    var canEdit: Bool { savedWorktree?.isEditable == true }
    init(repository: GitRepository, path: String) { self.repository = repository; self.path = path }
    func reload() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let snapshot = try await repository.fileComparison(path: path)
            self.snapshot = snapshot; savedWorktree = snapshot.worktree; draft = snapshot.worktree.text ?? ""; indexDraft = snapshot.index.text ?? ""
            await reloadPatch(); status = compareText("Loaded from disk")
        } catch { self.error = compareText(error.localizedDescription) }
    }
    func reloadPatch() async {
        do { partial = try await repository.partialStaging(path: path, unstage: unstagePartial); patch = try await repository.diff(target: .worktree(path: path, untracked: snapshot?.index.exists == false && snapshot?.isConflict == false), ignoreWhitespace: ignoreWhitespace) }
        catch { self.error = compareText(error.localizedDescription) }
    }
    @discardableResult
    func save() async -> Bool {
        guard !isBusy, let expected = savedWorktree else { return false }
        if !isDirty { return true }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            if indexDraft != snapshot?.index.text, let index = snapshot?.index {
                try await repository.saveIndex(path: path, text: indexDraft, expected: index)
                snapshot = try await repository.fileComparison(path: path)
                indexDraft = snapshot?.index.text ?? ""
                NotificationCenter.default.post(name: .rayGitWorktreeChanged, object: repository.url)
            }
            if draft != expected.text && canEdit {
                let saved = try await repository.saveWorktree(path: path, text: draft, expected: expected)
                savedWorktree = saved; draft = saved.text ?? ""
            }
            snapshot = try await repository.fileComparison(path: path)
            indexDraft = snapshot?.index.text ?? ""
            await reloadPatch(); status = compareText("Saved to working tree; index unchanged")
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
        guard let snapshot, let base = snapshot.base?.text, let ours = snapshot.ours?.text, let theirs = snapshot.theirs?.text else { return }
        do { draft = try await MergePreview.create(base: base, ours: ours, theirs: theirs).text } catch { self.error = compareText(error.localizedDescription) }
    }
    func stage(resolve: Bool) async {
        guard !isBusy else { return }
        if isDirty { guard await save() else { return } }
        guard let expected = savedWorktree else { return }
        isBusy = true; error = nil
        do {
            if resolve { try await repository.markResolved(path: path, expected: expected) }
            else {
                let current = try await repository.fileComparison(path: path)
                guard current.worktree.data == expected.data else { throw GitError("File changed on disk. Reload before saving.") }
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
    @State private var layout = "three"
    @State private var baseline = "index"
    @State private var wrapLines = false
    @State private var showNumbers = true
    @State private var synchronize = true
    @State private var search = ""
    @State private var navigation = 0
    @State private var changeNavigation = 0
    @State private var confirmReload = false
    @State private var showBase = false
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = session.error {
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { session.error = nil } label: { Image(systemName: "xmark") } }.font(.caption).padding(10).background(Color.orange.opacity(0.1))
            }
            if session.snapshot?.isConflict == true {
                HStack { Label(compareText("Conflict: edit the result, save, then mark resolved"), systemImage: "arrow.triangle.merge"); Spacer(); Toggle(compareText("Show merge base"), isOn: $showBase).toggleStyle(.checkbox) }.font(.caption).padding(8).background(Color.orange.opacity(0.1))
            }
            if layout == "patch" {
                if session.isDirty { Text(compareText("Patch shows saved disk content; save to update it")).font(.caption).foregroundStyle(.orange).padding(6) }
                PartialStagingPane(session: session)
            } else if let snapshot = session.snapshot, MediaCompareView.supports(snapshot) {
                MediaCompareView(snapshot: snapshot)
            } else if let snapshot = session.snapshot, [snapshot.head.data?.count ?? 0, snapshot.index.data?.count ?? 0, snapshot.worktree.data?.count ?? 0].max()! > 2 * 1024 * 1024 {
                PagedComparisonView(snapshot: snapshot)
            } else if session.snapshot != nil {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(compareText("Find in files"), text: $search).textFieldStyle(.plain)
                    Button { navigation -= 1 } label: { Image(systemName: "chevron.up") }.help(compareText("Previous match")).disabled(search.isEmpty)
                    Button { navigation += 1 } label: { Image(systemName: "chevron.down") }.help(compareText("Next match")).disabled(search.isEmpty)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle") } }
                }.padding(8)
                Divider()
                ComparisonEditor(columns: columns, wrapLines: wrapLines, showLineNumbers: showNumbers, synchronizeScroll: synchronize, search: search, navigation: navigation, changeNavigation: changeNavigation, onEdit: { id, text in if id == "worktree" { session.draft = text }; if id == "index" { session.indexDraft = text } }, languagePath: session.path)
            } else { Spacer(); if session.isBusy { ProgressView() } else { Text(compareText("No file loaded")).foregroundStyle(.secondary) }; Spacer() }
            Divider()
            HStack {
                if session.isBusy { ProgressView().controlSize(.mini) }
                Text(session.isDirty ? compareText("Unsaved changes") : session.savedWorktree?.unavailableReason.map { compareText($0) } ?? session.status)
                Spacer()
                Text(session.path).lineLimit(1).truncationMode(.middle)
                Text("UTF-8").foregroundStyle(.secondary).opacity(session.canEdit ? 1 : 0)
            }.font(.caption).padding(.horizontal, 10).frame(height: 28)
        }.environment(\.locale, L10n.locale)
            .task { await session.reload() }
            .alert(compareText("Discard unsaved changes and reload?"), isPresented: $confirmReload) {
                Button(compareText("Reload"), role: .destructive) { Task { await session.reload() } }
                Button(compareText("Cancel"), role: .cancel) {}
            }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(session.path).font(.headline).lineLimit(1).truncationMode(.middle)
                if session.isDirty { Circle().fill(.orange).frame(width: 7, height: 7) }
                Spacer()
                if session.snapshot?.isConflict == true { Button(compareText("Auto Merge")) { Task { await session.autoMerge() } }.disabled(session.isBusy) }
                Button(compareText("Reload")) { if session.isDirty { confirmReload = true } else { Task { await session.reload() } } }.disabled(session.isBusy)
                Button(compareText("Save")) { Task { await session.save() } }.keyboardShortcut("s").disabled(!session.isDirty || session.isBusy)
                Button(compareText(session.snapshot?.isConflict == true ? "Save & Mark Resolved" : "Save & Stage")) { Task { await session.stage(resolve: session.snapshot?.isConflict == true) } }.disabled(session.isBusy || !session.canEdit)
            }
            HStack(spacing: 10) {
                Picker(compareText("Layout"), selection: $layout) {
                    Text(compareText("Two Columns")).tag("two")
                    Text(compareText("Three Columns")).tag("three")
                    Text(compareText("Patch")).tag("patch")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 310)
                if layout == "two" && session.snapshot?.isConflict != true {
                    Picker(compareText("Baseline"), selection: $baseline) { Text("HEAD").tag("head"); Text(compareText("Index")).tag("index") }.frame(width: 155)
                }
                Button { changeNavigation -= 1 } label: { Image(systemName: "arrow.up") }.help(compareText("Previous change")).disabled(layout == "patch")
                Button { changeNavigation += 1 } label: { Image(systemName: "arrow.down") }.help(compareText("Next change")).disabled(layout == "patch")
                Spacer()
                Menu(compareText("Use Version")) {
                    if let snapshot = session.snapshot {
                        if snapshot.isConflict {
                            versionButton("Ours", snapshot.ours); versionButton("Theirs", snapshot.theirs); versionButton("Base", snapshot.base)
                        } else { versionButton("HEAD", snapshot.head); versionButton("Index", snapshot.index) }
                    }
                }.disabled(!session.canEdit || session.isBusy || layout == "patch")
                if let snapshot = session.snapshot { ExternalComparisonButton(snapshot: snapshot) }
                Menu(compareText("Display")) {
                    Toggle(compareText("Wrap Lines"), isOn: $wrapLines)
                    Toggle(compareText("Line Numbers"), isOn: $showNumbers)
                    Toggle(compareText("Synchronized Scrolling"), isOn: $synchronize)
                }
                if layout == "patch" { Toggle(interactionText("Ignore Whitespace"), isOn: $session.ignoreWhitespace).onChange(of: session.ignoreWhitespace) { _, _ in Task { await session.reloadPatch() } } }
            }
        }.padding(10).background(.bar)
    }
    private func versionButton(_ name: String, _ version: FileRevisionContent?) -> some View {
        Button(compareText(name)) { if let text = version?.text { session.draft = text } }.disabled(version?.text == nil)
    }
    private func column(_ id: String, _ name: String, _ revision: FileRevisionContent?, editable: Bool = false) -> ComparisonEditorColumn {
        let message = revision?.text != nil ? nil : (revision?.unavailableReason.map { compareText($0) } ?? (revision?.exists == true ? nil : compareText("File does not exist in this version")))
        return ComparisonEditorColumn(id: id, title: compareText(name), text: id == "index" ? session.indexDraft : editable ? session.draft : (revision?.text ?? ""), isEditable: (id == "index" ? revision?.isEditable == true : editable && session.canEdit) && !session.isBusy, message: message)
    }
    private var columns: [ComparisonEditorColumn] {
        guard let snapshot = session.snapshot else { return [] }
        if snapshot.isConflict {
            let left = column(showBase ? "base" : "ours", showBase ? "Base" : "Ours", showBase ? snapshot.base : snapshot.ours)
            let result = column("worktree", "Working Tree / Result", session.savedWorktree, editable: true)
            return layout == "two" ? [left, result] : [left, result, column("theirs", "Theirs", snapshot.theirs)]
        }
        let working = column("worktree", session.canEdit ? "Working Tree (Editable)" : "Working Tree (Read-only)", session.savedWorktree, editable: true)
        return layout == "two" ? [baseline == "head" ? column("head", "HEAD", snapshot.head) : column("index", "Index", snapshot.index), working] : [column("head", "HEAD", snapshot.head), column("index", "Index", snapshot.index), working]
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
