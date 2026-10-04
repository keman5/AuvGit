import SwiftUI
import AppKit
import RayGitLocalization

func designCompareText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "DesignCompare", arguments: arguments)
}

struct CompareDisplayButton: View {
    let title: String
    let symbol: String
    @Binding var enabled: Bool
    var body: some View {
        Button { enabled.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 25, height: 24)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .background(enabled ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityValue(enabled ? designCompareText("On") : designCompareText("Off"))
    }
}

struct CompareBasePanel: View {
    let column: ComparisonEditorColumn
    let wraps: Bool
    let numbers: Bool
    @Binding var expanded: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain).help(designCompareText("Merge base")).accessibilityLabel(designCompareText("Merge base"))
                Label(designCompareText("Base (Common ancestor)"), systemImage: "doc.text").fontWeight(.semibold)
                if !column.detail.isEmpty { Text(column.detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(column.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help(designCompareText("Copy base")).accessibilityLabel(designCompareText("Copy base"))
            }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 28).rayGitChrome()
            if expanded {
                Divider()
                ComparisonEditor(columns: [column], wrapLines: wraps, showLineNumbers: numbers, synchronizeScroll: false, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
                    .frame(minHeight: 100, idealHeight: 170, maxHeight: 230)
            }
        }
    }
}
