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
    @AppStorage("editor.defaultDiffSideBySide") private var sideBySide = true
    @State private var hunk = -1
    @AppStorage("editor.wrapLines") private var wraps = false
    @AppStorage("editor.showLineNumbers") private var lineNumbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronized = true
    @AppStorage("editor.fontSize") private var fontSize: Double = 12
    @State private var query = ""
    @State private var searchStep = 0
    @State private var matchCount = 0
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var parsed: ParsedDiff { DiffParser.parse(text) }
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
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6).rayGitChrome()
            if showSearch {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(diffControlText("search"), text: $query).textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onSubmit { searchStep += 1 }
                        if !query.isEmpty { Text("\(matchCount)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                        .rayGitInputSurface()
                        .frame(minWidth: 80, maxWidth: 260)
                    Button { searchStep -= 1 } label: { Image(systemName: "chevron.up") }
                        .help(diffControlText("previousMatch")).disabled(matchCount == 0)
                    Button { searchStep += 1 } label: { Image(systemName: "chevron.down") }
                        .help(diffControlText("nextMatch")).disabled(matchCount == 0)
                    Button { closeSearch() } label: { Image(systemName: "xmark") }
                    Spacer(minLength: 0)
                }.controlSize(.small).padding(.horizontal, 12).padding(.bottom, 6).rayGitChrome()
            }
            Divider()
            if isLoading { Spacer(); ProgressView(diffText("diff.loading")); Spacer() }
            else if text.isEmpty { RayGitEmptyState(title: diffText("diff.empty"), systemImage: "checkmark.circle") }
            else {
                if diff.isBinary { Label(diffText("diff.binary"), systemImage: "doc.zipper").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1)) }
                if diff.isTruncated { Text(diffText("diff.truncated", 20000)).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.15)) }
                if sideBySide {
                    HStack(spacing: 1) {
                        Text(diffText("diff.original")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(diffText("diff.modified")).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5).rayGitChrome()
                    Divider()
                }
                DiffTextSurface(diff: diff, languagePath: title, sideBySide: sideBySide, selectedHunk: hunk, dark: colorScheme == .dark, wraps: wraps, lineNumbers: lineNumbers, synchronized: synchronized, fontSize: CGFloat(fontSize), query: query, searchStep: searchStep, matchCount: $matchCount)
            }
        }.background(RayGitStyle.canvas).onChange(of: text) { _, _ in hunk = -1 }
            .onExitCommand { closeSearch() }
    }
    private var titleLabel: some View {
        Label(title.isEmpty ? diffText("diff.title") : title, systemImage: "doc.text")
            .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(title)
    }
    private func hunkControls(_ diff: ParsedDiff) -> some View {
        HStack(spacing: 8) {
            RayGitBadge(diffText("diff.hunkCount", diff.hunks.count), tint: .secondary).fixedSize()
            Button { hunk = max(0, hunk - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(diff.hunks.isEmpty).help(diffText("diff.previousHunk")).accessibilityLabel(diffText("diff.previousHunk"))
            Button { hunk = min(diff.hunks.count - 1, hunk + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(diff.hunks.isEmpty).help(diffText("diff.nextHunk")).accessibilityLabel(diffText("diff.nextHunk"))
        }
    }
    private var displayControls: some View {
        HStack(spacing: 8) {
            Picker(diffText("diff.view"), selection: $sideBySide) {
                Text(diffText("diff.sideBySide")).tag(true)
                Text(diffText("diff.unified")).tag(false)
            }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false).accessibilityLabel(diffText("diff.view"))
            Menu {
                Toggle(diffControlText("wrap"), isOn: $wraps)
                Toggle(diffControlText("lineNumbers"), isOn: $lineNumbers)
                Toggle(diffControlText("syncScroll"), isOn: $synchronized)
                Divider()
                Button(diffControlText("larger")) { fontSize = min(24, fontSize + 1) }
                Button(diffControlText("smaller")) { fontSize = max(9, fontSize - 1) }
                Button(diffControlText("resetFont")) { fontSize = 12 }
            } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().help(diffControlText("display"))
            Button {
                if showSearch { closeSearch() }
                else {
                    showSearch = true
                    DispatchQueue.main.async { searchFocused = true }
                }
            } label: { Image(systemName: "magnifyingglass") }
                .help(diffControlText("search")).accessibilityLabel(diffControlText("search"))
        }
    }
    private func closeSearch() {
        query = ""
        searchFocused = false
        showSearch = false
    }
}

/// AppKit lays out a single attributed document per column, keeping large patches
/// out of SwiftUI's view tree. Selection and Cmd-C use standard text editing behavior.
private struct DiffTextSurface: NSViewRepresentable {
    let diff: ParsedDiff
    let languagePath: String
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
    let query: String
    let searchStep: Int
    @Binding var matchCount: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 1; stack.distribution = .fillEqually
        for _ in 0..<2 {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false; view.allowsUndo = false
            view.isHorizontallyResizable = true; view.isVerticallyResizable = true
            view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainerInset = NSSize(width: 8, height: 8)
            scroll.documentView = view; stack.addArrangedSubview(scroll)
            context.coordinator.scrolls.append(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator, weak scroll] _ in
                guard let coordinator, let scroll, !coordinator.syncing, coordinator.synchronized else { return }
                coordinator.syncing = true
                for other in coordinator.scrolls where other !== scroll && !other.isHidden {
                    other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: scroll.contentView.bounds.origin.y)); other.reflectScrolledClipView(other.contentView)
                }
                coordinator.syncing = false
            })
        }
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        let coordinator = context.coordinator
        let signature = diff.lines.map { "\($0.kind):\($0.oldNumber ?? -1):\($0.newNumber ?? -1):\($0.text)" }.joined(separator: "\n")
        coordinator.synchronized = synchronized
        let changedDocument = coordinator.signature != signature
        let style = "\(additionColor)|\(deletionColor)|\(modificationColor)|\(fontName)|\(syntaxHighlight)|\(characterDiff)|\(tabWidth)|\(showWhitespace)"
        let changedStyle = coordinator.style != style
        coordinator.style = style
        if changedStyle || changedDocument || coordinator.split != sideBySide || coordinator.dark != dark || coordinator.lineNumbers != lineNumbers || coordinator.fontSize != fontSize {
            coordinator.syncing = true
            coordinator.lineNumbers = lineNumbers; coordinator.fontSize = fontSize
            coordinator.signature = signature; coordinator.split = sideBySide; coordinator.dark = dark
            let documents = render()
            coordinator.hunkRanges = documents.ranges
            coordinator.scrolls[1].isHidden = !sideBySide
            for (index, scroll) in coordinator.scrolls.enumerated() {
                let view = scroll.documentView as! NSTextView
                view.backgroundColor = .textBackgroundColor
                view.layoutManager?.showsInvisibleCharacters = showWhitespace
                let selection = view.selectedRange()
                let position = scroll.contentView.bounds.origin
                view.textStorage?.setAttributedString(documents.text[index])
                let length = (view.string as NSString).length
                view.setSelectedRange(changedDocument ? NSRange(location: 0, length: 0) : NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
                scroll.contentView.scroll(to: changedDocument ? .zero : position)
            }
            if changedDocument { coordinator.lastHunk = -1 }
            coordinator.query = nil
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
        if coordinator.query != query {
            coordinator.query = query
            coordinator.matches = []
            for (column, scroll) in coordinator.scrolls.enumerated() where !scroll.isHidden {
                guard let view = scroll.documentView as? NSTextView else { continue }
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (view.string as NSString).length))
                let string = view.string as NSString
                var start = 0
                while !query.isEmpty && start < string.length {
                    let range = string.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: string.length - start))
                    if range.location == NSNotFound { break }
                    coordinator.matches.append((column, range))
                    view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: range)
                    start = NSMaxRange(range)
                }
            }
            coordinator.matchIndex = -1
            let count = coordinator.matches.count
            if matchCount != count { DispatchQueue.main.async { self.matchCount = count } }
        }
        if coordinator.searchStep != searchStep {
            let direction = searchStep > coordinator.searchStep ? 1 : -1
            coordinator.searchStep = searchStep
            if !coordinator.matches.isEmpty {
                coordinator.matchIndex = coordinator.matchIndex < 0 ? (direction > 0 ? 0 : coordinator.matches.count - 1) : (coordinator.matchIndex + direction + coordinator.matches.count) % coordinator.matches.count
                let (column, range) = coordinator.matches[coordinator.matchIndex]
                if let view = coordinator.scrolls[column].documentView as? NSTextView {
                    view.setSelectedRange(range); view.scrollRangeToVisible(range)
                }
            }
        }
        if selectedHunk >= 0, selectedHunk < coordinator.hunkRanges.count, selectedHunk != coordinator.lastHunk {
            coordinator.lastHunk = selectedHunk
            for (column, scroll) in coordinator.scrolls.enumerated() where !scroll.isHidden { (scroll.documentView as? NSTextView)?.scrollRangeToVisible(coordinator.hunkRanges[selectedHunk][column]) }
        }
    }
    private func render() -> (text: [NSAttributedString], ranges: [[NSRange]]) {
        let left = NSMutableAttributedString(), right = NSMutableAttributedString()
        var ranges: [[NSRange]] = []
        let font = EditorPreferences.font(name: fontName, size: Double(fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(min(16, max(1, tabWidth)))
        func append(_ line: DiffLine?, to output: NSMutableAttributedString, number: Int?, prefix: String = "", modified: Bool = false) {
            let kind = line?.kind ?? .context
            let background: NSColor = modified ? DiffVisualStyle.lineBackground(EditorPreferences.color(modificationColor, fallback: .systemOrange), dark: dark) : kind == .addition ? DiffVisualStyle.lineBackground(EditorPreferences.color(additionColor, fallback: .systemGreen), dark: dark) : kind == .deletion ? DiffVisualStyle.lineBackground(EditorPreferences.color(deletionColor, fallback: .systemRed), dark: dark) : kind == .hunk ? NSColor.systemBlue.withAlphaComponent(0.12) : .textBackgroundColor
            let gutter = lineNumbers ? ((number.map { String(format: "%6d", $0) } ?? "      ") + "  ") : ""
            let rowOffset = output.length
            let contentOffset = rowOffset + gutter.utf16.count + prefix.utf16.count
            output.append(NSAttributedString(string: gutter + prefix + (line?.text ?? "") + "\n", attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: kind == .metadata || kind == .hunk ? NSColor.secondaryLabelColor : NSColor.textColor, .backgroundColor: background]))
            if lineNumbers {
                // Style only the number columns; preserve the original text and offsets.
                let numberColumnsLength = gutter.utf16.count + (sideBySide ? 0 : 7)
                output.addAttributes([.font: DiffVisualStyle.lineNumberFont(codeSize: fontSize), .foregroundColor: DiffVisualStyle.lineNumberColor], range: NSRange(location: rowOffset, length: numberColumnsLength))
            }
            if syntaxHighlight, let line, [.context, .addition, .deletion].contains(line.kind) {
                for token in SyntaxHighlighter.tokens(in: line.text, path: languagePath) {
                    let color: NSColor
                    switch token.kind { case .keyword: color = .systemPurple; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor; case .number: color = .systemBlue }
                    output.addAttribute(.foregroundColor, value: color, range: NSRange(location: contentOffset + token.range.location, length: token.range.length))
                }
            }
        }
        // The pane title already identifies a single file. Keep multi-file boundaries
        // and meaningful metadata (rename, mode, binary, missing final newline).
        let hasMultipleFiles = diff.lines.lazy.filter { $0.kind == .metadata && $0.text.hasPrefix("diff --git ") }.prefix(2).count > 1
        var index = 0
        while index < diff.lines.count {
            let line = diff.lines[index]
            if line.kind == .metadata && ((!hasMultipleFiles && line.text.hasPrefix("diff --git ")) || line.text.hasPrefix("index ") || line.text.hasPrefix("--- ") || line.text.hasPrefix("+++ ")) {
                index += 1
                continue
            }
            if line.kind == .hunk { ranges.append([NSRange(location: left.length, length: 1), NSRange(location: right.length, length: 1)]) }
            if sideBySide && (line.kind == .deletion || line.kind == .addition) {
                var removed: [DiffLine] = [], added: [DiffLine] = []
                while index < diff.lines.count && (diff.lines[index].kind == .deletion || diff.lines[index].kind == .addition) {
                    let item = diff.lines[index]; if item.kind == .deletion { removed.append(item) } else { added.append(item) }; index += 1
                }
                for row in 0..<max(removed.count, added.count) {
                    let a = row < removed.count ? removed[row] : nil, b = row < added.count ? added[row] : nil
                    let leftOffset = left.length + (lineNumbers ? 8 : 0), rightOffset = right.length + (lineNumbers ? 8 : 0)
                    append(a, to: left, number: a?.oldNumber, modified: a != nil && b != nil); append(b, to: right, number: b?.newNumber, modified: a != nil && b != nil)
                    if characterDiff, let a, let b {
                        let character = CharacterDiff(source: a.text, target: b.text)
                        for range in character.source { left.addAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(EditorPreferences.color(deletionColor, fallback: .systemRed), dark: dark), range: NSRange(location: leftOffset + range.location, length: range.length)) }
                        for range in character.target { right.addAttribute(.backgroundColor, value: DiffVisualStyle.characterBackground(EditorPreferences.color(additionColor, fallback: .systemGreen), dark: dark), range: NSRange(location: rightOffset + range.location, length: range.length)) }
                    }
                }
                continue
            }
            if sideBySide { append(line, to: left, number: line.oldNumber); append(line, to: right, number: line.newNumber) }
            else {
                let old = lineNumbers ? ((line.oldNumber.map { String(format: "%6d", $0) } ?? "      ") + " ") : ""
                append(line, to: left, number: line.newNumber, prefix: old + (line.kind == .addition ? "+ " : line.kind == .deletion ? "− " : "  "))
            }
            index += 1
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
        var query: String?
        var searchStep = 0, matchIndex = -1
        var matches: [(Int, NSRange)] = []
        var signature = "", lastHunk = -1
        var hunkRanges: [[NSRange]] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
