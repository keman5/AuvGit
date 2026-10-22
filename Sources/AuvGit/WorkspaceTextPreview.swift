import AppKit
import UniformTypeIdentifiers
import GitCore
import AuvGitLocalization

func previewText(_ key: String) -> String { L10n.text(key, table: "TextPreview") }

/// Original bytes preserve encoding and protect against external edits.
final class WorkspaceTextPreviewDocument {
    let url: URL
    let resolvedURL: URL
    let format: ComparisonTextFormat
    private var savedData: Data
    private var savedText: String
    var text: String
    var isDirty: Bool { text != savedText }

    private init(url: URL, data: Data, text: String) {
        self.url = url
        resolvedURL = url.resolvingSymlinksInPath()
        savedData = data
        format = ComparisonTextDecoder.format(of: data)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        savedText = normalized
        self.text = normalized
    }

    static func open(_ url: URL, defaults: UserDefaults = .standard) throws -> WorkspaceTextPreviewDocument? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true else { return nil }
        let forceText = TextPreviewPreferences.matches(url, formats: TextPreviewPreferences.formats(defaults: defaults))
        if !forceText, let type = values.contentType,
           [UTType.image, .audiovisualContent, .pdf, .archive, .rtf, .rtfd].contains(where: { type.conforms(to: $0) }) { return nil }
        // Bound synchronous work on the preview key path. Large files use Quick Look.
        let limit = 16 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit,
              let text = ComparisonTextDecoder.decode(data).text,
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) else { return nil }
        return WorkspaceTextPreviewDocument(url: url, data: data, text: text)
    }

    func save() throws {
        guard isDirty else { return }
        guard url.resolvingSymlinksInPath() == resolvedURL,
              try Data(contentsOf: resolvedURL) == savedData else {
            throw GitError(previewText("The file changed outside this preview. Reopen it before saving."))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)[.posixPermissions]
        let data = try ComparisonTextDecoder.encode(text, format: format)
        try data.write(to: resolvedURL, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolvedURL.path) }
        savedData = data
        savedText = text
    }
}

enum MonokaiPreviewTheme {
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let background = color(0x272822)
    static let foreground = color(0xF8F8F2)
    static let selection = color(0x49483E)
    static let caret = color(0xF8F8F0)
    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: color(0xF92672)
        case .string: color(0xE6DB74)
        case .comment: color(0x75715E)
        case .number: color(0xAE81FF)
        }
    }
    static func apply(_ tokens: [SyntaxToken], to storage: NSTextStorage) {
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: storage.length))
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }
}

@MainActor
enum WorkspaceTextPreviewPresenter {
    private(set) static var current: WorkspaceTextPreviewController?
    static func show(_ document: WorkspaceTextPreviewDocument, repositoryURL: URL?) {
        let controller = WorkspaceTextPreviewController(document: document, repositoryURL: repositoryURL) { current = nil }
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
    static func closeVisiblePreview() -> Bool {
        guard let controller = current, controller.window?.isVisible == true else { return false }
        controller.window?.performClose(nil)
        return true
    }
    static var hasUnsavedChanges: Bool { current?.previewDocument.isDirty == true }
    static func prepareToTerminate() -> Bool { current?.approveClose() ?? true }
}

/// Only a click or Tab enters editing; opening a preview does not take focus.
final class WorkspacePreviewTextView: NSTextView {
    var permitsFocus = false
    override var acceptsFirstResponder: Bool { permitsFocus && super.acceptsFirstResponder }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEditable { addCursorRect(visibleRect, cursor: .iBeam) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if isEditable { NSCursor.iBeam.set() }
        else { super.cursorUpdate(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        permitsFocus = true
        // NSWindow tries to focus the view before dispatching mouseDown, while
        // permitsFocus is still false. Retry only in response to this click.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

final class WorkspaceTextPreviewWindow: NSWindow {
    weak var editor: WorkspacePreviewTextView?
    var saveDocument: (() -> Void)?
    var isEditingContent: Bool { firstResponder === editor }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, modifiers.isEmpty { performClose(nil); return }
            if event.keyCode == 49, modifiers.isEmpty, !isEditingContent { performClose(nil); return }
            if event.keyCode == 48, modifiers.isEmpty, !isEditingContent, let editor {
                editor.permitsFocus = true
                makeFirstResponder(editor)
                return
            }
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, event.charactersIgnoringModifiers?.lowercased() == "s",
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            saveDocument?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class WorkspaceTextPreviewController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let previewDocument: WorkspaceTextPreviewDocument
    let editor = WorkspacePreviewTextView(frame: .zero)
    private let status = NSTextField(labelWithString: "")
    private let saveButton = NSButton()
    private let repositoryURL: URL?
    private let closed: () -> Void
    private var highlightTask: Task<Void, Never>?

    init(document: WorkspaceTextPreviewDocument, repositoryURL: URL?, closed: @escaping () -> Void) {
        self.previewDocument = document
        self.repositoryURL = repositoryURL
        self.closed = closed
        let window = WorkspaceTextPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = document.url.lastPathComponent + " — " + previewText("Text Preview")
        window.representedURL = document.url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MonokaiPreviewTheme.background
        super.init(window: window)
        window.delegate = self
        window.editor = editor
        window.saveDocument = { [weak self] in _ = self?.save() }
        configureContent(in: window)
        WindowFrameAppearance.clip(window)
        window.center()
        updateStatus()
        highlight()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { highlightTask?.cancel() }

    private func configureContent(in window: NSWindow) {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MonokaiPreviewTheme.background
        editor.isRichText = false
        editor.isEditable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.backgroundColor = MonokaiPreviewTheme.background
        editor.textColor = MonokaiPreviewTheme.foreground
        editor.insertionPointColor = MonokaiPreviewTheme.caret
        editor.selectedTextAttributes = [.backgroundColor: MonokaiPreviewTheme.selection, .foregroundColor: MonokaiPreviewTheme.foreground]
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: MonokaiPreviewTheme.foreground]
        editor.textContainerInset = NSSize(width: 16, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 920, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = previewDocument.text
        editor.setAccessibilityLabel(previewText("Editable file contents"))
        editor.delegate = self
        scroll.documentView = editor
        saveButton.title = previewText("Save") + "  ⌘S"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.focusRingType = .none
        let hint = NSTextField(labelWithString: previewText("Monokai · Click or Tab to edit · Esc to close"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [hint, NSView(), status, saveButton])
        footer.spacing = 12
        for view in [scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        window.contentView = root
    }

    func textDidChange(_ notification: Notification) {
        previewDocument.text = editor.string
        updateStatus()
        highlight()
    }
    private func updateStatus() {
        window?.isDocumentEdited = previewDocument.isDirty
        saveButton.isEnabled = previewDocument.isDirty
        status.stringValue = previewDocument.isDirty ? previewText("Unsaved changes") : previewDocument.format.encoding.rawValue + " · " + previewDocument.format.lineEnding.rawValue.uppercased()
    }
    private func highlight() {
        highlightTask?.cancel()
        let text = editor.string, path = previewDocument.url.path
        highlightTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let tokens = await Task.detached(priority: .userInitiated) { SyntaxHighlighter.tokens(in: text, path: path) }.value
            guard !Task.isCancelled, let self, self.editor.string == text, let storage = self.editor.textStorage else { return }
            MonokaiPreviewTheme.apply(tokens, to: storage)
            self.editor.typingAttributes = [.font: self.editor.font!, .foregroundColor: MonokaiPreviewTheme.foreground]
        }
    }
    @objc private func saveClicked() { _ = save() }
    @discardableResult func save() -> Bool {
        previewDocument.text = editor.string
        do {
            let changed = previewDocument.isDirty
            try previewDocument.save()
            updateStatus()
            if changed, let repositoryURL { NotificationCenter.default.post(name: .auvGitWorktreeChanged, object: repositoryURL) }
            return true
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return false
        }
    }
    func approveClose() -> Bool {
        guard previewDocument.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        switch DialogAppearance.confirmClose(title: compareText("Save changes before closing?"), message: previewDocument.url.path,
            save: compareText("Save"), discard: compareText("Discard Draft"), cancel: compareText("Cancel")) {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { approveClose() }
    func windowWillClose(_ notification: Notification) { highlightTask?.cancel(); closed() }
}
