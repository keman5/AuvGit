import Foundation
import GitCore

/// Groups adjacent changed alignment bands, including bands with an empty side.
struct ComparisonChangeNavigation {
    let bands: [[Range<Int>]]
    init(texts: [String], baseline: Int = 0, conflicts: [ConflictDraft.Block] = [], cachedAlignment: ComparisonAlignment? = nil) {
        guard texts.indices.contains(baseline) else { bands = []; return }
        let alignment = cachedAlignment ?? ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: conflicts)
        var changed = Array(repeating: Set<Int>(), count: texts.count)
        for pane in texts.indices where pane != baseline {
            let diff = TextLineDiff(source: texts[baseline], target: texts[pane])
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
