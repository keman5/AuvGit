import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

enum ComparisonEditorMetrics {
    static let textInset = NSSize(width: 3, height: 4)
    static let lineFragmentPadding: CGFloat = 2
    static let headerHeight: CGFloat = 28
    static let actionRailWidth: CGFloat = 24
    static let actionButtonWidth: CGFloat = 20
    static let actionButtonHeight: CGFloat = 24
    static func signWidth(codeFont: NSFont) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: codeFont.pointSize, weight: .semibold)
        return max(12, ceil(("−" as NSString).size(withAttributes: [.font: font]).width) + 4)
    }
    static func gutterWidth(firstLine: Int, lineCount: Int, codeFont: NSFont, showsNumbers: Bool) -> CGFloat {
        let sign = signWidth(codeFont: codeFont)
        guard showsNumbers else { return sign + 6 }
        let digits = max(3, String(max(firstLine, firstLine + max(0, lineCount - 1))).count)
        let numberFont = DiffVisualStyle.lineNumberFont(codeSize: codeFont.pointSize)
        let numbers = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: numberFont]).width
        return ceil(numbers) + sign + 6
    }
}

enum DiffVisualStyle {
    static func lineNumberFont(codeSize: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(8, codeSize - 2), weight: .regular)
    }
    static var lineNumberColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.labelColor.withAlphaComponent(dark ? 0.48 : 0.40)
        }
    }
    static func lineBackground(_ color: NSColor, dark: Bool) -> NSColor {
        color.withAlphaComponent(dark ? 0.28 : 0.22)
    }
    static func characterBackground(_ color: NSColor, dark: Bool) -> NSColor {
        color.withAlphaComponent(dark ? 0.48 : 0.43)
    }
}

struct ComparisonEditorColumn: Identifiable {
    let id: String
    let title: String
    let text: String
    let isEditable: Bool
    let message: String?
    var firstLine: Int = 1
    var detail: String = ""
    var preservesUndo: Bool = false
}

struct ComparisonCursorStatus {
    let line: Int
    let column: Int
    let selectedCharacters: Int
}

struct ComparisonEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editor.additionColor") private var additionColor = ""
    @AppStorage("editor.deletionColor") private var deletionColor = ""
    @AppStorage("editor.modificationColor") private var modificationColor = ""
    @AppStorage("editor.fontName") private var fontName = ""
    @AppStorage("editor.fontSize") private var fontSize = 12.0
    @AppStorage("editor.tabWidth") private var tabWidth = 4
    @AppStorage("editor.syntaxHighlight") private var syntaxHighlight = true
    @AppStorage("editor.characterDiff") private var characterDiff = true
    @AppStorage("editor.showWhitespace") private var showWhitespace = false
    @AppStorage("editor.highlightCurrentLine") private var highlightCurrentLine = true
    let columns: [ComparisonEditorColumn]
    let wrapLines: Bool
    let showLineNumbers: Bool
    let synchronizeScroll: Bool
    let search: String
    let navigation: Int
    let changeNavigation: Int
    let onEdit: (String, String) -> Void
    var languagePath: String = ""
    var resolver: ComparisonResolverState? = nil
    var onCursorChange: ((ComparisonCursorStatus) -> Void)? = nil
    var editingCommands: ComparisonEditingCommands? = nil
    var revealRequest: ComparisonRevealRequest? = nil
    var overviewMarkers: [ComparisonOverviewMarker]? = nil
    var onOverviewJump: ((Int) -> Void)? = nil
    var onOverviewNavigate: ((Double) -> Void)? = nil
    var scrollsToFirstChangeOnOpen = false
    var searchOptions: ComparisonSearchOptions? = nil
    var effectiveSearch: ComparisonSearchOptions { searchOptions ?? ComparisonSearchOptions(query: search) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSplitView {
        let split = ComparisonSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        context.coordinator.split = split
        split.onAttach = { [weak coordinator = context.coordinator] in coordinator?.scheduleAlignment() }
        context.coordinator.update(self)
        return split
    }
    func updateNSView(_ nsView: NSSplitView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ComparisonEditor
        weak var split: NSSplitView?
        fileprivate var panes: [Pane] = []
        fileprivate var paneCache: [String: Pane] = [:]
        var alignedTexts: [String] = []
        private var cachedAlignmentTexts: [String] = []
        private var cachedAlignmentBaseline = -1
        private var cachedConflictMode = false
        private var cachedAlignment: ComparisonAlignment?
        private var diffTexts: [String] = []
        private var cachedDiffs: [String: TextLineDiff] = [:]
        private var syntaxCache: [String: (String, String, [SyntaxToken])] = [:]
        private(set) var alignmentBuildCount = 0
        var alignmentGeometry = ""
        var scrollSourceID: String?
        var alignmentScheduled = false
        var aligning = false
        var scrolling = false
        var updating = false
        var didScrollToInitialChange = false
        var searchIndices: [String: Int] = [:]
        var navigationTexts: [String] = []
        var navigationBaseline = -1
        var navigationBands: [[Range<Int>]] = []
        private var consumedRevealRequest: UUID?
        var changeBandIndex: Int?
        var navigatingChange = false
        var lastNavigation: Int
        var lastChangeNavigation: Int
        var preferenceSignature = ""
        var changedRanges: [String: [NSRange]] = [:]
        var lineDiffs: [String: TextLineDiff] = [:]
        weak var active: NSTextView?
        init(_ model: ComparisonEditor) { self.model = model; lastNavigation = model.navigation; lastChangeNavigation = model.changeNavigation }
        deinit { NotificationCenter.default.removeObserver(self) }

        func update(_ value: ComparisonEditor) {
            updating = true
            defer { updating = false }
            let rebuild = panes.map(\.id) != value.columns.map(\.id)
            let previousSearch = model.effectiveSearch
            let previousLanguage = model.languagePath
            let settings = "\(value.fontName)|\(value.fontSize)|\(value.tabWidth)|\(value.syntaxHighlight)|\(value.characterDiff)|\(value.showWhitespace)|\(value.highlightCurrentLine)|\(value.additionColor)|\(value.deletionColor)|\(value.modificationColor)|\(value.colorScheme)"
            let preferencesChanged = preferenceSignature != settings
            if preferencesChanged || rebuild { alignmentGeometry = "" }
            preferenceSignature = settings
            if previousSearch != value.effectiveSearch { searchIndices = [:]; scheduleSearchStatus() }
            model = value
            value.resolver?.select = { [weak self] index in self?.selectConflict(index) }
            value.resolver?.accept = { [weak self] side, index in self?.acceptConflict(side, index: index) }
            value.editingCommands?.takeBlockAction = { [weak self] fromLeft in self?.takeBlock(fromLeft: fromLeft) ?? false }
            value.editingCommands?.focusEditorAction = { [weak self] in
                guard let self, let pane = self.historyTarget() ?? self.panes.first(where: { $0.id == "worktree" }) ?? self.panes.first else { return }
                pane.text.window?.makeFirstResponder(pane.text); self.active = pane.text
            }
            value.editingCommands?.selectReadOnlyRangeAction = { [weak self] id, range in
                guard let self, let pane = self.panes.first(where: { $0.id == id }) else { return }
                let location = min(range.location, pane.text.string.utf16.count)
                pane.text.setSelectedRange(NSRange(location: location, length: min(range.length, pane.text.string.utf16.count - location)))
                self.didScrollToInitialChange = true
                self.scrollAll(to: pane.y(forLine: pane.line(atUTF16: location)) - 24)
                self.active = pane.text
            }
            value.editingCommands?.revealLineAction = { [weak self] id, number in
                guard let self, let pane = self.panes.first(where: { $0.id == id }) else { return }
                let line = max(0, number - pane.gutter.firstLine)
                if !pane.text.isEditable, let editable = self.historyTarget(), let sourceIndex = self.panes.firstIndex(where: { $0 === pane }), let targetIndex = self.panes.firstIndex(where: { $0 === editable }) {
                    let texts = self.panes.map { $0.text.string }
                    let baseline = self.model.resolver != nil ? targetIndex : 0
                    let alignment = ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: self.model.resolver != nil ? ConflictDraft.blocks(in: texts[baseline]) : [])
                    if let band = alignment.bands.first(where: { $0[sourceIndex].contains(line) }) { self.revealLine(editable, line: band[targetIndex].lowerBound); return }
                }
                self.revealLine(pane, line: line)
            }
            value.editingCommands?.replaceSearchAction = { [weak self] options, replacement, all in
                guard let self, let pane = self.panes.first(where: { $0.id == "worktree" && $0.text.isEditable }) else { return comparisonSearchText("This preview is read-only.") }
                switch ComparisonSearch.replacing(in: pane.text.string, options: options, replacement: replacement, all: all, selected: pane.text.selectedRange()) {
                case .failure(let error): return error.localizedDescription
                case .success(let value):
                    pane.text.replaceAsUndoableEdit(value, actionName: comparisonSearchText(all ? "Replace all" : "Replace"))
                    self.active = pane.text
                    return nil
                }
            }
            value.editingCommands?.connect(undo: { [weak self] in self?.performHistory(redo: false) }, redo: { [weak self] in self?.performHistory(redo: true) })
            if rebuild, let split {
                NotificationCenter.default.removeObserver(self)
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: NSWindow.didResignKeyNotification, object: nil)
                let focusedID = panes.first(where: { $0.text === active || $0.text === split.window?.firstResponder })?.id
                split.subviews.forEach { $0.removeFromSuperview() }
                panes = value.columns.map { column in
                    let pane = paneCache[column.id] ?? Pane(column: column)
                    paneCache[column.id] = pane
                    pane.text.focusChanged = { [weak self, weak pane] in
                        guard let self, let pane else { return }
                        self.redrawCurrentLines()
                        if pane.text.window?.firstResponder === pane.text {
                            self.active = pane.text
                            self.reportCursor(in: pane)
                            self.scheduleCommandState()
                        }
                    }
                    pane.text.historyChanged = { [weak self] in self?.scheduleCommandState() }
                    pane.text.delegate = self
                    pane.geometryChanged = { [weak self] in self?.scheduleAlignment() }
                    pane.text.blockMenu = { [weak self, weak pane] line in
                        guard let self, let pane else { return [] }
                        return self.acceptActions(for: pane, line: line)
                    }
                    pane.scroll.contentView.postsBoundsChangedNotifications = true
                    NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)), name: NSView.boundsDidChangeNotification, object: pane.scroll.contentView)
                    split.addArrangedSubview(pane)
                    return pane
                }
                if let focusedID, let pane = panes.first(where: { $0.id == focusedID }) {
                    split.window?.makeFirstResponder(pane.text)
                }
                (split as? ComparisonSplitView)?.resetDistribution()
            }
            var changed = preferencesChanged || rebuild || previousSearch != value.effectiveSearch || previousLanguage != value.languagePath
            for (pane, column) in zip(panes, value.columns) {
                pane.title.stringValue = column.title
                pane.title.toolTip = column.title
                pane.detail.stringValue = column.detail
                pane.detail.toolTip = column.detail
                pane.preservesUndo = pane.preservesUndo || column.preservesUndo || column.isEditable
                pane.text.isEditable = column.isEditable && column.message == nil
                // Keep undo enabled during save/loading; changing this property clears native history.
                if !pane.text.allowsUndo { pane.text.allowsUndo = true }
                pane.message.stringValue = column.message ?? ""
                pane.message.isHidden = column.message == nil
                pane.scroll.isHidden = column.message != nil
                if pane.text.string != column.text {
                    let selected = pane.text.selectedRange()
                    if pane.preservesUndo {
                        pane.text.replaceAsUndoableEdit(column.text)
                        active = pane.text
                        pane.text.window?.makeFirstResponder(pane.text)
                    } else { pane.text.string = column.text }
                    let length = (column.text as NSString).length
                    pane.text.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
                    changed = true
                }
                pane.gutter.isHidden = false
                pane.wrap(value.wrapLines)
                let font = EditorPreferences.font(name: value.fontName, size: value.fontSize)
                if pane.text.font != font { pane.text.font = font }
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = []
                paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(min(16, max(1, value.tabWidth)))
                pane.text.defaultParagraphStyle = paragraph
                pane.text.typingAttributes[.paragraphStyle] = paragraph
                if preferencesChanged || rebuild { pane.text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: pane.text.string.utf16.count)) }
                pane.text.layoutManager?.showsInvisibleCharacters = value.showWhitespace
                pane.text.highlightCurrentLine = value.highlightCurrentLine
                pane.text.needsDisplay = true
                pane.gutter.additionColor = EditorPreferences.color(value.additionColor, fallback: .systemGreen)
                pane.gutter.deletionColor = EditorPreferences.color(value.deletionColor, fallback: .systemRed)
                pane.gutter.showsLineNumbers = value.showLineNumbers
                pane.gutter.firstLine = column.firstLine
                pane.gutter.setContent(column.text)
                pane.updateGutterWidth()
                pane.gutter.needsDisplay = true
                pane.needsLayout = true
            }
            if changed { decorate() }
            updateConflictGutters()
            scheduleAlignment()
            scheduleCommandState()
            if value.overviewMarkers != nil { refreshOverviews() }
            if lastChangeNavigation != value.changeNavigation || lastNavigation != value.navigation { alignDisplay() }
            if lastChangeNavigation != value.changeNavigation {
                didScrollToInitialChange = true
                navigateChange(forward: value.changeNavigation > lastChangeNavigation)
                lastChangeNavigation = value.changeNavigation
            }
            if lastNavigation != value.navigation {
                didScrollToInitialChange = true
                navigate(forward: value.navigation > lastNavigation)
                lastNavigation = value.navigation
            }
            if let request = value.revealRequest { scheduleReveal(request) }
        }
        private func scheduleReveal(_ request: ComparisonRevealRequest) {
            guard consumedRevealRequest != request.id else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.consumedRevealRequest != request.id, self.model.revealRequest?.id == request.id,
                      let pane = self.panes.first(where: { $0.id == request.paneID }), pane.gutter.firstLine == request.firstLine else { return }
                self.consumedRevealRequest = request.id
                self.alignDisplay()
                if let range = request.range { self.model.editingCommands?.revealRange(paneID: request.paneID, range: range) }
                else if let line = request.number { self.revealLine(pane, line: max(0, line - pane.gutter.firstLine)) }
            }
        }
        private func scheduleSearchStatus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let pane = self.panes.first(where: { $0.id == "worktree" }) ?? self.panes.first else { return }
                let total = (try? ComparisonSearch.matches(in: pane.text.string, options: self.model.effectiveSearch).get().count) ?? 0
                let current = self.searchIndices[pane.id].map { min($0 + 1, total) } ?? 0
                self.model.editingCommands?.updateSearch(current: current, total: total)
            }
        }
        private var commandStateScheduled = false
        func scheduleCommandState() {
            guard !commandStateScheduled else { return }
            commandStateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.commandStateScheduled = false
                let target = self.historyTarget()
                self.model.editingCommands?.update(canUndo: target?.text.editingUndoManager.canUndo == true,
                    canRedo: target?.text.editingUndoManager.canRedo == true)
            }
        }
        private func historyTarget() -> Pane? {
            let editable = panes.filter { $0.preservesUndo && $0.text.isEditable && !$0.scroll.isHidden }
            return editable.first(where: { $0.text === split?.window?.firstResponder })
                ?? editable.first(where: { $0.text === active })
                ?? editable.first(where: { $0.id == "worktree" }) ?? editable.first
        }
        private func performHistory(redo: Bool) {
            guard let target = historyTarget() else { return }
            target.text.breakUndoCoalescing()
            target.text.window?.makeFirstResponder(target.text)
            active = target.text
            let manager = target.text.editingUndoManager
            if redo { if manager.canRedo { manager.redo() } }
            else { if manager.canUndo { manager.undo() } }
            scheduleCommandState()
        }
        func selectConflict(_ index: Int) {
            guard let pane = panes.first(where: { $0.id == "worktree" }) else { return }
            alignDisplay()
            let blocks = ConflictDraft.blocks(in: pane.text.string)
            guard blocks.indices.contains(index) else { return }
            model.resolver?.selectedBlock = index
            pane.text.setSelectedRange(NSRange(location: blocks[index].range.location, length: 0))
            pane.text.scrollRangeToVisible(NSRange(location: blocks[index].range.location, length: 0))
            pane.text.window?.makeFirstResponder(pane.text)
            active = pane.text
            updateConflictGutters()
        }
        func acceptConflict(_ side: ConflictDraft.Side, index: Int) {
            guard let pane = panes.first(where: { $0.id == "worktree" }), pane.text.isEditable,
                  let replacement = ConflictDraft.replacement(accepting: side, block: index, in: pane.text.string) else { return }
            pane.text.window?.makeFirstResponder(pane.text)
            active = pane.text
            pane.text.replaceAsUndoableEdit(replacement.text, range: replacement.range, actionName: resolverText("Resolve Conflict"))
            let blocks = ConflictDraft.blocks(in: pane.text.string)
            if !blocks.isEmpty { selectConflict(min(index, blocks.count - 1)) }
            else { model.resolver?.selectedBlock = 0; updateConflictGutters() }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let text = notification.object as? NSTextView, let paragraph = text.defaultParagraphStyle {
                text.typingAttributes[.paragraphStyle] = paragraph
            }
            guard !updating, let text = notification.object as? NSTextView,
                  let pane = panes.first(where: { $0.text === text }) else { return }
            reportCursor(in: pane)
            active = text
            redrawCurrentLines()
            if !navigatingChange { changeBandIndex = nil; panes.forEach { $0.text.navigationHighlightRect = nil; $0.gutter.navigationHighlightRect = nil } }
            scheduleCommandState()
            if model.resolver != nil, pane.id == "worktree", let index = ConflictDraft.blockIndex(atUTF16Offset: text.selectedRange().location, in: text.string) {
                model.resolver?.selectedBlock = index
                updateConflictGutters()
            }
        }
        private func reportCursor(in pane: Pane) {
            let source = pane.text.string as NSString
            let selection = pane.text.selectedRange()
            let location = min(selection.location, source.length)
            let line = pane.line(atUTF16: location)
            let lineStart = pane.gutter.starts[min(line, pane.gutter.starts.count - 1)]
            let selected = source.substring(with: NSIntersectionRange(selection, NSRange(location: 0, length: source.length)))
            let column = source.substring(with: NSRange(location: lineStart, length: max(0, location - lineStart))).count + 1
            let status = ComparisonCursorStatus(line: line + pane.gutter.firstLine, column: column, selectedCharacters: selected.count)
            // Toolbar navigation can run inside updateNSView, where delegate
            // callbacks are deliberately suppressed. Publish its final focused
            // selection after that update completes.
            DispatchQueue.main.async { [weak self] in self?.model.onCursorChange?(status) }
        }
        func updateConflictGutters() {
            for pane in panes {
                pane.gutter.conflictBlocks = model.resolver != nil && pane.id == "worktree" ? ConflictDraft.blocks(in: pane.text.string) : []
                pane.gutter.selectedConflict = model.resolver?.selectedBlock ?? 0
                pane.text.conflictBlocks = pane.gutter.conflictBlocks
                pane.text.selectedConflict = pane.gutter.selectedConflict
                pane.text.needsDisplay = true
                pane.gutter.needsDisplay = true
            }
            updateActionRails()
        }
        func updateActionRails() {
            for (position, pane) in panes.enumerated() {
                for (rail, neighbor, pointsRight) in [(pane.leftRail, position - 1, true), (pane.rightRail, position + 1, false)] {
                    rail.pointsRight = pointsRight
                    rail.color = pointsRight ? .systemBlue : .systemGreen
                    var entries: [ComparisonActionRail.Entry] = []
                    if pane.text.isEditable, panes.indices.contains(neighbor), !panes[neighbor].scroll.isHidden {
                        let source = panes[neighbor]
                        if model.resolver != nil, pane.id == "worktree" {
                            let side: ConflictDraft.Side? = source.id == "ours" ? .ours : source.id == "theirs" ? .theirs : nil
                            if let side {
                                entries = ConflictDraft.blocks(in: pane.text.string).enumerated().map { index, block in
                                    ComparisonActionRail.Entry(text: pane.text, range: block.range,
                                        title: resolverText(side == .ours ? "Use Ours" : "Use Theirs") + " — " + resolverText("Apply to the current conflict only"),
                                        action: { [weak self] in self?.acceptConflict(side, index: index) })
                                }
                            }
                        } else if model.resolver == nil {
                            let diff = TextLineDiff(source: source.text.string, target: pane.text.string)
                            entries = diff.blocks().map { block in
                                let geometry = block.targetLines.isEmpty ? source : pane
                                let lines = block.targetLines.isEmpty ? block.sourceLines : block.targetLines
                                let start = geometry.gutter.starts[min(lines.lowerBound, geometry.gutter.starts.count - 1)]
                                let end = lines.upperBound < geometry.gutter.starts.count ? geometry.gutter.starts[lines.upperBound] : geometry.text.string.utf16.count
                                return ComparisonActionRail.Entry(text: geometry.text, range: NSRange(location: start, length: max(0, end - start)),
                                    title: L10n.text("acceptBlock", table: "AdvancedDiff", arguments: [source.title.stringValue]),
                                    action: { [weak self, weak pane, weak source] in
                                        guard let self, let pane, let source, pane.text.isEditable else { return }
                                        let current = TextLineDiff(source: source.text.string, target: pane.text.string)
                                        guard current.blocks().contains(block) else { return }
                                        let value = TextLineDiff.accepting(block, source: source.text.string, target: pane.text.string)
                                        pane.text.window?.makeFirstResponder(pane.text)
                                        self.active = pane.text
                                        pane.text.replaceAsUndoableEdit(value)
                                        self.updateActionRails()
                                    })
                            }
                        }
                    }
                    rail.setEntries(entries)
                    // Reserve the slot for the pane relationship, including while
                    // saving and after the last change is accepted. Draft content
                    // must never change the text container's horizontal geometry.
                    let hasSource = panes.indices.contains(neighbor) && !panes[neighbor].scroll.isHidden
                    let acceptsSource = model.resolver == nil || (pane.id == "worktree" && hasSource && ["ours", "theirs"].contains(panes[neighbor].id))
                    let width = pane.preservesUndo && hasSource && acceptsSource ? ComparisonEditorMetrics.actionRailWidth : CGFloat(0)
                    let constraint = pointsRight ? pane.leftRailWidth! : pane.rightRailWidth!
                    if constraint.constant != width { constraint.constant = width; pane.needsLayout = true }
                }
            }
        }
        func undoManager(for view: NSTextView) -> UndoManager? { (view as? ComparisonTextView)?.editingUndoManager }
        func textDidBeginEditing(_ notification: Notification) { active = notification.object as? NSTextView; scheduleCommandState() }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView, let pane = panes.first(where: { $0.text === text }) else { return }
            active = text
            pane.gutter.setContent(text.string)
            pane.updateGutterWidth()
            pane.gutter.needsDisplay = true
            model.onEdit(pane.id, text.string)
            decorate()
            scheduleSearchStatus()
            updateConflictGutters()
            scheduleAlignment()
        }
        func scheduleAlignment() {
            guard !alignmentScheduled, !aligning else { return }
            alignmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.alignmentScheduled = false
                self.alignDisplay()
            }
        }
        private func currentAlignment(_ texts: [String], baseline: Int) -> ComparisonAlignment {
            if cachedAlignment == nil || texts != cachedAlignmentTexts || baseline != cachedAlignmentBaseline || cachedConflictMode != (model.resolver != nil) {
                cachedAlignmentTexts = texts; cachedAlignmentBaseline = baseline; cachedConflictMode = model.resolver != nil
                cachedAlignment = ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: model.resolver != nil ? ConflictDraft.blocks(in: texts[baseline]) : [])
                alignmentBuildCount += 1
            }
            return cachedAlignment!
        }
        private func difference(_ source: Pane, _ target: Pane) -> TextLineDiff {
            let texts = panes.map { $0.text.string }
            if diffTexts != texts { diffTexts = texts; cachedDiffs = [:] }
            let key = source.id + "→" + target.id
            if let cached = cachedDiffs[key] { return cached }
            let diff = TextLineDiff(source: source.text.string, target: target.text.string)
            cachedDiffs[key] = diff; return diff
        }
        func geometrySignature() -> String {
            panes.map { pane in
                "\(pane.id)|\(pane.scroll.contentView.bounds.width)|\(pane.scroll.contentView.bounds.height)|\(pane.text.textContainer?.containerSize.width ?? 0)|\(pane.leftRailWidth.constant)|\(pane.rightRailWidth.constant)"
            }.joined(separator: ";") + "|\(model.fontName)|\(model.fontSize)|\(model.tabWidth)|\(model.wrapLines)|\(model.resolver != nil)"
        }
        func alignDisplay() {
            guard !aligning, !panes.isEmpty else { return }
            let origins = panes.map { $0.scroll.contentView.bounds.origin }
            let sourceIndex = panes.firstIndex(where: { $0.id == scrollSourceID }) ?? panes.firstIndex(where: { $0.text === active }) ?? 0
            let sharedY = origins[sourceIndex].y
            aligning = true
            defer {
                aligning = false
                if geometrySignature() != alignmentGeometry { scheduleAlignment() }
                else { scrollToInitialChangeIfReady() }
            }
            // Apply rail/gutter constraints before measuring wrapped line fragments.
            split?.layoutSubtreeIfNeeded()
            panes.forEach { $0.prepareTextGeometry() }
            let texts = panes.map { $0.text.string }
            let geometry = geometrySignature()
            guard texts != alignedTexts || geometry != alignmentGeometry else { return }
            alignedTexts = texts
            alignmentGeometry = geometry
            let baseline = model.resolver != nil ? (panes.firstIndex(where: { $0.id == "worktree" }) ?? 0) : 0
            let alignment = currentAlignment(texts, baseline: baseline)
            for pane in panes {
                guard let storage = pane.text.textStorage else { continue }
                let paragraph = (pane.text.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
                pane.text.textContainerInset.height = ComparisonEditorMetrics.textInset.height
                if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
            }
            let heights = panes.map { pane -> [Double] in
                guard let layout = pane.text.layoutManager else { return [] }
                let fallback = Double(layout.defaultLineHeight(for: pane.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
                return pane.gutter.starts.indices.map { line in
                    let top = pane.y(forLine: line)
                    let bottom = line + 1 < pane.gutter.starts.count ? pane.y(forLine: line + 1) : layout.usedRect(for: pane.text.textContainer!).maxY + ComparisonEditorMetrics.textInset.height
                    return max(fallback, Double(bottom - top))
                }
            }
            let padding = alignment.padding(lineHeights: heights)
            var sharedHeight: CGFloat = 2 * ComparisonEditorMetrics.textInset.height
            for index in panes.indices {
                let naturalHeight = heights[index].reduce(0.0, +)
                let trailingPadding = padding.after[index].reduce(0.0, +)
                let documentHeight = CGFloat(naturalHeight + trailingPadding + 2.0 * padding.before[index]) + 2 * ComparisonEditorMetrics.textInset.height
                sharedHeight = max(sharedHeight, documentHeight)
            }
            for (index, pane) in panes.enumerated() {
                guard let storage = pane.text.textStorage else { continue }
                storage.beginEditing()
                for line in pane.gutter.starts.indices where padding.after[index][line] > 0 {
                    let start = pane.gutter.starts[line]
                    let end = line + 1 < pane.gutter.starts.count ? pane.gutter.starts[line + 1] : storage.length
                    guard end > start else { continue }
                    let paragraph = (pane.text.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = padding.after[index][line]
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: end - start))
                }
                storage.endEditing()
                pane.text.textContainerInset.height = ComparisonEditorMetrics.textInset.height + padding.before[index]
                if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
                pane.alignedHeight = sharedHeight
                pane.fitDocument()
                pane.gutter.needsDisplay = true
                pane.text.needsDisplay = true
                pane.leftRail.refresh()
                pane.rightRail.refresh()
            }
            refreshOverviews()
            // TextKit may shrink the document while measuring its unpadded layout. Restore
            // the viewport only after every pane has its final aligned document geometry.
            for (index, pane) in panes.enumerated() {
                let clip = pane.scroll.contentView
                let y = model.synchronizeScroll ? sharedY : origins[index].y
                clip.scroll(to: NSPoint(x: origins[index].x, y: min(max(0, y), max(0, pane.text.bounds.height - clip.bounds.height))))
                pane.scroll.reflectScrolledClipView(clip)
            }
        }
        /// Runs only after TextKit and every pane have their final shared geometry.
        /// Inspect the first actual range directly; next-change navigation intentionally
        /// skips the current caret and therefore cannot implement initial positioning.
        private func scrollToInitialChangeIfReady() {
            guard model.scrollsToFirstChangeOnOpen, !didScrollToInitialChange,
                  split?.window != nil, !panes.isEmpty,
                  panes.allSatisfy({ $0.scroll.isHidden || ($0.scroll.contentView.bounds.width > 0 && $0.scroll.contentView.bounds.height > 0) }) else { return }
            didScrollToInitialChange = true
            let candidates = panes.filter { !$0.scroll.isHidden }.compactMap { pane -> (Pane, NSRange, CGFloat)? in
                guard let range = changedRanges[pane.id]?.min(by: { $0.location < $1.location }) else { return nil }
                let line = pane.gutter.starts.lastIndex(where: { $0 <= range.location }) ?? 0
                return (pane, range, pane.y(forLine: line))
            }
            guard let first = candidates.min(by: { $0.2 < $1.2 }) else { return }
            // Keep a small amount of context and scroll all columns to the same
            // aligned row even when subsequent scrolling is independent.
            let y = max(0, first.2 - 24)
            scrolling = true
            for pane in panes where !pane.scroll.isHidden {
                let clip = pane.scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(y, max(0, pane.text.bounds.height - clip.bounds.height))))
                pane.scroll.reflectScrolledClipView(clip)
            }
            scrolling = false
            first.0.text.setSelectedRange(NSRange(location: first.1.location, length: 0))
            active = first.0.text
            scrollSourceID = first.0.id
        }
        @objc func didScroll(_ notification: Notification) {
            panes.forEach { $0.gutter.needsDisplay = true; $0.leftRail.refresh(); $0.rightRail.refresh() }
            guard !aligning, !updating, !scrolling, let clip = notification.object as? NSClipView else { return }
            guard let source = panes.first(where: { $0.scroll.contentView === clip }) else { return }
            scrollSourceID = source.id
            guard model.synchronizeScroll || !model.wrapLines else { return }
            scrolling = true
            defer { scrolling = false }
            for pane in panes where pane !== source {
                let target = pane.scroll.contentView
                let y = model.synchronizeScroll ? clip.bounds.minY : target.bounds.minY
                let x = model.wrapLines ? target.bounds.minX : min(clip.bounds.minX, max(0, pane.text.bounds.width - target.bounds.width))
                target.scroll(to: NSPoint(x: x, y: min(y, max(0, pane.text.bounds.height - target.bounds.height))))
                pane.scroll.reflectScrolledClipView(target)
            }
        }
        func takeBlock(fromLeft: Bool) -> Bool {
            guard let target = historyTarget(), target.text.isEditable,
                  let targetIndex = panes.firstIndex(where: { $0 === target }) else { return false }
            let candidates = panes.enumerated().filter { $0.offset != targetIndex && !$0.element.scroll.isHidden }
            let source = fromLeft ? candidates.last(where: { $0.offset < targetIndex })?.element : candidates.first(where: { $0.offset > targetIndex })?.element
            guard let source else { return false }
            if model.resolver != nil {
                guard let index = model.resolver?.selectedBlock,
                      ConflictDraft.blocks(in: target.text.string).indices.contains(index), ["ours", "theirs"].contains(source.id) else { return false }
                acceptConflict(source.id == "ours" ? .ours : .theirs, index: index)
                return true
            }
            let line = target.line(atUTF16: target.text.selectedRange().location)
            let title = L10n.text("acceptBlock", table: "AdvancedDiff", arguments: [source.title.stringValue])
            guard let action = acceptActions(for: target, line: line).first(where: { $0.0 == title }) else { return false }
            action.1(); return true
        }
        fileprivate func acceptActions(for target: Pane, line: Int) -> [(String, () -> Void)] {
            guard target.text.isEditable else { return [] }
            if model.resolver != nil, target.id == "worktree" {
                let blocks = ConflictDraft.blocks(in: target.text.string)
                if let index = blocks.firstIndex(where: { ($0.startLine - 1)..<$0.endLine ~= line }) {
                    var choices: [(String, ConflictDraft.Side)] = [("Use Ours", .ours), ("Use Theirs", .theirs), ("Ours → Theirs", .oursThenTheirs), ("Theirs → Ours", .theirsThenOurs)]
                    if blocks[index].base != nil { choices.append(("Use Base", .base)) }
                    return choices.map { title, side in (resolverText(title), { [weak self] in self?.acceptConflict(side, index: index) }) }
                }
                return []
            }
            return panes.filter { $0 !== target && !$0.scroll.isHidden }.compactMap { source in
                let diff = difference(source, target)
                guard let block = diff.blocks().first(where: { $0.targetLines.contains(line) || ($0.targetLines.isEmpty && ($0.targetLines.lowerBound == line || $0.targetLines.lowerBound == line + 1)) }) else { return nil }
                let title = L10n.text("acceptBlock", table: "AdvancedDiff", arguments: [source.title.stringValue])
                return (title, { [weak target] in
                    guard let target else { return }
                    let value = TextLineDiff.accepting(block, source: source.text.string, target: target.text.string)
                    target.text.window?.makeFirstResponder(target.text)
                    target.text.replaceAsUndoableEdit(value)
                })
            }
        }
        func decorate() {
            guard let baseline = panes.first else { return }
            lineDiffs = [:]
            var lineChanges: [String: Set<Int>] = [:]
            var lineColors: [String: [Int: NSColor]] = [:]
            for pane in panes.dropFirst() {
                let diff = difference(baseline, pane)
                lineDiffs[pane.id] = diff
                lineChanges[baseline.id, default: []].formUnion(diff.sourceChangedLines)
                lineChanges[pane.id] = diff.targetChangedLines
                for block in diff.blocks() {
                    let sourceColor = EditorPreferences.color(block.targetLines.isEmpty ? model.deletionColor : model.modificationColor, fallback: block.targetLines.isEmpty ? .systemRed : .systemOrange)
                    let targetColor = EditorPreferences.color(block.sourceLines.isEmpty ? model.additionColor : model.modificationColor, fallback: block.sourceLines.isEmpty ? .systemGreen : .systemOrange)
                    for line in block.sourceLines { lineColors[baseline.id, default: [:]][line] = sourceColor }
                    for line in block.targetLines { lineColors[pane.id, default: [:]][line] = targetColor }
                }
            }
            var signs: [String: [Int: Bool]] = [:]
            for pane in panes {
                for line in lineChanges[pane.id] ?? [] {
                    signs[pane.id, default: [:]][line] = pane !== baseline
                }
            }
            for (source, target) in zip(panes, panes.dropFirst()) {
                let diff = difference(source, target)
                for line in diff.sourceChangedLines { signs[source.id, default: [:]][line] = false }
                for line in diff.targetChangedLines { signs[target.id, default: [:]][line] = true }
            }
            if model.resolver != nil, let resultIndex = panes.firstIndex(where: { $0.id == "worktree" }) {
                let result = panes[resultIndex]
                let blocks = ConflictDraft.blocks(in: result.text.string)
                let alignment = currentAlignment(panes.map { $0.text.string }, baseline: resultIndex)
                for band in alignment.bands where blocks.contains(where: { (($0.startLine - 1)..<$0.endLine).overlaps(band[resultIndex]) }) {
                    for (index, pane) in panes.enumerated() {
                        if pane.id == "ours" || pane.id == "theirs" {
                            for line in band[index] { signs[pane.id, default: [:]][line] = pane.id == "theirs" }
                        }
                    }
                }
                for block in blocks {
                    for line in (block.startLine - 1)..<block.endLine { signs[result.id]?[line] = nil }
                    for (section, value) in ConflictVisualStyle.sections(block, in: result.text.string).enumerated() {
                        let range = value.0
                        let addition = section == 1
                        for (line, start) in result.gutter.starts.enumerated() where NSLocationInRange(start, range) {
                            signs[result.id, default: [:]][line] = addition
                        }
                    }
                }
            }
            for pane in panes {
                pane.gutter.lineSigns = signs[pane.id] ?? [:]
                guard let layout = pane.text.layoutManager else { continue }
                let content = pane.text.string as NSString
                let dark = model.colorScheme == .dark
                let whole = NSRange(location: 0, length: content.length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
                let tokens: [SyntaxToken]
                if !model.syntaxHighlight { tokens = [] }
                else if let cached = syntaxCache[pane.id], cached.0 == pane.text.string, cached.1 == model.languagePath { tokens = cached.2 }
                else { tokens = SyntaxHighlighter.tokens(in: pane.text.string, path: model.languagePath); syntaxCache[pane.id] = (pane.text.string, model.languagePath, tokens) }
                for token in tokens {
                    let color: NSColor
                    switch token.kind { case .keyword: color = .systemPurple; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor; case .number: color = .systemBlue }
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }
                let conflictBlocks = pane.id == "worktree" ? ConflictDraft.blocks(in: pane.text.string) : []
                let conflictLines = Set(conflictBlocks.flatMap { ($0.startLine - 1)..<$0.endLine })
                let conflictColor = EditorPreferences.color(model.deletionColor, fallback: .systemRed)
                let changedLines = (lineChanges[pane.id] ?? []).union(conflictLines).union(pane.gutter.lineSigns.keys)
                pane.gutter.lineBackgrounds = [:]
                pane.gutter.changedLines = changedLines
                pane.gutter.needsDisplay = true
                var offset = 0
                var changes: [NSRange] = []
                let lines = pane.text.string.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let length = (line as NSString).length
                    let displayedLength = min(length + 1, content.length - offset)
                    if changedLines.contains(index) {
                        if let last = changes.last, NSMaxRange(last) == offset {
                            changes[changes.count - 1].length += displayedLength
                        } else { changes.append(NSRange(location: offset, length: displayedLength)) }
                        if displayedLength > 0 && !(model.resolver != nil && pane.id == "worktree" && conflictLines.contains(index)) {
                            var color = conflictLines.contains(index) ? conflictColor : (lineColors[pane.id]?[index] ?? EditorPreferences.color(model.modificationColor, fallback: .systemOrange))
                            if (model.resolver == nil || pane.id != "worktree"), let addition = pane.gutter.lineSigns[index] {
                                color = EditorPreferences.color(addition ? model.additionColor : model.deletionColor, fallback: addition ? .systemGreen : .systemRed)
                            }
                            pane.gutter.lineBackgrounds[index] = DiffVisualStyle.lineBackground(color, dark: dark)
                            layout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.lineBackground(color, dark: dark), forCharacterRange: NSRange(location: offset, length: displayedLength))
                        }
                    }
                    offset += length + 1
                }
                if let diff = lineDiffs[pane.id] {
                    for removedLine in diff.sourceChangedLines {
                        let targetLine = diff.sourceToTarget[removedLine]
                        let location = pane.gutter.starts[min(targetLine, pane.gutter.starts.count - 1)]
                        if !changes.contains(where: { NSLocationInRange(location, $0) || $0.location == location }) {
                            changes.append(NSRange(location: location, length: 0))
                        }
                    }
                }
                if model.characterDiff, let diff = lineDiffs[pane.id] {
                    let sourceLines = baseline.text.string.components(separatedBy: "\n")
                    for block in diff.blocks() {
                        for (a, b) in zip(block.sourceLines, block.targetLines) {
                            let chars = CharacterDiff(source: sourceLines[a], target: lines[b])
                            for range in chars.target where range.length > 0 {
                                let characterRange = NSRange(location: pane.gutter.starts[b] + range.location, length: range.length)
                                var color = EditorPreferences.color(model.modificationColor, fallback: .systemOrange)
                                if (model.resolver == nil || pane.id != "worktree"), let addition = pane.gutter.lineSigns[b] {
                                    color = EditorPreferences.color(addition ? model.additionColor : model.deletionColor, fallback: addition ? .systemGreen : .systemRed)
                                }
                                if model.resolver != nil, pane.id == "worktree", conflictLines.contains(b) {
                                    color = conflictBlocks.flatMap { ConflictVisualStyle.sections($0, in: pane.text.string) }
                                        .first(where: { NSLocationInRange(characterRange.location, $0.0) })?.1 ?? .systemOrange
                                } else if conflictLines.contains(b) { color = conflictColor }
                                layout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(color, dark: dark), forCharacterRange: characterRange)
                            }
                            if let sourceLayout = baseline.text.layoutManager {
                                for range in chars.source where range.length > 0 {
                                    let sourceColor: NSColor
                                    if (model.resolver == nil || baseline.id != "worktree"), let addition = baseline.gutter.lineSigns[a] {
                                        sourceColor = EditorPreferences.color(addition ? model.additionColor : model.deletionColor, fallback: addition ? .systemGreen : .systemRed)
                                    } else { sourceColor = EditorPreferences.color(model.modificationColor, fallback: .systemOrange) }
                                    sourceLayout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(sourceColor, dark: dark), forCharacterRange: NSRange(location: baseline.gutter.starts[a] + range.location, length: range.length))
                                }
                            }
                        }
                    }
                }
                changedRanges[pane.id] = changes.sorted { $0.location < $1.location }
                if case .success(let matches) = ComparisonSearch.matches(in: pane.text.string, options: model.effectiveSearch) {
                    for match in matches {
                        if match.length > 0 { layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: match) }
                        for (line, start) in pane.gutter.starts.enumerated() {
                            let end = line + 1 < pane.gutter.starts.count ? pane.gutter.starts[line + 1] : content.length + 1
                            if (start..<end).contains(match.location) || (match.length > 0 && NSIntersectionRange(NSRange(location: start, length: end - start), match).length > 0) {
                                pane.gutter.lineBackgrounds[line] = NSColor.systemYellow.withAlphaComponent(0.45)
                            }
                        }
                    }
                }
            }
        }
        var focusedText: NSTextView? {
            guard let responder = split?.window?.firstResponder as? NSTextView, panes.contains(where: { $0.text === responder }) else { return nil }
            return responder
        }
        @objc private func windowFocusChanged(_ notification: Notification) { redrawCurrentLines() }
        private func redrawCurrentLines() {
            for pane in panes { pane.text.needsDisplay = true; pane.gutter.needsDisplay = true }
        }
        private func scrollAll(to y: CGFloat) {
            scrolling = true
            defer { scrolling = false }
            for pane in panes where !pane.scroll.isHidden {
                let clip = pane.scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), max(0, pane.text.bounds.height - clip.bounds.height))))
                pane.scroll.reflectScrolledClipView(clip)
                pane.gutter.needsDisplay = true; pane.leftRail.refresh(); pane.rightRail.refresh()
            }
        }
        private func revealLine(_ pane: Pane, line: Int) {
            let line = min(line, pane.gutter.starts.count - 1)
            pane.text.setSelectedRange(NSRange(location: pane.gutter.starts[line], length: 0))
            scrollAll(to: max(0, pane.y(forLine: line) - 24))
            pane.text.window?.makeFirstResponder(pane.text); active = pane.text
            reportCursor(in: pane)
        }
        private func refreshOverviews() {
            guard !panes.isEmpty else { return }
            let texts = panes.map { $0.text.string }
            let baseline = model.resolver != nil ? panes.firstIndex(where: { $0.id == "worktree" }) ?? 0 : 0
            if texts != navigationTexts || baseline != navigationBaseline {
                navigationTexts = texts; navigationBaseline = baseline
                navigationBands = ComparisonChangeNavigation(texts: texts, baseline: baseline, conflicts: model.resolver != nil ? ConflictDraft.blocks(in: texts[baseline]) : [], cachedAlignment: currentAlignment(texts, baseline: baseline)).bands
                changeBandIndex = nil
            }
            let height = Double(max(1, panes.map { $0.text.bounds.height }.max() ?? 1))
            for (paneIndex, pane) in panes.enumerated() {
                pane.scroll.overview.usesLocalViewport = model.overviewMarkers == nil
                pane.scroll.overview.markers = model.overviewMarkers ?? navigationBands.enumerated().map { index, band in
                    let top = panes.indices.map { band[$0].lowerBound >= panes[$0].gutter.starts.count ? panes[$0].text.bounds.height : panes[$0].y(forLine: band[$0].lowerBound) }.min() ?? 0
                    let bottom = panes.indices.map { band[$0].upperBound >= panes[$0].gutter.starts.count ? panes[$0].text.bounds.height : panes[$0].y(forLine: band[$0].upperBound) }.max() ?? top
                    let kind: ComparisonOverviewMarker.Kind = band[baseline].isEmpty ? .addition : band.enumerated().contains(where: { $0.offset != baseline && $0.element.isEmpty }) ? .deletion : .modification
                    return ComparisonOverviewMarker(lower: min(1, Double(top) / height), upper: min(1, Double(max(top + 1, bottom)) / height), kind: kind, index: index)
                }
                pane.scroll.overview.onNavigate = { [weak self] fraction in
                    guard let self else { return }
                    if let action = self.model.onOverviewNavigate { action(fraction); return }
                    let y = CGFloat(fraction) * CGFloat(height)
                    for target in self.panes {
                        let line = fraction == 1 ? target.gutter.starts.count - 1 : target.line(atY: y)
                        target.text.setSelectedRange(NSRange(location: target.gutter.starts[max(0, line)], length: 0))
                    }
                    self.scrollAll(to: y - pane.scroll.contentView.bounds.height / 2)
                    self.active = pane.text
                    self.reportCursor(in: pane)
                }
                pane.scroll.overview.onSelect = { [weak self] index in
                    guard let self else { return }
                    if let action = self.model.onOverviewJump { action(index) }
                    else { self.selectChangeBand(index, focus: paneIndex) }
                }
            }
        }
        func navigateChange(forward: Bool) {
            guard !panes.isEmpty else { return }
            let texts = panes.map { $0.text.string }
            let baseline = model.resolver != nil ? panes.firstIndex(where: { $0.id == "worktree" }) ?? 0 : 0
            if texts != navigationTexts || baseline != navigationBaseline {
                navigationBaseline = baseline
                navigationTexts = texts
                navigationBands = ComparisonChangeNavigation(texts: texts, baseline: baseline, conflicts: model.resolver != nil ? ConflictDraft.blocks(in: texts[baseline]) : [], cachedAlignment: currentAlignment(texts, baseline: baseline)).bands
                changeBandIndex = nil
            }
            let groups = navigationBands
            guard !groups.isEmpty else { return }
            let focus = panes.firstIndex(where: { $0.text === focusedText || $0.text === active }) ?? baseline
            let line = panes[focus].line(atUTF16: panes[focus].text.selectedRange().location)
            let index: Int
            if let current = changeBandIndex { index = (current + (forward ? 1 : groups.count - 1)) % groups.count }
            else { index = forward ? groups.firstIndex(where: { $0[focus].lowerBound > line }) ?? 0 : groups.lastIndex(where: { $0[focus].lowerBound < line }) ?? groups.count - 1 }
            selectChangeBand(index, focus: focus)
        }
        private func selectChangeBand(_ index: Int, focus: Int) {
            guard navigationBands.indices.contains(index) else { return }
            navigatingChange = true
            defer { navigatingChange = false }
            let band = navigationBands[index]
            let top = panes.indices.compactMap { i -> CGFloat? in band[i].isEmpty ? nil : panes[i].y(forLine: band[i].lowerBound) }.min() ?? 0
            let bottom = panes.indices.map { i in band[i].upperBound >= panes[i].gutter.starts.count ? panes[i].text.bounds.height : panes[i].y(forLine: band[i].upperBound) }.max() ?? top
            for i in panes.indices {
                let highlight = NSRect(x: 0, y: top, width: panes[i].text.bounds.width, height: max(18, bottom - top))
                panes[i].text.navigationHighlightRect = highlight
                panes[i].gutter.navigationHighlightRect = highlight
                let pane = panes[i], start = band[i].lowerBound < panes[i].gutter.starts.count ? pane.gutter.starts[band[i].lowerBound] : pane.text.string.utf16.count
                let end = band[i].upperBound < pane.gutter.starts.count ? pane.gutter.starts[band[i].upperBound] : pane.text.string.utf16.count
                pane.text.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            }
            changeBandIndex = index
            scrollAll(to: top - 24)
            panes[focus].text.window?.makeFirstResponder(panes[focus].text); active = panes[focus].text
            reportCursor(in: panes[focus])
        }
        func navigate(forward: Bool) {
            guard let text = panes.first(where: { $0.id == "worktree" && !$0.scroll.isHidden })?.text ?? focusedText ?? active ?? panes.first?.text,
                  let pane = panes.first(where: { $0.text === text }),
                  case .success(let matches) = ComparisonSearch.matches(in: text.string, options: model.effectiveSearch), !matches.isEmpty else { return }
            let current = searchIndices[pane.id]
            let index = current.map { ($0 + (forward ? 1 : matches.count - 1)) % matches.count } ?? (forward ? 0 : matches.count - 1)
            searchIndices[pane.id] = index
            scheduleSearchStatus()
            text.setSelectedRange(matches[index])
            scrollAll(to: pane.y(forLine: pane.line(atUTF16: matches[index].location)) - 24)
            active = text
            reportCursor(in: pane)
        }
    }
}

final class ComparisonSplitView: NSSplitView {
    var onAttach: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { onAttach?() } }
    private var distributeEqually = true
    private var distributionGeneration = 0
    private var lastDistributedWidth: CGFloat = -1
    func resetDistribution() {
        distributionGeneration += 1
        let generation = distributionGeneration
        distributeEqually = true
        needsLayout = true
        adjustSubviews()
        layoutSubtreeIfNeeded()
        equalizeDividers()
        // A reused pane retains its former frame until AppKit's arranged-subview layout completes.
        // Repeat once after that pass, only for this rebuild, without affecting later user drags.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.distributionGeneration == generation else { return }
            self.layoutSubtreeIfNeeded()
            self.equalizeDividers()
        }
    }
    private func equalizeDividers() {
        guard bounds.width > 0, !subviews.isEmpty else { return }
        distributeEqually = false
        lastDistributedWidth = bounds.width
        let width = max(1, (bounds.width - CGFloat(subviews.count - 1) * dividerThickness) / CGFloat(subviews.count))
        for index in (0..<max(0, subviews.count - 1)).reversed() {
            setPosition(CGFloat(index + 1) * width + CGFloat(index) * dividerThickness, ofDividerAt: index)
        }
        subviews.forEach { $0.needsLayout = true }
    }
    override func layout() {
        super.layout()
        // AppKit's divider constraints can overwrite frames assigned by
        // resizeSubviews. Update the actual divider positions after that layout
        // pass when the split width changes; manual drags at the same width remain.
        if distributeEqually || bounds.width != lastDistributedWidth { equalizeDividers() }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !subviews.isEmpty else { return }
        if oldSize.width != bounds.width { distributeEqually = true }
        let available = max(1, bounds.width - CGFloat(subviews.count - 1) * dividerThickness)
        var x: CGFloat = 0
        for view in subviews {
            let width = available / CGFloat(subviews.count)
            view.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + dividerThickness
        }
    }
}

/// Paints behind text using TextKit geometry, including wrapped and empty lines.
private enum ConflictVisualStyle {
    static func fill(_ color: NSColor, emphasis: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            color.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? emphasis + 0.08 : emphasis)
        }
    }
    static func rect(_ range: NSRange, in text: NSTextView, layout: NSLayoutManager) -> NSRect? {
        guard range.length > 0, range.location < text.string.utf16.count, layout.numberOfGlyphs > 0 else { return nil }
        let first = layout.glyphIndexForCharacter(at: range.location)
        let last = layout.glyphIndexForCharacter(at: min(NSMaxRange(range) - 1, text.string.utf16.count - 1))
        let top = layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY
        let bottom = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY
        return NSRect(x: 0, y: top + text.textContainerInset.height, width: text.bounds.width, height: bottom - top)
    }
    static func sections(_ block: ConflictDraft.Block, in string: String) -> [(NSRange, NSColor)] {
        let source = string as NSString
        let opening = source.lineRange(for: NSRange(location: block.range.location, length: 0))
        let oursStart = NSMaxRange(opening)
        var dividerStart = oursStart + block.ours.utf16.count
        if let base = block.base {
            let baseMarker = source.lineRange(for: NSRange(location: dividerStart, length: 0))
            dividerStart = NSMaxRange(baseMarker) + base.utf16.count
        }
        guard dividerStart < source.length else { return [] }
        let divider = source.lineRange(for: NSRange(location: dividerStart, length: 0))
        return [(NSRange(location: oursStart, length: block.ours.utf16.count), .systemBlue),
                (NSRange(location: NSMaxRange(divider), length: block.theirs.utf16.count), .systemPurple)]
    }
}

final class ComparisonTextView: UndoableComparisonTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ComparisonCaret.draw(in: self, dirtyRect: dirtyRect)
    }
    override var shouldDrawInsertionPoint: Bool {
        isEditable ? super.shouldDrawInsertionPoint : ComparisonCaret.shouldDraw(in: self)
    }
    var navigationHighlightRect: NSRect? { didSet { needsDisplay = true } }
    var highlightCurrentLine = true
    var focusChanged: (() -> Void)?
    var currentLineFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); updateInsertionPointStateAndRestartTimer(true); needsDisplay = true; focusChanged?(); return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; DispatchQueue.main.async { [weak self] in self?.focusChanged?() }; return accepted }
    var conflictBlocks: [ConflictDraft.Block] = []
    var selectedConflict = 0
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let layoutManager {
            for (index, block) in conflictBlocks.enumerated() {
                guard let blockRect = ConflictVisualStyle.rect(block.range, in: self, layout: layoutManager), blockRect.intersects(rect) else { continue }
                let selected = index == selectedConflict
                ConflictVisualStyle.fill(.systemOrange, emphasis: selected ? 0.20 : 0.11).setFill()
                blockRect.intersection(rect).fill()
                // The marker and content offsets are real UTF-16 positions; drawing never changes the draft.
                for section in ConflictVisualStyle.sections(block, in: string) {
                    guard let sectionRect = ConflictVisualStyle.rect(section.0, in: self, layout: layoutManager) else { continue }
                    ConflictVisualStyle.fill(section.1, emphasis: selected ? 0.22 : 0.15).setFill()
                    sectionRect.intersection(rect).fill()
                }
                NSColor.systemOrange.withAlphaComponent(selected ? 0.95 : 0.50).setFill()
                NSRect(x: visibleRect.minX, y: blockRect.minY, width: selected ? 4 : 2, height: blockRect.height).intersection(rect).fill()
                if selected {
                    NSColor.systemOrange.withAlphaComponent(0.80).setStroke()
                    let border = NSBezierPath(rect: blockRect.insetBy(dx: 0.5, dy: 0.5))
                    border.lineWidth = 1
                    border.stroke()
                }
            }
        }
        if var highlight = navigationHighlightRect {
            highlight.size.width = bounds.width
            NSColor.systemOrange.withAlphaComponent(0.22).setFill(); highlight.intersection(rect).fill()
            NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
            NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        guard highlightCurrentLine, let layoutManager else { return }
        let source = string as NSString
        let character = min(selectedRange().location, source.length)
        var line: NSRect
        if layoutManager.numberOfGlyphs == 0 || (character == source.length && source.length > 0 && source.character(at: source.length - 1) == 10) {
            line = layoutManager.extraLineFragmentRect
            if line.height == 0 { line.size.height = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) }
        } else {
            let paragraph = source.lineRange(for: NSRange(location: min(character, max(0, source.length - 1)), length: min(selectedRange().length, max(0, source.length - character))))
            let first = layoutManager.glyphIndexForCharacter(at: paragraph.location)
            let last = layoutManager.glyphIndexForCharacter(at: max(paragraph.location, NSMaxRange(paragraph) - 1))
            let top = layoutManager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
            let bottom = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            line = NSRect(x: 0, y: top.minY, width: bounds.width, height: bottom.maxY - top.minY)
        }
        line.origin.y += textContainerInset.height
        line.origin.x = 0; line.size.width = bounds.width
        NSColor.selectedTextBackgroundColor.withAlphaComponent(currentLineFocused ? 0.24 : 0.12).setFill()
        line.intersection(rect).fill()
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isEditable { updateInsertionPointStateAndRestartTimer(true) }
        needsDisplay = true
    }
    var blockMenu: ((Int) -> [(String, () -> Void)])?
    private var actions: [() -> Void] = []
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let layoutManager, let textContainer else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height), in: textContainer)
        let character = layoutManager.numberOfGlyphs == 0 ? 0 : layoutManager.characterIndexForGlyph(at: min(glyph, layoutManager.numberOfGlyphs - 1))
        let line = string.utf16.prefix(character).filter { $0 == 10 }.count
        let choices = blockMenu?(line) ?? []
        actions = choices.map { $0.1 }
        if !choices.isEmpty { menu.addItem(.separator()) }
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.0, action: #selector(acceptBlock(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; menu.addItem(item)
        }
        return menu
    }
    @objc private func acceptBlock(_ sender: NSMenuItem) { if actions.indices.contains(sender.tag) { actions[sender.tag]() } }
}

private final class Pane: NSView {
    let id: String
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let scroll = ComparisonOverviewScrollView()
    let text = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: nil)
    let gutter = LineGutter()
    let leftRail = ComparisonActionRail()
    let rightRail = ComparisonActionRail()
    var leftRailWidth: NSLayoutConstraint!
    var rightRailWidth: NSLayoutConstraint!
    var gutterWidth: NSLayoutConstraint!
    var alignedHeight: CGFloat = 0
    var preservesUndo = false
    var geometryChanged: (() -> Void)?
    private var lastViewport = NSSize.zero
    private var wrapped: Bool?
    init(column: ComparisonEditorColumn) {
        id = column.id
        super.init(frame: .zero)
        clipsToBounds = true
        gutter.clipsToBounds = true
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        text.string = column.text
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.usesFindBar = true
        text.textContainerInset = ComparisonEditorMetrics.textInset
        text.textContainer?.lineFragmentPadding = ComparisonEditorMetrics.lineFragmentPadding
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Assigning the initial text can resize a detached NSTextView while its
        // parent coordinates are unflipped, leaving a negative frame origin.
        // Every decoration and synchronized scroll uses document-local y values.
        text.setFrameOrigin(.zero)
        scroll.documentView = text
        gutter.text = text
        gutter.scroll = scroll
        leftRail.scroll = scroll
        rightRail.scroll = scroll
        leftRail.clipsToBounds = true
        rightRail.clipsToBounds = true
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, detail, scroll, leftRail, rightRail, gutter, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.preferredWidth)
        leftRailWidth = leftRail.widthAnchor.constraint(equalToConstant: 0)
        rightRailWidth = rightRail.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), title.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -4), title.topAnchor.constraint(equalTo: topAnchor, constant: 4), title.heightAnchor.constraint(equalToConstant: 20),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), detail.centerYAnchor.constraint(equalTo: title.centerYAnchor), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
            leftRail.leadingAnchor.constraint(equalTo: leadingAnchor), leftRail.topAnchor.constraint(equalTo: gutter.topAnchor), leftRail.bottomAnchor.constraint(equalTo: bottomAnchor), leftRailWidth,
            rightRail.trailingAnchor.constraint(equalTo: trailingAnchor), rightRail.topAnchor.constraint(equalTo: gutter.topAnchor), rightRail.bottomAnchor.constraint(equalTo: bottomAnchor), rightRailWidth,
            gutter.leadingAnchor.constraint(equalTo: leftRail.trailingAnchor), gutter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4), gutter.bottomAnchor.constraint(equalTo: bottomAnchor), gutterWidth,
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: rightRail.leadingAnchor), scroll.topAnchor.constraint(equalTo: gutter.topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20)
        ])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: bounds.height - ComparisonEditorMetrics.headerHeight, width: bounds.width, height: ComparisonEditorMetrics.headerHeight).intersection(dirtyRect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - ComparisonEditorMetrics.headerHeight, width: bounds.width, height: 1).intersection(dirtyRect).fill()
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateGutterWidth() {
        let width = gutter.preferredWidth
        if gutterWidth.constant != width { gutterWidth.constant = width; needsLayout = true }
    }
    func line(atUTF16 location: Int) -> Int { max(0, (gutter.starts.lastIndex(where: { $0 <= location }) ?? 0)) }
    func line(atY y: CGFloat) -> Int {
        guard let layout = text.layoutManager, let container = text.textContainer, layout.numberOfGlyphs > 0 else { return 0 }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, y - text.textContainerInset.height)), in: container)
        let character = layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1))
        var lower = 0
        var upper = gutter.starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if gutter.starts[middle] <= character { lower = middle + 1 } else { upper = middle }
        }
        return max(lower - 1, 0)
    }
    func y(forLine line: Int) -> CGFloat {
        guard let layout = text.layoutManager else { return 0 }
        let character = gutter.starts[min(max(0, line), gutter.starts.count - 1)]
        if character >= (text.string as NSString).length { return layout.extraLineFragmentRect.minY + text.textContainerInset.height }
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + text.textContainerInset.height
    }
    /// Own the container width explicitly. TextKit's width tracking and sizeToFit
    /// otherwise compete: one uses the viewport, the other adds the horizontal inset.
    func prepareTextGeometry() {
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 0 else { return }
        text.textContainer?.widthTracksTextView = false
        if wrapped == true {
            text.setFrameSize(NSSize(width: viewport.width, height: max(text.frame.height, viewport.height)))
            let width = max(1, viewport.width - 2 * text.textContainerInset.width)
            if text.textContainer?.containerSize.width != width { text.textContainer?.containerSize.width = width }
        } else {
            text.textContainer?.containerSize.width = CGFloat.greatestFiniteMagnitude
            text.setFrameSize(NSSize(width: max(text.frame.width, viewport.width), height: max(text.frame.height, viewport.height)))
        }
    }
    func fitDocument() {
        let viewport = scroll.contentView.bounds.size
        text.sizeToFit()
        // Keep wrapped document width fixed after sizeToFit, including after adding
        // paragraph padding or changing an arrow rail width.
        let width = wrapped == true ? viewport.width : max(text.frame.width, viewport.width)
        text.setFrameSize(NSSize(width: width, height: max(text.frame.height, viewport.height, alignedHeight)))
        text.setFrameOrigin(.zero)
    }
    override func layout() {
        super.layout()
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 0 else { return }
        if viewport != lastViewport { lastViewport = viewport; geometryChanged?() }
        prepareTextGeometry()
        fitDocument()
    }
    func wrap(_ enabled: Bool) {
        guard wrapped != enabled else { return }
        wrapped = enabled
        text.isHorizontallyResizable = !enabled
        text.textContainer?.widthTracksTextView = false
        text.autoresizingMask = enabled ? [.width] : []
        prepareTextGeometry()
    }
}

private final class LineGutter: NSView {
    var navigationHighlightRect: NSRect? { didSet { needsDisplay = true } }
    weak var text: NSTextView?
    weak var scroll: NSScrollView?
    private var content = ""
    fileprivate var starts = [0]
    var lineBackgrounds: [Int: NSColor] = [:]
    var changedLines = Set<Int>()
    var firstLine = 1
    var showsLineNumbers = true
    var conflictBlocks: [ConflictDraft.Block] = []
    var selectedConflict = 0
    var lineSigns: [Int: Bool] = [:]
    var additionColor: NSColor = .systemGreen
    var deletionColor: NSColor = .systemRed
    private var codeFont: NSFont { text?.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular) }
    var signWidth: CGFloat { ComparisonEditorMetrics.signWidth(codeFont: codeFont) }
    var preferredWidth: CGFloat {
        ComparisonEditorMetrics.gutterWidth(firstLine: firstLine, lineCount: starts.count, codeFont: codeFont, showsNumbers: showsLineNumbers)
    }
    func setContent(_ value: String) {
        guard content != value else { return }
        content = value
        starts = [0]
        for (index, unit) in value.utf16.enumerated() where unit == 10 { starts.append(index + 1) }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.blended(withFraction: 0.45, of: .windowBackgroundColor)?.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let text, let scroll, let layout = text.layoutManager, let container = text.textContainer else { return }
        let visible = scroll.contentView.bounds
        for (index, block) in conflictBlocks.enumerated() {
            guard block.range.location < text.string.utf16.count else { continue }
            if let blockRect = ConflictVisualStyle.rect(block.range, in: text, layout: layout) {
                let gutterRect = NSRect(x: 0, y: blockRect.minY - visible.minY, width: bounds.width, height: blockRect.height)
                ConflictVisualStyle.fill(.systemOrange, emphasis: index == selectedConflict ? 0.20 : 0.11).setFill()
                gutterRect.intersection(bounds).fill()
                for section in ConflictVisualStyle.sections(block, in: text.string) {
                    guard let sectionRect = ConflictVisualStyle.rect(section.0, in: text, layout: layout) else { continue }
                    ConflictVisualStyle.fill(section.1, emphasis: index == selectedConflict ? 0.22 : 0.15).setFill()
                    NSRect(x: 0, y: sectionRect.minY - visible.minY, width: bounds.width, height: sectionRect.height).intersection(bounds).fill()
                }
                NSColor.systemOrange.withAlphaComponent(index == selectedConflict ? 0.95 : 0.5).setFill()
                NSRect(x: bounds.width - 3, y: gutterRect.minY, width: 3, height: gutterRect.height).intersection(bounds).fill()
            }

        }

        if let highlight = navigationHighlightRect {
            let area = NSRect(x: 0, y: highlight.minY - visible.minY, width: bounds.width, height: highlight.height)
            NSColor.systemOrange.withAlphaComponent(0.22).setFill(); area.intersection(bounds).fill()
            NSColor.systemOrange.withAlphaComponent(0.85).setStroke(); NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        let inset = text.textContainerInset
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: visible.minY - inset.height, width: visible.width, height: visible.height), in: container)
        let content = text.string as NSString
        let codeFont = text.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let numberFont = DiffVisualStyle.lineNumberFont(codeSize: codeFont.pointSize)
        let baselineOffset = codeFont.ascender - numberFont.ascender
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: DiffVisualStyle.lineNumberColor]
        guard layout.numberOfGlyphs > 0 else {
            let y = inset.height - visible.minY
            var numberAttributes = attrs
            if let native = text as? ComparisonTextView, native.highlightCurrentLine {
                let focused = native.currentLineFocused
                NSColor.selectedTextBackgroundColor.withAlphaComponent(focused ? 0.24 : 0.12).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: layout.defaultLineHeight(for: codeFont)).intersection(bounds).fill()
                numberAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize, weight: focused ? .semibold : .medium)
                numberAttributes[.foregroundColor] = focused ? NSColor.labelColor : DiffVisualStyle.lineNumberColor
            }
            if showsLineNumbers {
                let label = "\(firstLine)" as NSString
                label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: numberAttributes).width - signWidth - 3, y: y + baselineOffset), withAttributes: numberAttributes)
            }
            return
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            var lower = 0
            var upper = self.starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if self.starts[middle] <= character { lower = middle + 1 } else { upper = middle }
            }
            let line = max(lower, 1) - 1
            let y = rect.minY + inset.height - visible.minY
            if let color = self.lineBackgrounds[line] {
                color.setFill()
                NSRect(x: 0, y: y, width: self.bounds.width, height: rect.height).intersection(self.bounds).fill()
            }
            let selectedLine = self.starts.lastIndex(where: { $0 <= text.selectedRange().location }) ?? 0
            let selectionEnd = text.selectedRange().length > 0 ? NSMaxRange(text.selectedRange()) - 1 : text.selectedRange().location
            let lastSelectedLine = self.starts.lastIndex(where: { $0 <= selectionEnd }) ?? selectedLine
            let current = (selectedLine...lastSelectedLine).contains(line) && (text as? ComparisonTextView)?.highlightCurrentLine == true
            let focused = (text as? ComparisonTextView)?.currentLineFocused == true
            if current {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(focused ? 0.24 : 0.12).setFill()
                NSRect(x: 0, y: y, width: self.bounds.width, height: rect.height).intersection(self.bounds).fill()
            }
            if character == 0 || (character <= content.length && content.character(at: character - 1) == 10) {
                if self.showsLineNumbers {
                    let label = "\(self.firstLine + line)" as NSString
                    var numberAttributes = attrs
                    if current {
                        numberAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize, weight: focused ? .semibold : .medium)
                        numberAttributes[.foregroundColor] = focused ? NSColor.labelColor : DiffVisualStyle.lineNumberColor
                    }
                    label.draw(at: NSPoint(x: self.bounds.width - label.size(withAttributes: numberAttributes).width - self.signWidth - 3, y: y + baselineOffset), withAttributes: numberAttributes)
                }
                if let addition = self.lineSigns[line] {
                    let label = (addition ? "+" : "−") as NSString
                    let signFont = NSFont.monospacedSystemFont(ofSize: codeFont.pointSize, weight: .semibold)
                    let attributes: [NSAttributedString.Key: Any] = [.font: signFont, .foregroundColor: addition ? self.additionColor : self.deletionColor]
                    let x = self.bounds.width - self.signWidth + (self.signWidth - label.size(withAttributes: attributes).width) / 2
                    label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                }
            }
        }
        if content.length == 0 || content.character(at: content.length - 1) == 10 {
            let rect = layout.extraLineFragmentRect
            let y = rect.minY + inset.height - visible.minY
            if y >= -20 && y <= bounds.height {
                var numberAttributes = attrs
                if text.selectedRange().location == content.length, let native = text as? ComparisonTextView, native.highlightCurrentLine {
                    let focused = native.currentLineFocused
                    NSColor.selectedTextBackgroundColor.withAlphaComponent(focused ? 0.24 : 0.12).setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: rect.height).intersection(bounds).fill()
                    numberAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize, weight: focused ? .semibold : .medium)
                    numberAttributes[.foregroundColor] = focused ? NSColor.labelColor : DiffVisualStyle.lineNumberColor
                }
                if showsLineNumbers {
                    let label = "\(firstLine + starts.count - 1)" as NSString
                    label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: numberAttributes).width - signWidth - 3, y: y + baselineOffset), withAttributes: numberAttributes)
                }
            }
        }
    }
}
