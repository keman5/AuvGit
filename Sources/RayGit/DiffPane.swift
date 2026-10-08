import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

private func diffText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Detail", arguments: arguments)
}

private func diffControlText(_ key: String) -> String {
    L10n.text(key, table: "DiffControls")
}

struct DiffPane: View {
    let text: String
    let title: String
    let isLoading: Bool
    var extraMenuItems: AnyView? = nil
    var preview: FileComparisonSnapshot? = nil
    @AppStorage("editor.defaultDiffSideBySide") private var sideBySide = true
    var leftRevisionTitle: String? = nil
    var rightRevisionTitle: String? = nil
    var onOpenEditableComparison: ((ComparisonSearchOptions, String) -> Void)? = nil
    var forceCompact = false
    var standaloneShortcuts = false
    var initialSearchOptions = ComparisonSearchOptions()
    var initialReplacement = ""
    @State private var hunk = 0
    @AppStorage("editor.wrapLines") private var wraps = false
    @AppStorage("editor.showLineNumbers") private var lineNumbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronized = true
    @AppStorage("editor.fontSize") private var fontSize: Double = 12
    @State private var searchOptions = ComparisonSearchOptions()
    @State private var replacement = ""
    @AppStorage("diff.compact") private var compact = false
    @State private var searchStep = 0
    @State private var matchCount = 0
    @State private var matchIndex = 0
    @State private var searchError: String?
    @State private var openedDocumentIdentity = ""
    @State private var showSearch = false
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var parseCache = ComparisonPatchCache()
    private var parsed: ParsedDiff { parseCache.value(for: text) }
    var body: some View {
        let diff = parsed
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    titleLabel.frame(minWidth: 120, alignment: .leading)
                    Spacer(minLength: 0)
                    hunkControls(diff)
                    displayControls
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        titleLabel
                        Spacer(minLength: 0)
                        hunkControls(diff)
                    }
                    HStack(spacing: 8) {
                        displayControls
                        Spacer(minLength: 0)
                    }
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 4).rayGitChrome()
            Divider()
            if let preview { StaticComparisonView(snapshot: preview, showsControls: false) }
            else if text.isEmpty { RayGitEmptyState(title: diffText("diff.empty"), systemImage: "checkmark.circle") }
            else {
                if diff.isBinary { Label(diffText("diff.binary"), systemImage: "doc.zipper").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1)) }
                if diff.isTruncated { Text(diffText("diff.truncated", 20000)).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.15)) }
                if sideBySide {
                    HStack(spacing: 1) {
                        Text(leftRevisionTitle ?? diffText("diff.original")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(rightRevisionTitle ?? diffText("diff.modified")).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 26).rayGitChrome()
                    Divider()
                }
                DiffTextSurface(diff: diff, sourceText: text, languagePath: title, documentIdentity: documentIdentity, sideBySide: sideBySide, selectedHunk: hunk, dark: colorScheme == .dark, wraps: wraps, lineNumbers: lineNumbers, synchronized: synchronized, fontSize: CGFloat(fontSize), compact: forceCompact || compact, searchOptions: searchOptions, searchStep: searchStep, matchCount: $matchCount, matchIndex: $matchIndex, searchError: $searchError, scrollsToFirstChange: openedDocumentIdentity != documentIdentity, onFirstScroll: { openedDocumentIdentity = documentIdentity })
            }
        }.background(ComparisonKeyboardRegion(standalone: standaloneShortcuts, action: performShortcut))
            .background(RayGitStyle.canvas).onChange(of: documentIdentity) { _, _ in hunk = 0 }
            .onExitCommand { closeSearch() }
            .onAppear { searchOptions = initialSearchOptions; replacement = initialReplacement }
            .onChange(of: initialSearchOptions) { _, value in searchOptions = value }
            .onChange(of: initialReplacement) { _, value in replacement = value }
    }
    private func performShortcut(_ command: ShortcutCommand) -> Bool {
        guard !isLoading, preview == nil else { return false }
        switch command {
        case .compareFind: showSearch = true
        case .compareFindNext, .compareFindPrevious:
            guard !searchOptions.query.isEmpty else { return false }
            searchStep += command == .compareFindNext ? 1 : -1
        case .comparePreviousChange:
            guard !parsed.hunks.isEmpty else { return false }; hunk = max(0, hunk - 1)
        case .compareNextChange:
            guard !parsed.hunks.isEmpty else { return false }; hunk = min(parsed.hunks.count - 1, hunk + 1)
        case .compareWrap: wraps.toggle()
        case .compareCompact: compact.toggle()
        case .compareLines: lineNumbers.toggle()
        case .compareSync: synchronized.toggle()
        default: return false
        }
        return true
    }
    private var documentIdentity: String { title + "|" + (leftRevisionTitle ?? "") + "|" + (rightRevisionTitle ?? "") }
    private var titleLabel: some View {
        Label(title.isEmpty ? diffText("diff.title") : title, systemImage: "doc.text")
            .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(title)
    }
    private func hunkControls(_ diff: ParsedDiff) -> some View {
        HStack(spacing: 2) {
            RayGitBadge(diffText("diff.hunkCount", diff.hunks.count), tint: .secondary).fixedSize().padding(.trailing, 6)
            Button { hunk = max(0, hunk - 1) } label: { ComparisonToolbarIcon(name: "chevron.up") }.buttonStyle(ComparisonToolbarButtonStyle())
                .disabled(diff.hunks.isEmpty).help(diffText("diff.previousHunk")).accessibilityLabel(diffText("diff.previousHunk"))
            Button { hunk = min(diff.hunks.count - 1, hunk + 1) } label: { ComparisonToolbarIcon(name: "chevron.down") }.buttonStyle(ComparisonToolbarButtonStyle())
                .disabled(diff.hunks.isEmpty).help(diffText("diff.nextHunk")).accessibilityLabel(diffText("diff.nextHunk"))
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22))
    }
    private var displayControls: some View {
        HStack(spacing: 8) {
            Picker(diffText("diff.view"), selection: $sideBySide) {
                Text(diffText("diff.sideBySide")).tag(true)
                Text(diffText("diff.unified")).tag(false)
            }.pickerStyle(.segmented).labelsHidden().frame(height: 24).fixedSize(horizontal: true, vertical: false).accessibilityLabel(diffText("diff.view"))
            Menu {
                Toggle(L10n.text("Changes only", table: "DiffRefinement"), isOn: $compact)
                Toggle(diffControlText("wrap"), isOn: $wraps)
                Toggle(diffControlText("lineNumbers"), isOn: $lineNumbers)
                Toggle(diffControlText("syncScroll"), isOn: $synchronized)
                Divider()
                Button(diffControlText("larger")) { fontSize = min(24, fontSize + 1) }
                Button(diffControlText("smaller")) { fontSize = max(9, fontSize - 1) }
                Button(diffControlText("resetFont")) { fontSize = 12 }
                if let extraMenuItems { Divider(); extraMenuItems.disabled(isLoading) }
            } label: { ComparisonToolbarIcon(name: "ellipsis") }.buttonStyle(ComparisonToolbarButtonStyle())
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(diffControlText("display"))
            Button { showSearch.toggle() } label: { ComparisonToolbarIcon(name: "magnifyingglass") }.buttonStyle(ComparisonToolbarButtonStyle())
                .help(diffControlText("search")).accessibilityLabel(diffControlText("search"))
                .popover(isPresented: $showSearch) {
                    ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: matchCount, matchIndex: matchIndex, canReplace: false,
                        onNavigate: { searchStep += $0 ? 1 : -1 }, onReplace: { _ in },
                        onOpenEditor: (isLoading ? nil : onOpenEditableComparison).map { action in { action(searchOptions, replacement); showSearch = false } }, error: searchError, onClose: { showSearch = false })
                }
        }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22))
    }
    private func closeSearch() { searchOptions.query = ""; showSearch = false }
}

/// AppKit lays out a single attributed document per column, keeping large patches
/// out of SwiftUI's view tree. Selection and Cmd-C use standard text editing behavior.
struct DiffTextSurface: NSViewRepresentable {
    let diff: ParsedDiff
    let sourceText: String
    let languagePath: String
    let documentIdentity: String
    let sideBySide: Bool
    let selectedHunk: Int
    let dark: Bool
    @AppStorage("editor.additionColor") private var additionColor = ""
    @AppStorage("editor.deletionColor") private var deletionColor = ""
    @AppStorage("editor.modificationColor") private var modificationColor = ""
    @AppStorage("editor.fontName") private var fontName = ""
    @AppStorage("editor.syntaxHighlight") private var syntaxHighlight = true
    @AppStorage("editor.characterDiff") private var characterDiff = true
    @AppStorage("editor.tabWidth") private var tabWidth = 4
    @AppStorage("editor.showWhitespace") private var showWhitespace = false
    let wraps: Bool
    let lineNumbers: Bool
    let synchronized: Bool
    let fontSize: CGFloat
    let compact: Bool
    let searchOptions: ComparisonSearchOptions
    let searchStep: Int
    @Binding var matchCount: Int
    @Binding var matchIndex: Int
    @Binding var searchError: String?
    let scrollsToFirstChange: Bool
    let onFirstScroll: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSStackView {
        let stack = AlignedDiffStackView(); stack.onResize = { [weak coordinator = context.coordinator] in coordinator?.alignWrappedRows() }; stack.orientation = .horizontal; stack.spacing = 1; stack.distribution = .fillEqually
        for _ in 0..<2 {
            let scroll = ComparisonOverviewScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
            let view = ReadOnlyDiffTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false; view.allowsUndo = false
            view.isHorizontallyResizable = true; view.isVerticallyResizable = true
            view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = view; stack.addArrangedSubview(scroll)
            context.coordinator.scrolls.append(scroll)
            context.coordinator.observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: view, queue: .main) { [weak coordinator = context.coordinator, weak view] _ in
                guard let coordinator, let view else { return }
                coordinator.highlightCurrentRow(in: view)
            })
            scroll.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator, weak scroll] _ in
                guard let coordinator, let scroll else { return }
                coordinator.synchronizeScroll(from: scroll)
            })
        }
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        let coordinator = context.coordinator
        let changedIdentity = coordinator.documentIdentity != documentIdentity
        if changedIdentity {
            coordinator.documentIdentity = documentIdentity
            coordinator.pendingFirstScroll = false
            coordinator.lastHunk = -1
        }
        let signature = sourceText
        coordinator.synchronized = synchronized
        let changedDocument = changedIdentity || coordinator.signature != signature
        let style = "\(compact)|\(additionColor)|\(deletionColor)|\(modificationColor)|\(fontName)|\(syntaxHighlight)|\(characterDiff)|\(tabWidth)|\(showWhitespace)"
        let changedStyle = coordinator.style != style
        coordinator.style = style
        if changedStyle || changedDocument || coordinator.split != sideBySide || coordinator.dark != dark || coordinator.lineNumbers != lineNumbers || coordinator.fontSize != fontSize {
            coordinator.syncing = true
            coordinator.lineNumbers = lineNumbers; coordinator.fontSize = fontSize
            coordinator.lastAlignedSignature = nil
            coordinator.signature = signature; coordinator.split = sideBySide; coordinator.dark = dark
            let documents = render()
            coordinator.hunkRanges = documents.ranges
            coordinator.hunkKinds = diff.hunks.indices.map { index in
                let start = diff.hunks[index].lineIndex
                let end = index + 1 < diff.hunks.count ? diff.hunks[index + 1].lineIndex : diff.lines.count
                let rows = diff.lines[start..<end]
                let additions = rows.contains { $0.kind == .addition }, deletions = rows.contains { $0.kind == .deletion }
                return additions && !deletions ? .addition : deletions && !additions ? .deletion : .modification
            }
            coordinator.scrolls[1].isHidden = !sideBySide
            for (index, scroll) in coordinator.scrolls.enumerated() {
                let view = scroll.documentView as! NSTextView
                view.backgroundColor = .textBackgroundColor
                view.layoutManager?.showsInvisibleCharacters = showWhitespace
                let selection = view.selectedRange()
                let position = scroll.contentView.bounds.origin
                view.textStorage?.setAttributedString(documents.text[index])
                let length = (view.string as NSString).length
                view.setSelectedRange(changedDocument && scrollsToFirstChange ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
                scroll.contentView.scroll(to: changedDocument && scrollsToFirstChange ? .zero : position)
            }
            coordinator.searchOptions = nil
            coordinator.syncing = false
        }
        coordinator.syncing = true
        for scroll in coordinator.scrolls {
            guard let view = scroll.documentView as? NSTextView else { continue }
            if coordinator.wraps != wraps {
                let position = scroll.contentView.bounds.origin
                view.isHorizontallyResizable = !wraps
                view.autoresizingMask = wraps ? [.width] : []
                view.textContainer?.widthTracksTextView = wraps
                view.textContainer?.containerSize = NSSize(width: wraps ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                if wraps { view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.frame.height)) }
                scroll.hasHorizontalScroller = !wraps
                scroll.contentView.scroll(to: position)
            }
        }
        coordinator.syncing = false
        coordinator.wraps = wraps
        coordinator.alignWrappedRows()
        if coordinator.searchOptions != searchOptions {
            coordinator.searchOptions = searchOptions
            coordinator.matches = []
            var failure: String?
            for (column, scroll) in coordinator.scrolls.enumerated() where !scroll.isHidden {
                guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { continue }
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
                let string = storage.string as NSString
                storage.enumerateAttribute(.rayGitDiffDecoration, in: NSRange(location: 0, length: storage.length)) { decoration, sourceRange, _ in
                    guard decoration as? Bool != true else { return }
                    switch ComparisonSearch.matches(in: string.substring(with: sourceRange), options: searchOptions) {
                    case .failure(let error): failure = error.localizedDescription
                    case .success(let ranges):
                        for item in ranges {
                            let range = NSRange(location: sourceRange.location + item.location, length: item.length)
                            coordinator.matches.append((column, range))
                            view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: range)
                        }
                    }
                }
            }
            coordinator.matchIndex = -1
            let count = coordinator.matches.count, error = failure
            if matchCount != count || searchError != error || matchIndex != 0 { DispatchQueue.main.async { self.matchCount = count; self.matchIndex = 0; self.searchError = error } }
        }
        if coordinator.searchStep != searchStep {
            let direction = searchStep > coordinator.searchStep ? 1 : -1
            coordinator.searchStep = searchStep
            if !coordinator.matches.isEmpty {
                coordinator.matchIndex = coordinator.matchIndex < 0 ? (direction > 0 ? 0 : coordinator.matches.count - 1) : (coordinator.matchIndex + direction + coordinator.matches.count) % coordinator.matches.count
                let (column, range) = coordinator.matches[coordinator.matchIndex]
                coordinator.navigate(column: column, range: range)
                let current = coordinator.matchIndex + 1
                DispatchQueue.main.async { self.matchIndex = current }
            }
        }
        if scrollsToFirstChange, !coordinator.pendingFirstScroll, let firstIndex = coordinator.hunkRanges.firstIndex(where: { $0[0].length > 0 || $0[1].length > 0 }) {
            let first = coordinator.hunkRanges[firstIndex]
            coordinator.pendingFirstScroll = true
            DispatchQueue.main.async {
                guard coordinator.documentIdentity == documentIdentity else { return }
                guard coordinator.signature == signature else { coordinator.pendingFirstScroll = false; return }
                coordinator.alignWrappedRows()
                coordinator.navigate(column: 0, range: first[0])
                coordinator.lastHunk = firstIndex; self.onFirstScroll()
            }
        }
        if !scrollsToFirstChange, selectedHunk >= 0, selectedHunk < coordinator.hunkRanges.count, selectedHunk != coordinator.lastHunk {
            coordinator.lastHunk = selectedHunk
            coordinator.navigate(column: 0, range: coordinator.hunkRanges[selectedHunk][0])
        }
    }
    private func render() -> (text: [NSAttributedString], ranges: [[NSRange]]) {
        let left = NSMutableAttributedString(), right = NSMutableAttributedString()
        var ranges: [[NSRange]] = []
        let font = EditorPreferences.font(name: fontName, size: Double(fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(min(16, max(1, tabWidth)))
        func append(_ line: DiffLine?, to output: NSMutableAttributedString, number: Int?, prefix: String = "") {
            let kind = line?.kind ?? .context
            let background: NSColor = kind == .addition ? DiffVisualStyle.lineBackground(EditorPreferences.color(additionColor, fallback: .systemGreen), dark: dark) : kind == .deletion ? DiffVisualStyle.lineBackground(EditorPreferences.color(deletionColor, fallback: .systemRed), dark: dark) : kind == .hunk ? NSColor.systemBlue.withAlphaComponent(0.12) : .textBackgroundColor
            let gutter = lineNumbers ? ((number.map { String(format: "%6d", $0) } ?? "      ") + "  ") : ""
            let marker = sideBySide ? (kind == .addition ? "+ " : kind == .deletion ? "− " : "  ") : ""
            let rowOffset = output.length
            let contentOffset = rowOffset + gutter.utf16.count + marker.utf16.count + prefix.utf16.count
            output.append(NSAttributedString(string: gutter + marker + prefix + (line?.text ?? "") + "\n", attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: kind == .metadata || kind == .hunk ? NSColor.secondaryLabelColor : NSColor.textColor, .backgroundColor: background]))
            if kind == .addition || kind == .deletion {
                output.addAttribute(.rayGitDiffRowBackground, value: background, range: NSRange(location: rowOffset, length: output.length - rowOffset))
            }
            if lineNumbers {
                // Style only the number columns; preserve the original text and offsets.
                let numberColumnsLength = gutter.utf16.count + (sideBySide ? 0 : 7)
                output.addAttributes([.font: DiffVisualStyle.lineNumberFont(codeSize: fontSize), .foregroundColor: DiffVisualStyle.lineNumberColor], range: NSRange(location: rowOffset, length: numberColumnsLength))
            }
            // Gutter and marker are display decoration, excluded from plain-text copy.
            if contentOffset > rowOffset {
                output.addAttribute(.rayGitDiffDecoration, value: true, range: NSRange(location: rowOffset, length: contentOffset - rowOffset))
            }
            if sideBySide, line == nil {
                output.addAttribute(.rayGitDiffDecoration, value: true, range: NSRange(location: rowOffset, length: output.length - rowOffset))
            }
            if sideBySide, kind == .addition || kind == .deletion {
                let color = kind == .addition ? EditorPreferences.color(additionColor, fallback: .systemGreen) : EditorPreferences.color(deletionColor, fallback: .systemRed)
                output.addAttribute(.foregroundColor, value: color, range: NSRange(location: rowOffset + gutter.utf16.count, length: 1))
            }
            if syntaxHighlight, let line, [.context, .addition, .deletion].contains(line.kind) {
                for token in SyntaxHighlighter.tokens(in: line.text, path: languagePath) {
                    let color: NSColor
                    switch token.kind { case .keyword: color = .systemPurple; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor; case .number: color = .systemBlue }
                    output.addAttribute(.foregroundColor, value: color, range: NSRange(location: contentOffset + token.range.location, length: token.range.length))
                }
            }
        }
        ranges = Array(repeating: [NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)], count: diff.hunks.count)
        var anchored: Set<Int> = []
        for row in PatchPreviewRows.make(diff, sideBySide: sideBySide, compact: compact) {
            if row.isChange, let hunk = row.hunk, ranges.indices.contains(hunk), anchored.insert(hunk).inserted {
                ranges[hunk] = [NSRange(location: left.length, length: 1), NSRange(location: right.length, length: sideBySide ? 1 : 0)]
            }
            if sideBySide {
                let leftOffset = left.length + (lineNumbers ? 8 : 0) + 2, rightOffset = right.length + (lineNumbers ? 8 : 0) + 2
                append(row.left, to: left, number: row.left?.oldNumber)
                append(row.right, to: right, number: row.right?.newNumber)
                if characterDiff, let a = row.left, let b = row.right, row.isChange {
                    let character = CharacterDiff(source: a.text, target: b.text)
                    for range in character.source { left.addAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(EditorPreferences.color(deletionColor, fallback: .systemRed), dark: dark), range: NSRange(location: leftOffset + range.location, length: range.length)) }
                    for range in character.target { right.addAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(EditorPreferences.color(additionColor, fallback: .systemGreen), dark: dark), range: NSRange(location: rightOffset + range.location, length: range.length)) }
                }
            } else if let line = row.left {
                let old = lineNumbers ? ((line.oldNumber.map { String(format: "%6d", $0) } ?? "      ") + " ") : ""
                append(line, to: left, number: line.newNumber, prefix: old + (line.kind == .addition ? "+ " : line.kind == .deletion ? "− " : "  "))
            }
            if row.isChange, let hunk = row.hunk, ranges.indices.contains(hunk) {
                ranges[hunk][0].length = left.length - ranges[hunk][0].location
                if sideBySide { ranges[hunk][1].length = right.length - ranges[hunk][1].location }
            }
        }
        return ([left, right], ranges)
    }
    final class Coordinator {
        var style = ""
        var scrolls: [NSScrollView] = [], observers: [NSObjectProtocol] = []
        var syncing = false, split = true, dark = false
        var synchronized = true, lineNumbers = true
        var wraps: Bool? = nil
        var fontSize: CGFloat = 12
        var searchOptions: ComparisonSearchOptions?
        var pendingFirstScroll = false
        var searchStep = 0, matchIndex = -1
        var matches: [(Int, NSRange)] = []
        var signature = "", lastHunk = -1
        var documentIdentity = ""
        var hunkRanges: [[NSRange]] = []
        var hunkKinds: [ComparisonOverviewMarker.Kind] = []
        var lastAlignedSignature: String?
        private var lastAlignedWidths: [CGFloat] = []
        private var lastAlignedWrap: Bool?
        private var aligning = false
        func synchronizeScroll(from source: NSScrollView) {
            guard !syncing, synchronized || wraps == false else { return }
            syncing = true; defer { syncing = false }
            // Elastic bounds lie outside the document. Forward only the legal
            // document position, and constrain it independently for each pane.
            let sourcePosition = source.contentView.constrainBoundsRect(source.contentView.bounds).origin
            for target in scrolls where target !== source && !target.isHidden {
                var bounds = target.contentView.bounds
                if wraps == false { bounds.origin.x = sourcePosition.x }
                if synchronized { bounds.origin.y = sourcePosition.y }
                let position = target.contentView.constrainBoundsRect(bounds).origin
                guard abs(position.x - target.contentView.bounds.minX) > 0.01
                        || abs(position.y - target.contentView.bounds.minY) > 0.01 else { continue }
                target.contentView.scroll(to: position)
                target.reflectScrolledClipView(target.contentView)
            }
        }
        func highlightCurrentRow(in active: NSTextView) {
            guard let sourceIndex = scrolls.firstIndex(where: { $0.documentView === active }) else { return }
            let string = active.string as NSString
            let location = min(active.selectedRange().location, max(0, string.length - 1))
            var row = 0, offset = 0
            while offset < location {
                let next = NSMaxRange(string.lineRange(for: NSRange(location: offset, length: 0)))
                if next > location { break }; row += 1; offset = next
            }
            for (index, scroll) in scrolls.enumerated() {
                guard let view = scroll.documentView as? ReadOnlyDiffTextView else { continue }
                view.highlightedRow = index == sourceIndex || split ? row : nil
                view.needsDisplay = true
            }
        }
        /// Explicit navigation always moves both aligned documents, independently of manual scroll preferences.
        func navigate(column: Int, range: NSRange) {
            guard scrolls.indices.contains(column), let view = scrolls[column].documentView as? NSTextView,
                  NSMaxRange(range) <= (view.string as NSString).length else { return }
            syncing = true
            view.setSelectedRange(range); view.scrollRangeToVisible(range)
            let y = scrolls[column].contentView.bounds.origin.y
            for scroll in scrolls where !scroll.isHidden {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            syncing = false
            highlightCurrentRow(in: view)
        }
        private func refreshOverviews() {
            for (column, scroll) in scrolls.enumerated() {
                guard let scroll = scroll as? ComparisonOverviewScrollView, let view = scroll.documentView as? NSTextView,
                      let layout = view.layoutManager, let container = view.textContainer else { continue }
                layout.ensureLayout(for: container)
                let height = max(1, view.bounds.height)
                let textLength = view.textStorage?.length ?? 0
                scroll.overview.markers = hunkRanges.enumerated().map { index, ranges in
                    let range = ranges[column]
                    let location = min(range.location, max(0, textLength - 1))
                    let glyph = layout.numberOfGlyphs > 0 ? layout.glyphIndexForCharacter(at: location) : 0
                    let rect = layout.numberOfGlyphs > 0 ? layout.lineFragmentRect(forGlyphAt: min(glyph, layout.numberOfGlyphs - 1), effectiveRange: nil) : .zero
                    let end = min(max(location, NSMaxRange(range) - 1), max(0, textLength - 1))
                    let last = layout.numberOfGlyphs > 0 ? layout.glyphIndexForCharacter(at: end) : 0
                    let bottom = layout.numberOfGlyphs > 0 ? layout.lineFragmentRect(forGlyphAt: min(last, layout.numberOfGlyphs - 1), effectiveRange: nil).maxY : rect.maxY
                    return ComparisonOverviewMarker(lower: min(1, Double((rect.minY + view.textContainerInset.height) / height)), upper: min(1, Double((bottom + view.textContainerInset.height) / height)), kind: self.hunkKinds.indices.contains(index) ? self.hunkKinds[index] : .modification, index: index)
                }
                scroll.overview.onNavigate = { [weak self] fraction in
                    guard let self else { return }
                    let point = NSPoint(x: 0, y: max(0, CGFloat(fraction) * height - view.textContainerInset.height))
                    let glyph = layout.glyphIndex(for: point, in: container)
                    let character = fraction == 1 ? textLength : layout.numberOfGlyphs > 0 ? layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1)) : 0
                    self.navigate(column: column, range: NSRange(location: character, length: 0))
                }
                scroll.overview.onSelect = { [weak self] index in
                    guard let self, self.hunkRanges.indices.contains(index) else { return }
                    self.lastHunk = index; self.navigate(column: column, range: self.hunkRanges[index][column])
                }
            }
        }
        func alignWrappedRows() {
            guard !aligning else { return }
            let widths = scrolls.map { $0.contentSize.width }
            guard lastAlignedSignature != signature || lastAlignedWidths != widths || lastAlignedWrap != wraps else { return }
            lastAlignedSignature = signature; lastAlignedWidths = widths; lastAlignedWrap = wraps
            aligning = true
            defer { aligning = false; refreshOverviews() }
            let views = scrolls.compactMap { $0.documentView as? NSTextView }
            guard split, views.count == 2 else { return }
            if wraps != true {
                for (index, view) in views.enumerated() {
                    if let storage = view.textStorage {
                        var spacing: [(NSRange, NSMutableParagraphStyle)] = []
                        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                            guard let style = value as? NSParagraphStyle, style.paragraphSpacing != 0,
                                  let paragraph = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                            paragraph.paragraphSpacing = 0
                            spacing.append((range, paragraph))
                        }
                        if !spacing.isEmpty {
                            storage.beginEditing()
                            for (range, paragraph) in spacing { storage.addAttribute(.paragraphStyle, value: paragraph, range: range) }
                            storage.endEditing()
                        }
                    }
                    view.sizeToFit(); view.setFrameOrigin(.zero)
                    view.setFrameSize(NSSize(width: max(view.frame.width, scrolls[index].contentSize.width), height: view.frame.height))
                }
                return
            }
            var rows: [[NSRange]] = []
            for (index, view) in views.enumerated() {
                if wraps == true {
                    view.setFrameSize(NSSize(width: scrolls[index].contentSize.width, height: view.frame.height))
                    view.textContainer?.containerSize.width = max(1, scrolls[index].contentSize.width - 2 * view.textContainerInset.width)
                }
                let source = view.string as NSString
                var ranges: [NSRange] = [], offset = 0
                view.textStorage?.beginEditing()
                while offset < source.length {
                    let range = source.lineRange(for: NSRange(location: offset, length: 0))
                    ranges.append(range); offset = NSMaxRange(range)
                    if let existing = view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle, existing.paragraphSpacing != 0,
                       let paragraph = existing.mutableCopy() as? NSMutableParagraphStyle {
                        paragraph.paragraphSpacing = 0
                        view.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
                    }
                }
                view.textStorage?.endEditing()
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                rows.append(ranges)
            }
            guard rows[0].count == rows[1].count else { return }
            let heights = views.enumerated().map { column, view in
                rows[column].map { range -> CGFloat in
                    guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    return layout.boundingRect(forGlyphRange: glyphs, in: container).height
                }
            }
            views.forEach { $0.textStorage?.beginEditing() }
            for row in rows[0].indices {
                let height = max(heights[0][row], heights[1][row])
                for column in 0..<2 {
                    let range = rows[column][row], view = views[column]
                    guard let style = view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                          let paragraph = style.mutableCopy() as? NSMutableParagraphStyle else { continue }
                    paragraph.paragraphSpacing = max(0, height - heights[column][row])
                    guard paragraph.paragraphSpacing != style.paragraphSpacing else { continue }
                    view.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
            }
            views.forEach { $0.textStorage?.endEditing() }
            for (index, view) in views.enumerated() {
                view.layoutManager?.ensureLayout(for: view.textContainer!); view.sizeToFit(); view.setFrameOrigin(.zero)
                view.setFrameSize(NSSize(width: wraps == true ? scrolls[index].contentSize.width : max(view.frame.width, scrolls[index].contentSize.width), height: view.frame.height))
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

private final class AlignedDiffStackView: NSStackView {
    var onResize: (() -> Void)?
    private var lastSize: NSSize = .zero
    override func layout() {
        super.layout()
        guard lastSize != bounds.size else { return }
        lastSize = bounds.size
        onResize?()
    }
}

private extension NSAttributedString.Key {
    static let rayGitDiffRowBackground = NSAttributedString.Key("RayGitDiffRowBackground")
    static let rayGitDiffDecoration = NSAttributedString.Key("RayGitDiffDecoration")
}

/// The attributed preview contains visual gutters, but copying returns selected code.
final class ReadOnlyDiffTextView: NSTextView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); setAccessibilityHelp(NativeFocusNavigation.editorHelp) }
    override func keyDown(with event: NSEvent) {
        if NativeFocusNavigation.leaveEditor(event, from: self) { return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ComparisonCaret.draw(in: self, dirtyRect: dirtyRect)
    }
    override var shouldDrawInsertionPoint: Bool { ComparisonCaret.shouldDraw(in: self) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }
    var highlightedRow: Int?
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let source = storage.string as NSString
        storage.enumerateAttribute(.rayGitDiffRowBackground, in: visible) { value, range, _ in
            guard let color = value as? NSColor else { return }
            var offset = range.location
            while offset < NSMaxRange(range) {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                let lineGlyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                let bounds = layout.boundingRect(forGlyphRange: lineGlyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                color.setFill()
                NSRect(x: 0, y: bounds.minY, width: self.bounds.width, height: bounds.height).intersection(rect).fill()
                offset = NSMaxRange(line)
            }
        }
        if let highlightedRow {
            var row = 0, offset = 0
            while offset < storage.length {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                if row == highlightedRow {
                    let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                    let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                    NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                    NSRect(x: 0, y: bounds.minY, width: self.bounds.width, height: bounds.height).intersection(rect).fill()
                    break
                }
                offset = NSMaxRange(line); row += 1
            }
        }
    }
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { super.copy(sender); return }
        let selection = selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return }
        let source = storage.string as NSString
        var value = ""
        storage.enumerateAttribute(.rayGitDiffDecoration, in: selection) { decoration, range, _ in
            if decoration as? Bool != true { value += source.substring(with: range) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Parsing and signatures are independent of search/caret/display changes.
private final class ComparisonPatchCache: ObservableObject {
    private var source: String?
    private var parsed: ParsedDiff?
    func value(for text: String) -> ParsedDiff {
        if source != text { source = text; parsed = DiffParser.parse(text) }
        return parsed ?? DiffParser.parse("")
    }
}
