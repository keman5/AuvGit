import Foundation

public struct TextChangeBlock: Equatable, Sendable {
    public let sourceLines: Range<Int>
    public let targetLines: Range<Int>
}

extension TextLineDiff {
    /// Blocks include insertions/deletions with an empty range on the unchanged side.
    public func blocks() -> [TextChangeBlock] {
        let anchors = sourceToTarget.indices.filter { !sourceChangedLines.contains($0) }.map { ($0, sourceToTarget[$0]) }
        var previous = (-1, -1)
        var result: [TextChangeBlock] = []
        for next in anchors + [(sourceToTarget.count, targetToSource.count)] {
            let source = (previous.0 + 1)..<next.0
            let target = (previous.1 + 1)..<next.1
            if !source.isEmpty || !target.isEmpty { result.append(TextChangeBlock(sourceLines: source, targetLines: target)) }
            previous = next
        }
        return result
    }
    public static func accepting(_ block: TextChangeBlock, source: String, target: String) -> String {
        let a = source.components(separatedBy: "\n")
        var b = target.components(separatedBy: "\n")
        guard block.sourceLines.upperBound <= a.count, block.targetLines.upperBound <= b.count else { return target }
        b.replaceSubrange(block.targetLines, with: a[block.sourceLines])
        return b.joined(separator: "\n")
    }
}

/// UTF-16 ranges can be applied directly to NSTextView without modifying its string.
public struct CharacterDiff: Equatable {
    public let source: [NSRange]
    public let target: [NSRange]
    public init(source a: String, target b: String) {
        // Keep this linear for pathological generated lines. Common prefix/suffix isolates the changed span.
        let aa = Array(a.utf16), bb = Array(b.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(aa.count, bb.count), aa[prefix] == bb[prefix] { prefix += 1 }
        while suffix < min(aa.count, bb.count) - prefix, aa[aa.count - suffix - 1] == bb[bb.count - suffix - 1] { suffix += 1 }
        source = aa.count - suffix > prefix ? [NSRange(location: prefix, length: aa.count - suffix - prefix)] : []
        target = bb.count - suffix > prefix ? [NSRange(location: prefix, length: bb.count - suffix - prefix)] : []
    }
}
