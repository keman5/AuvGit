import Foundation
import SwiftUI
import RayGitLocalization

struct ComparisonSearchOptions: Equatable {
    var query = ""
    var caseSensitive = false
    var regularExpression = false
}
func comparisonSearchText(_ key: String) -> String { L10n.text(key, table: "ComparisonSearch") }

enum ComparisonSearch {
    static func matches(in text: String, options: ComparisonSearchOptions) -> Result<[NSRange], Error> {
        guard !options.query.isEmpty else { return .success([]) }
        do {
            let pattern = options.regularExpression ? options.query : NSRegularExpression.escapedPattern(for: options.query)
            let expression = try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
            return .success(expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range))
        } catch { return .failure(error) }
    }
    static func replacing(in text: String, options: ComparisonSearchOptions, replacement: String, all: Bool, selected: NSRange? = nil) -> Result<String, Error> {
        do {
            guard !options.query.isEmpty else { return .success(text) }
            let pattern = options.regularExpression ? options.query : NSRegularExpression.escapedPattern(for: options.query)
            let expression = try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
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
    private func close() { onClose?(); dismiss() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(comparisonSearchText("Search and replace")).fontWeight(.semibold)
            HStack {
                ComparisonSearchField(text: $options.query, placeholder: comparisonSearchText("Find"), initialFocus: true,
                    onNavigate: onNavigate, onEscape: close).frame(height: 24)
                HStack(spacing: 2) {
                    Button { onNavigate(false) } label: { ComparisonToolbarIcon(name: "chevron.up") }.buttonStyle(ComparisonToolbarButtonStyle()).configuredShortcut(.compareFindPrevious, using: shortcuts).help(comparisonSearchText("Previous match"))
                    Button { onNavigate(true) } label: { ComparisonToolbarIcon(name: "chevron.down") }.buttonStyle(ComparisonToolbarButtonStyle()).configuredShortcut(.compareFindNext, using: shortcuts).help(comparisonSearchText("Next match"))
                }
            }
            HStack {
                Toggle(comparisonSearchText("Case sensitive"), isOn: $options.caseSensitive)
                Toggle(comparisonSearchText("Regular expression"), isOn: $options.regularExpression)
                if isSearching { ProgressView().controlSize(.mini); if let onCancelSearch { Button(comparisonSearchText("Cancel search"), action: onCancelSearch) } }
                Text("\(min(max(0, matchIndex), matchCount))/\(matchCount)").monospacedDigit()
            }.frame(maxWidth: .infinity).font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            ComparisonSearchField(text: $replacement, placeholder: comparisonSearchText("Replace with"),
                onNavigate: onNavigate, onEscape: close).frame(height: 24)
            HStack {
                if canReplace {
                    Button(comparisonSearchText("Replace")) { onReplace(false) }
                    Button(comparisonSearchText("Replace all")) { onReplace(true) }
                } else if let onOpenEditor {
                    Button(comparisonSearchText("Open editor to replace"), action: onOpenEditor)
                }
                Spacer()
            }.disabled(error != nil || (canReplace && (options.query.isEmpty || matchCount == 0)))
            Text(comparisonSearchText(canReplace ? "Replacements change the draft only. Use Undo to revert." : "This preview is read-only.")).font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small).padding(14).frame(width: 400).onExitCommand(perform: close).nativeFocusRoot()
    }
}
