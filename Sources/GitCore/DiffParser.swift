import Foundation

public enum DiffLineKind: Sendable { case context, addition, deletion, metadata, hunk }
public struct DiffLine: Sendable {
    public let kind: DiffLineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}
public struct DiffHunk: Sendable {
    public let header: String
    public let lineIndex: Int
    public let oldStart: Int
    public let newStart: Int
}
public struct ParsedDiff: Sendable {
    public let lines: [DiffLine]
    public let hunks: [DiffHunk]
    public let isBinary: Bool
    public let isTruncated: Bool
}
public enum DiffParser {
    public static func parse(_ text: String, maximumLines: Int = 20_000) -> ParsedDiff {
        var lines: [DiffLine] = [], hunks: [DiffHunk] = []
        var old = 0, new = 0, inHunk = false, binary = false, truncated = false
        let pattern = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        // Enumerate rather than split the entire input, bounding allocation for large patches.
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { substring, _, _, stop in
            guard lines.count < max(1, maximumLines) else { truncated = true; stop = true; return }
            let raw = substring ?? ""
            if raw.hasPrefix("diff --git ") { inHunk = false }
            if raw.hasPrefix("Binary files ") || raw == "GIT binary patch" { binary = true; inHunk = false }
            if let match = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let a = Range(match.range(at: 1), in: raw), let b = Range(match.range(at: 2), in: raw) {
                old = Int(raw[a]) ?? 0; new = Int(raw[b]) ?? 0; inHunk = true
                hunks.append(DiffHunk(header: raw, lineIndex: lines.count, oldStart: old, newStart: new))
                lines.append(DiffLine(kind: .hunk, text: raw, oldNumber: nil, newNumber: nil)); return
            }
            let kind: DiffLineKind
            var oldNumber: Int?, newNumber: Int?
            if inHunk && raw.hasPrefix("+") { kind = .addition; newNumber = new; new += 1 }
            else if inHunk && raw.hasPrefix("-") { kind = .deletion; oldNumber = old; old += 1 }
            else if inHunk && raw.hasPrefix(" ") { kind = .context; oldNumber = old; newNumber = new; old += 1; new += 1 }
            else { kind = .metadata }
            let content = kind == .addition || kind == .deletion || kind == .context ? String(raw.dropFirst()) : raw
            lines.append(DiffLine(kind: kind, text: content, oldNumber: oldNumber, newNumber: newNumber))
        }
        return ParsedDiff(lines: lines, hunks: hunks, isBinary: binary, isTruncated: truncated)
    }
}
