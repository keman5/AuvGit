import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSplitView {
        let split = ComparisonSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        context.coordinator.split = split
        context.coordinator.update(self)
        return split
    }
    func updateNSView(_ nsView: NSSplitView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ComparisonEditor
        weak var split: NSSplitView?
        fileprivate var panes: [Pane] = []
        var alignedTexts: [String] = []
        var alignmentGeometry = ""
        var scrollSourceID: String?
        var alignmentScheduled = false
        var aligning = false
        var scrolling = false
        var updating = false
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
            let previousSearch = model.search
            let previousLanguage = model.languagePath
            let settings = "\(value.fontName)|\(value.fontSize)|\(value.tabWidth)|\(value.syntaxHighlight)|\(value.characterDiff)|\(value.showWhitespace)|\(value.highlightCurrentLine)|\(value.additionColor)|\(value.deletionColor)|\(value.modificationColor)|\(value.colorScheme)"
            let preferencesChanged = preferenceSignature != settings
            if preferencesChanged || rebuild { alignmentGeometry = "" }
            preferenceSignature = settings
            model = value
            value.resolver?.select = { [weak self] index in self?.selectConflict(index) }
            value.resolver?.accept = { [weak self] side, index in self?.acceptConflict(side, index: index) }
            if rebuild, let split {
                NotificationCenter.default.removeObserver(self)
                let focusedID = panes.first(where: { $0.text === active || $0.text === split.window?.firstResponder })?.id
                split.subviews.forEach { $0.removeFromSuperview() }
                let oldPanes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
                panes = value.columns.map { column in
                    let pane = oldPanes[column.id] ?? Pane(column: column)
                    pane.text.delegate = self
                    pane.geometryChanged = { [weak self] in self?.scheduleAlignment() }
                    pane.text.blockMenu = { [weak self, weak pane] line in
                        guard let self, let pane else { return [] }
                        return self.acceptActions(for: pane, line: line)
                    }
                    pane.gutter.acceptConflict = { [weak self] side, index in self?.acceptConflict(side, index: index) }
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
            var changed = preferencesChanged || rebuild || previousSearch != value.search || previousLanguage != value.languagePath
            for (pane, column) in zip(panes, value.columns) {
                pane.title.stringValue = column.title
                pane.text.isEditable = column.isEditable && column.message == nil
                // Keep undo enabled during save/loading; changing this property clears native history.
                if !pane.text.allowsUndo { pane.text.allowsUndo = true }
                pane.message.stringValue = column.message ?? ""
                pane.message.isHidden = column.message == nil
                pane.scroll.isHidden = column.message != nil
                if pane.text.string != column.text {
                    let selected = pane.text.selectedRange()
                    if column.isEditable {
                        pane.text.insertText(column.text, replacementRange: NSRange(location: 0, length: (pane.text.string as NSString).length))
                    } else { pane.text.string = column.text }
                    let length = (column.text as NSString).length
                    pane.text.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
                    changed = true
                }
                pane.gutter.isHidden = !value.showLineNumbers
                pane.gutterWidth.constant = value.resolver != nil && pane.id == "worktree" ? (value.showLineNumbers ? 88 : 40) : (value.showLineNumbers ? 58 : 0)
                pane.gutter.isHidden = !value.showLineNumbers && !(value.resolver != nil && pane.id == "worktree")
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
                pane.gutter.showsLineNumbers = value.showLineNumbers
                pane.gutter.firstLine = column.firstLine
                pane.gutter.setContent(column.text)
                pane.gutter.needsDisplay = true
                pane.needsLayout = true
            }
            if changed { decorate() }
            updateConflictGutters()
            scheduleAlignment()
            if lastChangeNavigation != value.changeNavigation || lastNavigation != value.navigation { alignDisplay() }
            if lastChangeNavigation != value.changeNavigation {
                navigateChange(forward: value.changeNavigation > lastChangeNavigation)
                lastChangeNavigation = value.changeNavigation
            }
            if lastNavigation != value.navigation {
                navigate(forward: value.navigation > lastNavigation)
                lastNavigation = value.navigation
            }
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
            pane.text.breakUndoCoalescing()
            pane.text.insertText(replacement.text, replacementRange: replacement.range)
            pane.text.breakUndoCoalescing()
            pane.text.undoManager?.setActionName(resolverText("Resolve Conflict"))
            let blocks = ConflictDraft.blocks(in: pane.text.string)
            if !blocks.isEmpty { selectConflict(min(index, blocks.count - 1)) }
            else { model.resolver?.selectedBlock = 0; updateConflictGutters() }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let text = notification.object as? NSTextView, let paragraph = text.defaultParagraphStyle {
                text.typingAttributes[.paragraphStyle] = paragraph
            }
            guard !updating, model.resolver != nil, let text = notification.object as? NSTextView,
                  let pane = panes.first(where: { $0.text === text }) else { return }
            active = text
            if pane.id == "worktree", let index = ConflictDraft.blockIndex(atUTF16Offset: text.selectedRange().location, in: text.string) {
                model.resolver?.selectedBlock = index
                updateConflictGutters()
            }
        }
        func updateConflictGutters() {
            for pane in panes {
                pane.gutter.conflictBlocks = model.resolver != nil && pane.id == "worktree" ? ConflictDraft.blocks(in: pane.text.string) : []
                pane.gutter.canAcceptConflict = pane.text.isEditable
                pane.gutter.selectedConflict = model.resolver?.selectedBlock ?? 0
                pane.text.conflictBlocks = pane.gutter.conflictBlocks
                pane.text.selectedConflict = pane.gutter.selectedConflict
                pane.text.needsDisplay = true
                pane.gutter.needsDisplay = true
            }
        }
        func undoManager(for view: NSTextView) -> UndoManager? { (view as? ComparisonTextView)?.editingUndoManager }
        func textDidBeginEditing(_ notification: Notification) { active = notification.object as? NSTextView }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView, let pane = panes.first(where: { $0.text === text }) else { return }
            active = text
            pane.gutter.setContent(text.string)
            pane.gutter.needsDisplay = true
            model.onEdit(pane.id, text.string)
            decorate()
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
        func alignDisplay() {
            guard !aligning, !panes.isEmpty else { return }
            let texts = panes.map { $0.text.string }
            let geometry = panes.map { pane in
                "\(pane.id)|\(pane.scroll.contentSize.width)|\(pane.scroll.contentSize.height)|\(pane.text.textContainer?.containerSize.width ?? 0)"
            }.joined(separator: ";") + "|\(model.fontName)|\(model.fontSize)|\(model.tabWidth)|\(model.wrapLines)|\(model.resolver != nil)"
            guard texts != alignedTexts || geometry != alignmentGeometry else { return }
            alignedTexts = texts
            alignmentGeometry = geometry
            let origins = panes.map { $0.scroll.contentView.bounds.origin }
            let sourceIndex = panes.firstIndex(where: { $0.id == scrollSourceID }) ?? panes.firstIndex(where: { $0.text === active }) ?? 0
            let sharedY = origins[sourceIndex].y
            aligning = true
            defer { aligning = false }
            let baseline = model.resolver != nil ? (panes.firstIndex(where: { $0.id == "worktree" }) ?? 0) : 0
            let alignment = ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: model.resolver != nil ? ConflictDraft.blocks(in: texts[baseline]) : [])
            for pane in panes {
                guard let storage = pane.text.textStorage else { continue }
                let paragraph = (pane.text.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
                pane.text.textContainerInset.height = 8
                if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
            }
            let heights = panes.map { pane -> [Double] in
                guard let layout = pane.text.layoutManager else { return [] }
                let fallback = Double(layout.defaultLineHeight(for: pane.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
                return pane.gutter.starts.indices.map { line in
                    let top = pane.y(forLine: line)
                    let bottom = line + 1 < pane.gutter.starts.count ? pane.y(forLine: line + 1) : layout.usedRect(for: pane.text.textContainer!).maxY + 8
                    return max(fallback, Double(bottom - top))
                }
            }
            let padding = alignment.padding(lineHeights: heights)
            var sharedHeight: CGFloat = 16
            for index in panes.indices {
                let naturalHeight = heights[index].reduce(0.0, +)
                let trailingPadding = padding.after[index].reduce(0.0, +)
                let documentHeight = CGFloat(naturalHeight + trailingPadding + 2.0 * padding.before[index]) + 16
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
                pane.text.textContainerInset.height = 8 + padding.before[index]
                if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
                pane.alignedHeight = sharedHeight
                pane.text.sizeToFit()
                pane.text.setFrameSize(NSSize(width: max(pane.text.frame.width, pane.scroll.contentSize.width), height: max(pane.scroll.contentSize.height, pane.alignedHeight)))
                pane.gutter.needsDisplay = true
                pane.text.needsDisplay = true
            }
            // TextKit may shrink the document while measuring its unpadded layout. Restore
            // the viewport only after every pane has its final aligned document geometry.
            for (index, pane) in panes.enumerated() {
                let clip = pane.scroll.contentView
                let y = model.synchronizeScroll ? sharedY : origins[index].y
                clip.scroll(to: NSPoint(x: origins[index].x, y: min(max(0, y), max(0, pane.text.bounds.height - clip.bounds.height))))
                pane.scroll.reflectScrolledClipView(clip)
            }
        }
        @objc func didScroll(_ notification: Notification) {
            panes.forEach { $0.gutter.needsDisplay = true }
            guard !aligning, !updating, !scrolling, let clip = notification.object as? NSClipView else { return }
            guard let source = panes.first(where: { $0.scroll.contentView === clip }) else { return }
            scrollSourceID = source.id
            guard model.synchronizeScroll else { return }
            scrolling = true
            defer { scrolling = false }
            for pane in panes where pane !== source {
                let target = pane.scroll.contentView
                let y = clip.bounds.minY
                target.scroll(to: NSPoint(x: target.bounds.origin.x, y: min(y, max(0, pane.text.bounds.height - target.bounds.height))))
                pane.scroll.reflectScrolledClipView(target)
            }
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
                let diff = TextLineDiff(source: source.text.string, target: target.text.string)
                guard let block = diff.blocks().first(where: { $0.targetLines.contains(line) || ($0.targetLines.isEmpty && ($0.targetLines.lowerBound == line || $0.targetLines.lowerBound == line + 1)) }) else { return nil }
                let title = L10n.text("acceptBlock", table: "AdvancedDiff", arguments: [source.title.stringValue])
                return (title, { [weak target] in
                    guard let target else { return }
                    let value = TextLineDiff.accepting(block, source: source.text.string, target: target.text.string)
                    target.text.insertText(value, replacementRange: NSRange(location: 0, length: target.text.string.utf16.count))
                })
            }
        }
        func decorate() {
            guard let baseline = panes.first else { return }
            lineDiffs = [:]
            var lineChanges: [String: Set<Int>] = [:]
            var lineColors: [String: [Int: NSColor]] = [:]
            for pane in panes.dropFirst() {
                let diff = TextLineDiff(source: baseline.text.string, target: pane.text.string)
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
            for pane in panes {
                guard let layout = pane.text.layoutManager else { continue }
                let content = pane.text.string as NSString
                let dark = model.colorScheme == .dark
                let whole = NSRange(location: 0, length: content.length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
                for token in (model.syntaxHighlight ? SyntaxHighlighter.tokens(in: pane.text.string, path: model.languagePath) : []) {
                    let color: NSColor
                    switch token.kind { case .keyword: color = .systemPurple; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor; case .number: color = .systemBlue }
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }
                let conflictBlocks = pane.id == "worktree" ? ConflictDraft.blocks(in: pane.text.string) : []
                let conflictLines = Set(conflictBlocks.flatMap { ($0.startLine - 1)..<$0.endLine })
                let conflictColor = EditorPreferences.color(model.deletionColor, fallback: .systemRed)
                let changedLines = (lineChanges[pane.id] ?? []).union(conflictLines)
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
                            layout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.lineBackground(conflictLines.contains(index) ? conflictColor : (lineColors[pane.id]?[index] ?? EditorPreferences.color(model.modificationColor, fallback: .systemOrange)), dark: dark), forCharacterRange: NSRange(location: offset, length: displayedLength))
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
                                if model.resolver != nil, pane.id == "worktree", conflictLines.contains(b) {
                                    color = conflictBlocks.flatMap { ConflictVisualStyle.sections($0, in: pane.text.string) }
                                        .first(where: { NSLocationInRange(characterRange.location, $0.0) })?.1 ?? .systemOrange
                                } else if conflictLines.contains(b) { color = conflictColor }
                                layout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(color, dark: dark), forCharacterRange: characterRange)
                            }
                            if let sourceLayout = baseline.text.layoutManager {
                                for range in chars.source where range.length > 0 {
                                    sourceLayout.addTemporaryAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(EditorPreferences.color(model.modificationColor, fallback: .systemOrange), dark: dark), forCharacterRange: NSRange(location: baseline.gutter.starts[a] + range.location, length: range.length))
                                }
                            }
                        }
                    }
                }
                changedRanges[pane.id] = changes.sorted { $0.location < $1.location }
                guard !model.search.isEmpty else { continue }
                var range = whole
                while range.length > 0 {
                    let match = content.range(of: model.search, options: [.caseInsensitive], range: range)
                    if match.location == NSNotFound { break }
                    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: match)
                    let next = NSMaxRange(match)
                    range = NSRange(location: next, length: content.length - next)
                }
            }
        }
        var focusedText: NSTextView? {
            guard let responder = split?.window?.firstResponder as? NSTextView, panes.contains(where: { $0.text === responder }) else { return nil }
            return responder
        }
        func navigateChange(forward: Bool) {
            guard let text = focusedText ?? active ?? panes.first(where: { $0.text.isEditable })?.text ?? panes.first?.text,
                  let pane = panes.first(where: { $0.text === text }),
                  let ranges = changedRanges[pane.id], !ranges.isEmpty else { return }
            let location = text.selectedRange().location
            let target = forward ? (ranges.first(where: { $0.location > location }) ?? ranges[0]) : (ranges.last(where: { $0.location < location }) ?? ranges[ranges.count - 1])
            text.setSelectedRange(target)
            text.scrollRangeToVisible(target)
            text.window?.makeFirstResponder(text)
            active = text
        }
        func navigate(forward: Bool) {
            guard !model.search.isEmpty, let text = focusedText ?? active ?? panes.first(where: { $0.text.isEditable })?.text ?? panes.first?.text else { return }
            let content = text.string as NSString
            let selected = text.selectedRange()
            let start = min(forward ? NSMaxRange(selected) : selected.location, content.length)
            let options: NSString.CompareOptions = forward ? [.caseInsensitive] : [.caseInsensitive, .backwards]
            let range = forward ? NSRange(location: start, length: content.length - start) : NSRange(location: 0, length: start)
            var found = content.range(of: model.search, options: options, range: range)
            if found.location == NSNotFound { found = content.range(of: model.search, options: options) }
            if found.location != NSNotFound {
                text.setSelectedRange(found)
                text.scrollRangeToVisible(found)
                text.window?.makeFirstResponder(text)
                active = text
            }
        }
    }
}

private final class ComparisonSplitView: NSSplitView {
    private var distributeEqually = true
    private var distributionGeneration = 0
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
        let width = max(1, (bounds.width - CGFloat(subviews.count - 1) * dividerThickness) / CGFloat(subviews.count))
        for index in (0..<max(0, subviews.count - 1)).reversed() {
            setPosition(CGFloat(index + 1) * width + CGFloat(index) * dividerThickness, ofDividerAt: index)
        }
        subviews.forEach { $0.needsLayout = true }
    }
    override func layout() {
        super.layout()
        if distributeEqually { equalizeDividers() }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !subviews.isEmpty else { return }
        let previous = subviews.reduce(CGFloat(0)) { $0 + $1.frame.width }
        let available = max(1, bounds.width - CGFloat(subviews.count - 1) * dividerThickness)
        var x: CGFloat = 0
        for view in subviews {
            let ratio = previous > 0 && !distributeEqually ? view.frame.width / previous : 1 / CGFloat(subviews.count)
            let width = available * ratio
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

private final class ComparisonTextView: NSTextView {
    var highlightCurrentLine = true
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
        guard highlightCurrentLine, window?.firstResponder === self, let layoutManager, layoutManager.numberOfGlyphs > 0 else { return }
        let character = min(selectedRange().location, max(0, string.utf16.count - 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        line.origin.y += textContainerInset.height
        line.origin.x = 0; line.size.width = bounds.width
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
        line.intersection(rect).fill()
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }
    private let history = UndoManager()
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
    var editingUndoManager: UndoManager { history }
    override var undoManager: UndoManager? { history }
}

private final class Pane: NSView {
    let id: String
    let title = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let scroll = NSScrollView()
    let text = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    let gutter = LineGutter()
    var gutterWidth: NSLayoutConstraint!
    var alignedHeight: CGFloat = 0
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
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        gutter.text = text
        gutter.scroll = scroll
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        for view in [title, scroll, gutter, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 58)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), title.topAnchor.constraint(equalTo: topAnchor, constant: 8), title.heightAnchor.constraint(equalToConstant: 20),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor), gutter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), gutter.bottomAnchor.constraint(equalTo: bottomAnchor), gutterWidth,
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: gutter.topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
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
    override func layout() {
        super.layout()
        let viewport = scroll.contentSize
        guard viewport.width > 0 else { return }
        if viewport != lastViewport { lastViewport = viewport; geometryChanged?() }
        if wrapped == true {
            text.textContainer?.containerSize.width = viewport.width
            text.setFrameSize(NSSize(width: viewport.width, height: max(text.frame.height, viewport.height)))
        } else {
            text.setFrameSize(NSSize(width: max(text.frame.width, viewport.width), height: max(text.frame.height, viewport.height)))
        }
        text.sizeToFit()
        text.setFrameSize(NSSize(width: max(text.frame.width, viewport.width), height: max(text.frame.height, viewport.height, alignedHeight)))
    }
    func wrap(_ enabled: Bool) {
        guard wrapped != enabled else { return }
        wrapped = enabled
        text.isHorizontallyResizable = !enabled
        text.textContainer?.widthTracksTextView = enabled
        text.textContainer?.containerSize = NSSize(width: enabled ? max(scroll.contentSize.width, 1) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = enabled ? [.width] : []
        if enabled { text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height)) }
    }
}

private final class LineGutter: NSView {
    weak var text: NSTextView?
    weak var scroll: NSScrollView?
    private var content = ""
    fileprivate var starts = [0]
    var changedLines = Set<Int>()
    var firstLine = 1
    var showsLineNumbers = true
    var conflictBlocks: [ConflictDraft.Block] = []
    var selectedConflict = 0
    var canAcceptConflict = true
    var acceptConflict: ((ConflictDraft.Side, Int) -> Void)?
    private var conflictButtons: [(NSRect, Int, ConflictDraft.Side)] = []
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let button = conflictButtons.first(where: { $0.0.contains(point) }) else { return "" }
        return resolverText(button.2 == .ours ? "Use Ours" : "Use Theirs") + " — " + resolverText("Apply to the current conflict only")
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = conflictButtons.first(where: { $0.0.contains(point) }) { acceptConflict?(button.2, button.1) }
        else { super.mouseDown(with: event) }
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
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let text, let scroll, let layout = text.layoutManager, let container = text.textContainer else { return }
        conflictButtons = []
        removeAllToolTips()
        let visible = scroll.contentView.bounds
        for (index, block) in conflictBlocks.enumerated() {
            guard block.range.location < text.string.utf16.count else { continue }
            let glyph = layout.glyphIndexForCharacter(at: block.range.location)
            let row = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = row.minY + text.textContainerInset.height - visible.minY
            if let blockRect = ConflictVisualStyle.rect(block.range, in: text, layout: layout) {
                let gutterRect = NSRect(x: 0, y: blockRect.minY - visible.minY, width: bounds.width, height: blockRect.height)
                ConflictVisualStyle.fill(.systemOrange, emphasis: index == selectedConflict ? 0.20 : 0.11).setFill()
                gutterRect.intersection(bounds).fill()
                NSColor.systemOrange.withAlphaComponent(index == selectedConflict ? 0.95 : 0.5).setFill()
                NSRect(x: bounds.width - 3, y: gutterRect.minY, width: 3, height: gutterRect.height).intersection(bounds).fill()
            }
            guard canAcceptConflict, y > -20, y < bounds.height else { continue }
            for (x, label, side) in [(CGFloat(1), "→", ConflictDraft.Side.ours), (CGFloat(20), "←", ConflictDraft.Side.theirs)] {
                let rect = NSRect(x: x, y: y, width: 18, height: max(16, row.height))
                (side == .ours ? NSColor.systemBlue : NSColor.systemPurple).withAlphaComponent(index == selectedConflict ? 0.32 : 0.18).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                (label as NSString).draw(at: NSPoint(x: x + 3, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.labelColor])
                conflictButtons.append((rect, index, side))
                addToolTip(rect, owner: self, userData: nil)
            }
        }

        guard showsLineNumbers else { return }
        let inset = text.textContainerInset
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: visible.minY - inset.height, width: visible.width, height: visible.height), in: container)
        let content = text.string as NSString
        let codeFont = text.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let numberFont = DiffVisualStyle.lineNumberFont(codeSize: codeFont.pointSize)
        let baselineOffset = codeFont.ascender - numberFont.ascender
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: DiffVisualStyle.lineNumberColor]
        guard layout.numberOfGlyphs > 0 else {
            let label = "\(firstLine)" as NSString
            label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attrs).width - 10, y: inset.height - visible.minY + baselineOffset), withAttributes: attrs)
            return
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            if character == 0 || (character <= content.length && content.character(at: character - 1) == 10) {
                var lower = 0
                var upper = self.starts.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if self.starts[middle] <= character { lower = middle + 1 } else { upper = middle }
                }
                let label = "\(self.firstLine + max(lower, 1) - 1)" as NSString
                label.draw(at: NSPoint(x: self.bounds.width - label.size(withAttributes: attrs).width - 10, y: rect.minY + inset.height - visible.minY + baselineOffset), withAttributes: attrs)
            }
        }
        if content.length > 0, content.character(at: content.length - 1) == 10 {
            let rect = layout.extraLineFragmentRect
            let y = rect.minY + inset.height - visible.minY
            if y >= -20 && y <= bounds.height {
                let label = "\(firstLine + starts.count - 1)" as NSString
                label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attrs).width - 10, y: y + baselineOffset), withAttributes: attrs)
            }
        }
    }
}
