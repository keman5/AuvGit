import Foundation

/// Conflict choices affect supplied text only, never the index or disk.
public enum ConflictDraft {
    public enum Side: Sendable { case ours, theirs, base, oursThenTheirs, theirsThenOurs }
    public struct Block: Sendable {
        public let range: NSRange
        public let startLine: Int
        public let endLine: Int
        public let ours: String
        public let theirs: String
        public let base: String?
    }
    public struct Replacement: Sendable {
        public let range: NSRange
        public let text: String
    }
    /// Conservative detection also flags malformed markers that cannot form a selectable block.
    public static func hasConflictMarkers(in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { rawLine in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("<<<<<<<") || line.hasPrefix("|||||||") || line.hasPrefix(">>>>>>>") { return true }
            return line.count >= 7 && line.allSatisfy { $0 == "=" }
        }
    }
    public static func blocks(in text: String) -> [Block] {
        let source = text as NSString
        let lines = text.components(separatedBy: "\n")
        var offsets = [0]
        for line in lines { offsets.append(offsets.last! + line.utf16.count + 1) }
        func marker(_ line: String, _ character: Character, width: Int? = nil) -> Int? {
            let count = line.prefix(while: { $0 == character }).count
            guard count >= 7, width == nil || width == count else { return nil }
            let suffix = line.dropFirst(count).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard suffix.isEmpty || (character != "=" && suffix.first == " ") else { return nil }
            return count
        }
        func content(_ start: Int, _ end: Int) -> String {
            source.substring(with: NSRange(location: offsets[start], length: offsets[end] - offsets[start]))
        }
        var result: [Block] = [], start: Int?, base: Int?, divider: Int?, width = 7
        for (index, line) in lines.enumerated() {
            if let count = marker(line, "<", width: start == nil ? nil : width) {
                guard start == nil else { return [] }
                start = index; base = nil; divider = nil; width = count
            } else if let first = start {
                if marker(line, "|", width: width) != nil {
                    guard base == nil, divider == nil else { return [] }; base = index
                } else if marker(line, "=", width: width) != nil {
                    guard divider == nil else { return [] }; divider = index
                } else if marker(line, ">", width: width) != nil {
                    guard let middle = divider else { return [] }
                    let end = min(offsets[index + 1], source.length)
                    result.append(Block(range: NSRange(location: offsets[first], length: end - offsets[first]), startLine: first + 1, endLine: index + 1, ours: content(first + 1, base ?? middle), theirs: content(middle + 1, index), base: base.map { content($0 + 1, middle) }))
                    start = nil
                }
            }
        }
        return start == nil ? result : []
    }
    /// Parses afresh so the block number refers to the current draft.
    public static func replacement(accepting side: Side, block index: Int, in text: String) -> Replacement? {
        let blocks = blocks(in: text)
        guard blocks.indices.contains(index) else { return nil }
        let block = blocks[index]
        let replacement: String?
        switch side { case .ours: replacement = block.ours; case .theirs: replacement = block.theirs; case .base: replacement = block.base; case .oursThenTheirs: replacement = block.ours + block.theirs; case .theirsThenOurs: replacement = block.theirs + block.ours }
        guard let replacement else { return nil }
        return Replacement(range: block.range, text: replacement)
    }
    public static func accepting(_ side: Side, block index: Int, in text: String) -> String? {
        guard let edit = replacement(accepting: side, block: index, in: text) else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }
    /// NSTextView positions are UTF-16 offsets; the newline following a marker belongs to its block.
    public static func blockIndex(atUTF16Offset offset: Int, in text: String) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        return blocks(in: text).firstIndex { block in
            NSLocationInRange(offset, block.range) ||
            (offset == text.utf16.count && NSMaxRange(block.range) == offset && !text.hasSuffix("\n"))
        }
    }
}
