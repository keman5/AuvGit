import Foundation
import GitCore

/// Groups adjacent changed alignment bands, including bands with an empty side.
struct ComparisonChangeNavigation {
    let bands: [[Range<Int>]]
    init(texts: [String], baseline: Int = 0, conflicts: [ConflictDraft.Block] = [], cachedAlignment: ComparisonAlignment? = nil, diffs: [Int: TextLineDiff] = [:], rules: ComparisonRules = .init(), endings: [ComparisonLineEnding] = []) {
        guard texts.indices.contains(baseline) else { bands = []; return }
        let alignment = cachedAlignment ?? ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: conflicts, rules: rules, endings: endings)
        var changed = Array(repeating: Set<Int>(), count: texts.count)
        for pane in texts.indices where pane != baseline {
            let diff = diffs[pane] ?? TextLineDiff(source: rules.textKey(texts[baseline], ending: endings.indices.contains(baseline) ? endings[baseline] : .lf), target: rules.textKey(texts[pane], ending: endings.indices.contains(pane) ? endings[pane] : .lf), rules: rules)
            changed[baseline].formUnion(diff.sourceChangedLines); changed[pane].formUnion(diff.targetChangedLines)
        }
        var result: [[Range<Int>]] = []
        var adjacent = false
        for band in alignment.bands {
            let isChanged = texts.indices.contains { !changed[$0].isDisjoint(with: band[$0]) }
                || conflicts.contains { (($0.startLine - 1)..<$0.endLine).overlaps(band[baseline]) }
            if isChanged {
                if adjacent, let previous = result.last {
                    result[result.count - 1] = zip(previous, band).map { $0.0.lowerBound..<$0.1.upperBound }
                } else { result.append(band) }
            }
            adjacent = isChanged
        }
        bands = result
    }
}

/// One bounded policy for editor bands, patch hunks, and global large-file changes.
struct ComparisonChangeTargets: Equatable {
    let previous: Int?
    let next: Int?
    let current: Int?
    init(ranges: [Range<Int>], position: Int, selected: Int? = nil) {
        let current = selected.flatMap { ranges.indices.contains($0) ? $0 : nil }
            ?? ranges.firstIndex { $0.contains(position) || ($0.isEmpty && $0.lowerBound == position) }
        self.current = current
        if let current {
            previous = current > 0 ? current - 1 : nil
            next = current + 1 < ranges.count ? current + 1 : nil
        } else {
            previous = ranges.lastIndex { $0.upperBound <= position && $0.lowerBound < position }
            next = ranges.firstIndex { $0.lowerBound > position }
        }
    }
    init(count: Int, selected: Int?) {
        self.init(ranges: (0..<max(0, count)).map { $0..<($0 + 1) }, position: selected ?? -1, selected: selected)
    }
    static let empty = ComparisonChangeTargets(count: 0, selected: nil)
    func target(forward: Bool) -> Int? { forward ? next : previous }
}
