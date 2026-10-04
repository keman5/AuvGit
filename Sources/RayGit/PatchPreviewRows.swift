import Foundation
import GitCore

struct PatchPreviewRow {
    let left: DiffLine?
    let right: DiffLine?
    let hunk: Int?
    var isChange: Bool { [left, right].compactMap { $0 }.contains { $0.kind == .addition || $0.kind == .deletion } }
}
enum PatchPreviewRows {
    static func make(_ diff: ParsedDiff, sideBySide: Bool, compact: Bool) -> [PatchPreviewRow] {
        var result: [PatchPreviewRow] = [], index = 0, hunk: Int?
        while index < diff.lines.count {
            let line = diff.lines[index]
            if line.kind == .hunk { hunk = (hunk ?? -1) + 1; index += 1; continue }
            if line.kind == .metadata || (compact && line.kind == .context) { index += 1; continue }
            if sideBySide && (line.kind == .addition || line.kind == .deletion) {
                var removed: [DiffLine] = [], added: [DiffLine] = []
                while index < diff.lines.count {
                    let item = diff.lines[index]
                    if item.kind == .metadata && item.text == "\\ No newline at end of file" { index += 1; continue }
                    guard [.addition, .deletion].contains(item.kind) else { break }
                    if item.kind == .deletion { removed.append(item) } else { added.append(item) }
                    index += 1
                }
                if removed.isEmpty { result += added.map { PatchPreviewRow(left: nil, right: $0, hunk: hunk) } }
                else if added.isEmpty { result += removed.map { PatchPreviewRow(left: $0, right: nil, hunk: hunk) } }
                else {
                    let alignment = ComparisonAlignment(texts: [removed.map(\.text).joined(separator: "\n"), added.map(\.text).joined(separator: "\n")])
                    result += alignment.bands.compactMap { band in
                        let left = band[0].first.flatMap { removed.indices.contains($0) ? removed[$0] : nil }
                        let right = band[1].first.flatMap { added.indices.contains($0) ? added[$0] : nil }
                        return left == nil && right == nil ? nil : PatchPreviewRow(left: left, right: right, hunk: hunk)
                    }
                }
            } else {
                result.append(PatchPreviewRow(left: line, right: sideBySide ? line : nil, hunk: hunk)); index += 1
            }
        }
        return result
    }
}
