import Foundation

/// An order-sensitive comparison of logical lines, including the final empty line after LF.
public struct TextLineDiff: Equatable {
    public let sourceChangedLines: Set<Int>
    public let targetChangedLines: Set<Int>
    public let sourceToTarget: [Int]
    public let targetToSource: [Int]
    public let usedConservativeFallback: Bool

    public init(source: String, target: String, maximumDetailedLines: Int = 4_000, maximumDetailedProduct: Int = 4_000_000) {
        let a = source.components(separatedBy: "\n")
        let b = target.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        var regions = [(a.startIndex..<a.endIndex, b.startIndex..<b.endIndex)]
        while let (sourceRegion, targetRegion) = regions.popLast() {
            var aStart = sourceRegion.lowerBound, bStart = targetRegion.lowerBound
            var aEnd = sourceRegion.upperBound, bEnd = targetRegion.upperBound
            while aStart < aEnd, bStart < bEnd, a[aStart] == b[bStart] { aStart += 1; bStart += 1 }
            while aStart < aEnd, bStart < bEnd, a[aEnd - 1] == b[bEnd - 1] { aEnd -= 1; bEnd -= 1 }
            if aStart == aEnd { inserted.formUnion(bStart..<bEnd); continue }
            if bStart == bEnd { removed.formUnion(aStart..<aEnd); continue }
            let ac = aEnd - aStart, bc = bEnd - bStart
            let large = ac + bc > maximumDetailedLines || ac > max(0, maximumDetailedProduct) / bc
            if large {
                // Unique common lines form monotone anchors. Thousands of unchanged lines
                // between sparse edits become independent tiny comparisons, not one change.
                let anchors = Self.patienceAnchors(a, aStart..<aEnd, b, bStart..<bEnd)
                if !anchors.isEmpty {
                    var previousA = aStart, previousB = bStart
                    for (nextA, nextB) in anchors {
                        if previousA < nextA || previousB < nextB { regions.append((previousA..<nextA, previousB..<nextB)) }
                        previousA = nextA + 1; previousB = nextB + 1
                    }
                    if previousA < aEnd || previousB < bEnd { regions.append((previousA..<aEnd, previousB..<bEnd)) }
                    continue
                }
                if Set(a[aStart..<aEnd]).isDisjoint(with: Set(b[bStart..<bEnd])) {
                    removed.formUnion(aStart..<aEnd); inserted.formUnion(bStart..<bEnd); continue
                }
            }
            // Repeated lines may offer no patience anchors. Use the exact edit path;
            // budget limits never turn unchanged context into a fabricated modification.
            let difference = b[bStart..<bEnd].difference(from: a[aStart..<aEnd])
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(aStart + offset)
                case .insert(let offset, _, _): inserted.insert(bStart + offset)
                }
            }
        }
        sourceChangedLines = removed
        targetChangedLines = inserted
        usedConservativeFallback = false
        let unchangedA = a.indices.filter { !removed.contains($0) }
        let unchangedB = b.indices.filter { !inserted.contains($0) }
        let anchors = Array(zip(unchangedA, unchangedB))
        sourceToTarget = Self.mapping(count: a.count, otherCount: b.count, anchors: anchors)
        targetToSource = Self.mapping(count: b.count, otherCount: a.count, anchors: anchors.map { ($0.1, $0.0) })
    }

    private static func patienceAnchors(_ a: [String], _ ar: Range<Int>, _ b: [String], _ br: Range<Int>) -> [(Int, Int)] {
        var positionsA: [String: Int] = [:], positionsB: [String: Int] = [:]
        for index in ar { positionsA[a[index]] = positionsA[a[index]] == nil ? index : -1 }
        for index in br { positionsB[b[index]] = positionsB[b[index]] == nil ? index : -1 }
        let pairs = ar.compactMap { index -> (Int, Int)? in
            guard positionsA[a[index]] == index, let target = positionsB[a[index]], target >= 0 else { return nil }
            return (index, target)
        }
        // Longest increasing target sequence, O(n log n), preserves source order.
        var tails: [Int] = [], previous = Array(repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < pairs[index].1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        guard var index = tails.last else { return [] }
        var result: [(Int, Int)] = []
        while index >= 0 { result.append(pairs[index]); index = previous[index] }
        return result.reversed()
    }

    private static func mapping(count: Int, otherCount: Int, anchors: [(Int, Int)]) -> [Int] {
        var result = Array(repeating: 0, count: count)
        var position = 0
        var previous = (-1, -1)
        for next in anchors + [(count, otherCount)] {
            while position < next.0 {
                let fraction = Double(position - previous.0) / Double(next.0 - previous.0)
                let mapped = Double(previous.1) + fraction * Double(next.1 - previous.1)
                result[position] = min(max(Int(mapped.rounded()), 0), otherCount - 1)
                position += 1
            }
            if position < count { result[position] = next.1; position += 1 }
            previous = next
        }
        return result
    }
}
