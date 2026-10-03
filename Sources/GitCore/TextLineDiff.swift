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
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let ac = a.count - prefix - suffix
        let bc = b.count - prefix - suffix
        let fallback = ac + bc > maximumDetailedLines || (ac > 0 && bc > maximumDetailedProduct / ac)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if fallback {
            removed = Set(prefix..<(a.count - suffix))
            inserted = Set(prefix..<(b.count - suffix))
        } else {
            let difference = b[prefix..<(b.count - suffix)].difference(from: a[prefix..<(a.count - suffix)])
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(prefix + offset)
                case .insert(let offset, _, _): inserted.insert(prefix + offset)
                }
            }
        }
        sourceChangedLines = removed
        targetChangedLines = inserted
        usedConservativeFallback = fallback
        let unchangedA = a.indices.filter { !removed.contains($0) }
        let unchangedB = b.indices.filter { !inserted.contains($0) }
        let anchors = Array(zip(unchangedA, unchangedB))
        sourceToTarget = Self.mapping(count: a.count, otherCount: b.count, anchors: anchors)
        targetToSource = Self.mapping(count: b.count, otherCount: a.count, anchors: anchors.map { ($0.1, $0.0) })
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
