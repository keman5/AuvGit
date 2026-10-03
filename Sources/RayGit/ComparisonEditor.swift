import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

struct ComparisonEditorColumn: Identifiable {
    let id: String
    let title: String
    let text: String
    let isEditable: Bool
    let message: String?
}

struct ComparisonEditor: NSViewRepresentable {
    let columns: [ComparisonEditorColumn]
    let wrapLines: Bool
    let showLineNumbers: Bool
    let synchronizeScroll: Bool
    let search: String
    let navigation: Int
    let changeNavigation: Int
    let onEdit: (String, String) -> Void
    var languagePath: String = ""

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
        var scrolling = false
        var updating = false
        var lastNavigation: Int
        var lastChangeNavigation: Int
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
            model = value
            if rebuild, let split {
                NotificationCenter.default.removeObserver(self)
                let focusedID = panes.first(where: { $0.text === active || $0.text === split.window?.firstResponder })?.id
                split.subviews.forEach { $0.removeFromSuperview() }
                let oldPanes = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
                panes = value.columns.map { column in
                    let pane = oldPanes[column.id] ?? Pane(column: column)
                    pane.text.delegate = self
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
                (split as? ComparisonSplitView)?.distributeEqually = true
                split.needsLayout = true
                split.adjustSubviews()
            }
            var changed = rebuild || previousSearch != value.search || previousLanguage != value.languagePath
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
                pane.gutterWidth.constant = value.showLineNumbers ? 58 : 0
                pane.wrap(value.wrapLines)
                pane.gutter.setContent(column.text)
                pane.gutter.needsDisplay = true
                pane.needsLayout = true
            }
            if changed { decorate() }
            if lastChangeNavigation != value.changeNavigation {
                navigateChange(forward: value.changeNavigation > lastChangeNavigation)
                lastChangeNavigation = value.changeNavigation
            }
            if lastNavigation != value.navigation {
                navigate(forward: value.navigation > lastNavigation)
                lastNavigation = value.navigation
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
        }
        @objc func didScroll(_ notification: Notification) {
            panes.forEach { $0.gutter.needsDisplay = true }
            guard model.synchronizeScroll, !scrolling, let clip = notification.object as? NSClipView else { return }
            scrolling = true
            defer { scrolling = false }
            guard let source = panes.first(where: { $0.scroll.contentView === clip }) else { return }
            let sourceLine = source.line(atY: clip.bounds.minY)
            let baseLine = lineDiffs[source.id].map { $0.targetToSource[min(sourceLine, $0.targetToSource.count - 1)] } ?? sourceLine
            for pane in panes where pane !== source {
                let targetLine = lineDiffs[pane.id].map { $0.sourceToTarget[min(baseLine, $0.sourceToTarget.count - 1)] } ?? baseLine
                let target = pane.scroll.contentView
                let y = pane.y(forLine: targetLine)
                target.scroll(to: NSPoint(x: target.bounds.origin.x, y: min(y, max(0, pane.text.bounds.height - target.bounds.height))))
                pane.scroll.reflectScrolledClipView(target)
            }
        }
        fileprivate func acceptActions(for target: Pane, line: Int) -> [(String, () -> Void)] {
            guard target.text.isEditable else { return [] }
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
            for pane in panes.dropFirst() {
                let diff = TextLineDiff(source: baseline.text.string, target: pane.text.string)
                lineDiffs[pane.id] = diff
                lineChanges[baseline.id, default: []].formUnion(diff.sourceChangedLines)
                lineChanges[pane.id] = diff.targetChangedLines
            }
            for pane in panes {
                guard let layout = pane.text.layoutManager else { continue }
                let content = pane.text.string as NSString
                let whole = NSRange(location: 0, length: content.length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
                for token in SyntaxHighlighter.tokens(in: pane.text.string, path: model.languagePath) {
                    let color: NSColor
                    switch token.kind { case .keyword: color = .systemPurple; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor; case .number: color = .systemBlue }
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
                }
                let changedLines = lineChanges[pane.id] ?? []
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
                        if displayedLength > 0 {
                            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.13), forCharacterRange: NSRange(location: offset, length: displayedLength))
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
                if let diff = lineDiffs[pane.id] {
                    let sourceLines = baseline.text.string.components(separatedBy: "\n")
                    for block in diff.blocks() {
                        for (a, b) in zip(block.sourceLines, block.targetLines) {
                            let chars = CharacterDiff(source: sourceLines[a], target: lines[b])
                            for range in chars.target where range.length > 0 {
                                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.32), forCharacterRange: NSRange(location: pane.gutter.starts[b] + range.location, length: range.length))
                            }
                            if let sourceLayout = baseline.text.layoutManager {
                                for range in chars.source where range.length > 0 {
                                    sourceLayout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.32), forCharacterRange: NSRange(location: baseline.gutter.starts[a] + range.location, length: range.length))
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
    var distributeEqually = true
    override func layout() {
        super.layout()
        guard distributeEqually, bounds.width > 0, !subviews.isEmpty else { return }
        distributeEqually = false
        let width = max(1, (bounds.width - CGFloat(subviews.count - 1) * dividerThickness) / CGFloat(subviews.count))
        for (index, view) in subviews.enumerated() {
            view.frame = NSRect(x: CGFloat(index) * (width + dividerThickness), y: 0, width: width, height: bounds.height)
            view.needsLayout = true
        }
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

private final class ComparisonTextView: NSTextView {
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
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
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
        if wrapped == true {
            text.textContainer?.containerSize.width = viewport.width
            text.setFrameSize(NSSize(width: viewport.width, height: max(text.frame.height, viewport.height)))
        } else {
            text.setFrameSize(NSSize(width: max(text.frame.width, viewport.width), height: max(text.frame.height, viewport.height)))
        }
        text.sizeToFit()
        text.setFrameSize(NSSize(width: max(text.frame.width, viewport.width), height: max(text.frame.height, viewport.height)))
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
        let visible = scroll.contentView.bounds
        let inset = text.textContainerInset
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: visible.minY - inset.height, width: visible.width, height: visible.height), in: container)
        let content = text.string as NSString
        guard layout.numberOfGlyphs > 0 else {
            ("1" as NSString).draw(at: NSPoint(x: bounds.width - 17, y: inset.height - visible.minY), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            if character == 0 || (character <= content.length && content.character(at: character - 1) == 10) {
                var lower = 0
                var upper = self.starts.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if self.starts[middle] <= character { lower = middle + 1 } else { upper = middle }
                }
                let label = "\(max(lower, 1))" as NSString
                var lineAttrs = attrs
                if self.changedLines.contains(max(lower, 1) - 1) { lineAttrs[.foregroundColor] = NSColor.systemOrange }
                label.draw(at: NSPoint(x: self.bounds.width - label.size(withAttributes: attrs).width - 10, y: rect.minY + inset.height - visible.minY), withAttributes: lineAttrs)
            }
        }
        if content.length > 0, content.character(at: content.length - 1) == 10 {
            let rect = layout.extraLineFragmentRect
            let y = rect.minY + inset.height - visible.minY
            if y >= -20 && y <= bounds.height {
                let label = "\(starts.count)" as NSString
                var lineAttrs = attrs
                if changedLines.contains(starts.count - 1) { lineAttrs[.foregroundColor] = NSColor.systemOrange }
                label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attrs).width - 10, y: y), withAttributes: lineAttrs)
            }
        }
    }
}
