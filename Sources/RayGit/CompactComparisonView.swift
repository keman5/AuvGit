import SwiftUI
import GitCore

struct CompactComparisonProjection {
    struct Line: Identifiable {
        let number: Int
        let text: String
        let addition: Bool
        var id: Int { number }
    }
    struct Band: Identifiable {
        let id: Int
        let columns: [[Line]]
    }
    let bands: [Band]
    init(columns: [ComparisonEditorColumn], conflict: Bool) {
        let texts = columns.map(\.text)
        let baseline = conflict ? columns.firstIndex(where: { $0.id == "worktree" }) ?? 0 : 0
        guard texts.indices.contains(baseline) else { bands = []; return }
        let blocks = conflict ? ConflictDraft.blocks(in: texts[baseline]) : []
        let alignment = ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: blocks)
        var changed = Array(repeating: Set<Int>(), count: texts.count)
        for pane in texts.indices where pane != baseline {
            let diff = TextLineDiff(source: texts[baseline], target: texts[pane])
            changed[baseline].formUnion(diff.sourceChangedLines)
            changed[pane].formUnion(diff.targetChangedLines)
        }
        let lines = texts.map { $0.components(separatedBy: "\n") }
        bands = alignment.bands.enumerated().compactMap { index, band in
            let isConflict = blocks.contains { (($0.startLine - 1)..<$0.endLine).overlaps(band[baseline]) }
            let selected = texts.indices.map { pane in
                band[pane].filter { isConflict || changed[pane].contains($0) }.map { line in
                    Line(number: columns[pane].firstLine + line, text: lines[pane][line], addition: conflict ? columns[pane].id == "theirs" : pane != baseline)
                }
            }
            return selected.allSatisfy(\.isEmpty) ? nil : Band(id: index, columns: selected)
        }
    }
}

/// A separate, read-only projection leaves the mounted native document and undo
/// manager intact. Each shared band has one height across all panes.
struct CompactComparisonView: View {
    let columns: [ComparisonEditorColumn]
    let conflict: Bool
    let wraps: Bool
    let numbers: Bool
    let onReturnToEditor: () -> Void
    var onRevealLine: ((String, Int) -> Void)? = nil
    private var projection: CompactComparisonProjection { CompactComparisonProjection(columns: columns, conflict: conflict) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(comparisonSearchText("Compact differences are read-only.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(comparisonSearchText("Return to editor"), action: onReturnToEditor)
            }.padding(.horizontal, 12).frame(height: 30)
            HStack(spacing: 1) {
                ForEach(columns) { column in
                    Text(column.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(column.title)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                }
            }.frame(height: 28).rayGitChrome()
            Divider()
            if projection.bands.isEmpty { Text(comparisonSearchText("No differences")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(projection.bands) { band in
                            HStack(alignment: .top, spacing: 1) {
                                ForEach(columns.indices, id: \.self) { pane in
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(band.columns[pane]) { line in
                                            HStack(alignment: .top, spacing: 4) {
                                                if numbers { Text("\(line.number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing) }
                                                Text(line.addition ? "+" : "−").foregroundStyle(line.addition ? Color.green : Color.red).frame(width: 10)
                                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                                    .fixedSize(horizontal: !wraps, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                            }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 2)
                                                .contentShape(Rectangle())
                                                .onTapGesture { onRevealLine?(columns[pane].id, line.number) }
                                                .accessibilityAction { onRevealLine?(columns[pane].id, line.number) }
                                        }
                                    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 19, alignment: .topLeading)
                                        .clipped().background(pane == columns.firstIndex(where: { $0.id == "worktree" }) && conflict ? Color.orange.opacity(0.10) : (band.columns[pane].first?.addition == true ? Color.green : Color.red).opacity(0.08))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
