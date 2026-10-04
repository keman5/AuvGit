import Foundation

/// Display-only bands. Ranges refer to original logical lines, never synthetic text.
public struct ComparisonAlignment {
    public let bands: [[Range<Int>]]
    public init(texts: [String], baseline: Int = 0, conflictBlocks: [ConflictDraft.Block] = []) {
        guard texts.indices.contains(baseline) else { bands = []; return }
        let counts = texts.map { $0.components(separatedBy: "\n").count }
        let diffs = texts.map { TextLineDiff(source: texts[baseline], target: $0) }
        if conflictBlocks.isEmpty {
            bands = Self.normalBands(texts: texts, baseline: baseline, diffs: diffs)
            return
        }
        let conflicts = conflictBlocks.map { ($0.startLine - 1)..<$0.endLine }
        let anchors = (0..<counts[baseline]).filter { line in
            !conflicts.contains(where: { $0.contains(line) }) && diffs.enumerated().allSatisfy { index, diff in
                index == baseline || !diff.sourceChangedLines.contains(line)
            }
        }
        var result: [[Range<Int>]] = []
        var positions = Array(repeating: 0, count: texts.count)
        for anchor in anchors + [counts[baseline]] {
            let ends = texts.indices.map { index in
                anchor == counts[baseline] ? counts[index] : (index == baseline ? anchor : diffs[index].sourceToTarget[anchor])
            }
            let ranges = texts.indices.map { positions[$0]..<max(positions[$0], ends[$0]) }
            let atomic = conflicts.contains { $0.overlaps(ranges[baseline]) }
            if atomic {
                result.append(ranges)
            } else {
                for row in 0..<(ranges.map(\.count).max() ?? 0) {
                    result.append(ranges.map { range in
                        let start = min(range.lowerBound + row, range.upperBound)
                        return start..<min(start + 1, range.upperBound)
                    })
                }
            }
            if anchor < counts[baseline] {
                result.append(ends.map { $0..<($0 + 1) })
                positions = ends.map { $0 + 1 }
            }
        }
        bands = result
    }

    private static func normalBands(texts: [String], baseline: Int, diffs: [TextLineDiff]) -> [[Range<Int>]] {
        let lines = texts.map { $0.components(separatedBy: "\n") }
        let count = lines[baseline].count
        var matches = Array(repeating: [Int: Int](), count: texts.count)
        var insertions = Array(repeating: [Int: [Int]](), count: texts.count)
        for pane in texts.indices {
            for line in 0..<count where !diffs[pane].sourceChangedLines.contains(line) {
                matches[pane][line] = diffs[pane].sourceToTarget[line]
            }
            for block in diffs[pane].blocks() {
                let a = Array(block.sourceLines), b = Array(block.targetLines)
                // A monotone edit path retains similar replacements alongside exact anchors,
                // so one pane's added lines cannot displace another pane's unchanged rows.
                let pairs = replacementPairs(a.map { lines[baseline][$0] }, b.map { lines[pane][$0] })
                var sourcePosition = block.sourceLines.lowerBound
                for (source, target) in pairs {
                    if let source {
                        sourcePosition = a[source] + 1
                        if let target { matches[pane][a[source]] = b[target] }
                    } else if let target {
                        insertions[pane][sourcePosition, default: []].append(b[target])
                    }
                }
            }
        }
        var positions = Array(repeating: 0, count: texts.count)
        var result: [[Range<Int>]] = []
        for slot in 0...count {
            let inserted = texts.indices.map { insertions[$0][slot] ?? [] }
            for row in 0..<(inserted.map(\.count).max() ?? 0) {
                result.append(texts.indices.map { pane in
                    guard row < inserted[pane].count else { return positions[pane]..<positions[pane] }
                    let line = inserted[pane][row]; positions[pane] = line + 1
                    return line..<(line + 1)
                })
            }
            if slot < count {
                result.append(texts.indices.map { pane in
                    guard let line = matches[pane][slot] else { return positions[pane]..<positions[pane] }
                    positions[pane] = line + 1
                    return line..<(line + 1)
                })
            }
        }
        return result
    }

    private static func replacementPairs(_ a: [String], _ b: [String]) -> [(Int?, Int?)] {
        guard a.count <= 1_000, b.count <= 1_000, a.count * b.count <= 16_000 else {
            return (0..<max(a.count, b.count)).map { ($0 < a.count ? $0 : nil, $0 < b.count ? $0 : nil) }
        }
        let sampledA = a.map { Array($0.prefix(256)) + Array($0.suffix(256)) }
        let sampledB = b.map { Array($0.prefix(256)) + Array($0.suffix(256)) }
        func cost(_ left: Int, _ right: Int) -> Double {
            let aa = sampledA[left], bb = sampledB[right]
            let denominator = max(1, max(aa.count, bb.count))
            var prefix = 0, suffix = 0
            while prefix < min(aa.count, bb.count), aa[prefix] == bb[prefix] { prefix += 1 }
            while suffix < min(aa.count, bb.count) - prefix, aa[aa.count - 1 - suffix] == bb[bb.count - 1 - suffix] { suffix += 1 }
            let similarity = Double(prefix + suffix) / Double(denominator)
            return similarity >= 0.3 ? 1 - similarity : 1
        }
        var matrix = Array(repeating: Array(repeating: 0.0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { matrix[i][0] = Double(i) * 0.6 }
        for j in 0...b.count { matrix[0][j] = Double(j) * 0.6 }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count { for j in 1...b.count {
                matrix[i][j] = min(matrix[i-1][j] + 0.6, matrix[i][j-1] + 0.6, matrix[i-1][j-1] + cost(i-1, j-1))
            } }
        }
        var i = a.count, j = b.count, result: [(Int?, Int?)] = []
        while i > 0 || j > 0 {
            if j > 0 && abs(matrix[i][j] - matrix[i][j-1] - 0.6) < 0.00001 {
                j -= 1; result.append((nil,j))
            } else if i > 0 && j > 0 && abs(matrix[i][j] - matrix[i-1][j-1] - cost(i-1, j-1)) < 0.00001 {
                i -= 1; j -= 1; result.append((i,j))
            } else { i -= 1; result.append((i,nil)) }
        }
        return result.reversed()
    }

    /// Extra space after each real line and before the first line, given measured wrapped heights.
    public func padding(lineHeights: [[Double]]) -> (before: [Double], after: [[Double]]) {
        var before = Array(repeating: 0.0, count: lineHeights.count)
        var after = lineHeights.map { Array(repeating: 0.0, count: $0.count) }
        var previous = Array<Int?>(repeating: nil, count: lineHeights.count)
        for band in bands {
            let heights = band.enumerated().map { index, range in range.reduce(0.0) { $0 + lineHeights[index][$1] } }
            let height = heights.max() ?? 0
            for index in band.indices {
                if let last = band[index].last { previous[index] = last }
                let extra = height - heights[index]
                if let line = previous[index] { after[index][line] += extra }
                else { before[index] += extra }
            }
        }
        return (before, after)
    }
}
