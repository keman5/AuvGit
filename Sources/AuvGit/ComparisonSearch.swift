import Foundation
import SwiftUI
import AuvGitLocalization

struct ComparisonSearchOptions: Equatable {
    var query = ""
    var caseSensitive = false
    var regularExpression = false
}
func comparisonSearchText(_ key: String) -> String { L10n.text(key, table: "ComparisonSearch") }

enum ComparisonSearch {
    private static let expressions: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>(); cache.countLimit = 32; return cache
    }()
    static func expression(for options: ComparisonSearchOptions) throws -> NSRegularExpression {
        let key = "\(options.caseSensitive)|\(options.regularExpression)|" + options.query
        if let cached = expressions.object(forKey: key as NSString) { return cached }
        let pattern = options.regularExpression ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        let expression = try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
        expressions.setObject(expression, forKey: key as NSString)
        return expression
    }
    static func matches(in text: String, options: ComparisonSearchOptions) -> Result<[NSRange], Error> {
        Result {
            guard !options.query.isEmpty else { return [] }
            return try matches(in: text, range: NSRange(location: 0, length: text.utf16.count), expression: expression(for: options))
        }
    }
    static func matches(in text: String, range: NSRange, expression: NSRegularExpression) throws -> [NSRange] {
        try Task.checkCancellation()
        var ranges: [NSRange] = []
        // ICU progress callbacks allow even a slow regex to observe cancellation.
        expression.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
            if Task.isCancelled { stop.pointee = true }
            else if let match { ranges.append(match.range) }
        }
        try Task.checkCancellation()
        return ranges
    }
    // Scan ordered matches and line starts together instead of scanning the whole document per match.
    static func matchingLines(matches: [NSRange], starts: [Int], length: Int) -> Set<Int> {
        var lines: Set<Int> = []
        var line = 0
        for match in matches {
            while line + 1 < starts.count && starts[line + 1] <= match.location { line += 1 }
            var endLine = line
            while endLine < starts.count {
                let start = starts[endLine]
                let end = endLine + 1 < starts.count ? starts[endLine + 1] : length + 1
                guard start < NSMaxRange(match) || (start..<end).contains(match.location) else { break }
                lines.insert(endLine)
                endLine += 1
            }
            line = max(line, endLine - 1)
        }
        return lines
    }
    static func replacing(in text: String, options: ComparisonSearchOptions, replacement: String, all: Bool, selected: NSRange? = nil) -> Result<String, Error> {
        do {
            guard !options.query.isEmpty else { return .success(text) }
            let expression = try expression(for: options)
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
            guard !matches.isEmpty else { return .success(text) }
            let targets = all ? matches : [matches.first(where: { $0.range == selected }) ?? matches.first(where: { $0.range.location >= (selected?.location ?? 0) }) ?? matches[0]]
            let value = NSMutableString(string: text)
            for match in targets.reversed() {
                let insertion = options.regularExpression ? expression.replacementString(for: match, in: text, offset: 0, template: replacement) : replacement
                value.replaceCharacters(in: match.range, with: insertion)
            }
            return .success(value as String)
        } catch { return .failure(error) }
    }
}

struct ComparisonSearchPopover: View {
    @ObservedObject private var shortcuts = KeyboardShortcuts.shared
    @Environment(\.dismiss) private var dismiss
    @Binding var options: ComparisonSearchOptions
    @Binding var replacement: String
    let matchCount: Int
    var matchIndex = 0
    var isSearching = false
    var canReplace = false
    let onNavigate: (Bool) -> Void
    var onReplace: (Bool) -> Void = { _ in }
    var onOpenEditor: (() -> Void)? = nil
    var error: String? = nil
    var onCancelSearch: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @State private var query: String?
    private var pendingQuery: String { query ?? options.query }
    private func applyQuery() { options.query = pendingQuery }
    private func navigate(_ forward: Bool) {
        applyQuery()
        DispatchQueue.main.async { onNavigate(forward) }
    }
    private func close() { applyQuery(); onClose?(); dismiss() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(comparisonSearchText("Search and replace")).fontWeight(.semibold)
            HStack {
                ComparisonSearchField(text: Binding(get: { pendingQuery }, set: { query = $0 }), placeholder: comparisonSearchText("Find"), initialFocus: true,
                    onNavigate: navigate, onEscape: close).frame(height: 24)
                HStack(spacing: 2) {
                    Button { navigate(false) } label: { ComparisonToolbarIcon(name: "chevron.up") }.buttonStyle(ComparisonToolbarButtonStyle()).configuredShortcut(.compareFindPrevious, using: shortcuts).help(comparisonSearchText("Previous match"))
                    Button { navigate(true) } label: { ComparisonToolbarIcon(name: "chevron.down") }.buttonStyle(ComparisonToolbarButtonStyle()).configuredShortcut(.compareFindNext, using: shortcuts).help(comparisonSearchText("Next match"))
                }
            }
            HStack {
                KeyViewProxy(label: comparisonSearchText("Case sensitive"), checked: options.caseSensitive) { options.caseSensitive.toggle() }
                KeyViewProxy(label: comparisonSearchText("Regular expression"), checked: options.regularExpression) { options.regularExpression.toggle() }
                if isSearching { ProgressView().controlSize(.mini); if let onCancelSearch { Button(comparisonSearchText("Cancel search"), action: onCancelSearch) } }
                Text("\(min(max(0, matchIndex), matchCount))/\(matchCount)").monospacedDigit()
            }.frame(maxWidth: .infinity).font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            ComparisonSearchField(text: $replacement, placeholder: comparisonSearchText("Replace with"),
                onNavigate: navigate, onEscape: close).frame(height: 24)
            HStack {
                if canReplace {
                    Button(comparisonSearchText("Replace")) { onReplace(false) }
                    Button(comparisonSearchText("Replace all")) { onReplace(true) }
                } else if let onOpenEditor {
                    Button(comparisonSearchText("Open editor to replace"), action: onOpenEditor)
                }
                Spacer()
            }.disabled(pendingQuery != options.query || error != nil || (canReplace && (options.query.isEmpty || matchCount == 0)))
            Text(comparisonSearchText(canReplace ? "Replacements change the draft only. Use Undo to revert." : "This preview is read-only.")).font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small).padding(14).frame(width: 400).onExitCommand(perform: close).background(ComparisonKeyboardRegion(standalone: true, commands: [.compareFind]) { _ in
            return true
        })
        .nativeFocusRoot()
        .task(id: query) {
            guard let query else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            options.query = query
        }
        .onDisappear { applyQuery() }
    }
}
