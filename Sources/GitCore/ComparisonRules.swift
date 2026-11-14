import Foundation

/// Equality rules affect comparison only; original text and offsets are retained.
public struct ComparisonRules: Equatable, Sendable {
    public var boundedComparison: Bool
    public var ignoreWhitespace: Bool
    public var ignoreCase: Bool
    public var ignoreLineEndings: Bool
    public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false, ignoreLineEndings: Bool = false, boundedComparison: Bool = false) {
        self.boundedComparison = boundedComparison
        self.ignoreWhitespace = ignoreWhitespace; self.ignoreCase = ignoreCase; self.ignoreLineEndings = ignoreLineEndings
    }
    public func textKey(_ text: String, ending: ComparisonLineEnding = .lf) -> String {
        guard !ignoreLineEndings, ending != .lf else { return text }
        return text.replacingOccurrences(of: "\n", with: (ending == .crlf ? "\r" : "\u{001E}") + "\n")
    }
    public func key(for line: String) -> String {
        var value = line
        if ignoreLineEndings, value.hasSuffix("\r") { value.removeLast() }
        if ignoreWhitespace { value.removeAll { $0 == " " || $0 == "\t" } }
        if ignoreCase { value = value.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        return value
    }
}

/// Small, offset-preserving edits shared by the editor and index operations.
public enum ComparisonTransfer {
    public enum Granularity: Sendable { case line, selection, innerLine }
    public struct Edit: Sendable {
        public let range: NSRange
        public let replacement: String
        public func applying(to text: String) -> String { (text as NSString).replacingCharacters(in: range, with: replacement) }
    }
    public static func edit(source: String, target: String, selection: NSRange, granularity: Granularity, rules: ComparisonRules = .init()) -> Edit? {
        if granularity == .selection, selection.length > 0 {
            let ns = target as NSString
            let location = min(selection.location, ns.length), end = min(NSMaxRange(selection), ns.length)
            let firstLine = ns.substring(to: location).filter { $0 == "\n" }.count
            let lastLine = ns.substring(to: max(location, end - 1)).filter { $0 == "\n" }.count
            if lastLine > firstLine {
                let lines = target.components(separatedBy: "\n"), offsets = starts(lines)
                var value = target, changed = false
                for line in (firstLine...lastLine).reversed() {
                    let start = max(location, offsets[line]), stop = min(end, offsets[line] + lines[line].utf16.count + (line < lines.count - 1 ? 1 : 0))
                    if let edit = edit(source: source, target: target, selection: NSRange(location: start, length: max(0, stop - start)), granularity: .selection, rules: rules) {
                        value = edit.applying(to: value); changed = true
                    }
                }
                return changed ? Edit(range: NSRange(location: 0, length: target.utf16.count), replacement: value) : nil
            }
        }
        let a = source.components(separatedBy: "\n"), b = target.components(separatedBy: "\n")
        let diff = TextLineDiff(source: source, target: target, rules: rules)
        let startsB = starts(b)
        let safe = min(selection.location, target.utf16.count)
        let line = startsB.lastIndex(where: { $0 <= safe }) ?? 0
        guard let block = diff.blocks().first(where: { $0.targetLines.contains(line) || ($0.targetLines.isEmpty && abs($0.targetLines.lowerBound - line) <= 1) }) else { return nil }
        let sourceLine = min(block.sourceLines.upperBound, block.sourceLines.lowerBound + max(0, line - block.targetLines.lowerBound))
        if granularity == .line {
            let targetStart = min(max(line, block.targetLines.lowerBound), block.targetLines.upperBound)
            let targetLines = targetStart..<min(targetStart + 1, block.targetLines.upperBound)
            let sourceLines = sourceLine..<min(sourceLine + 1, block.sourceLines.upperBound)
            var updated = b
            updated.replaceSubrange(targetLines, with: a[sourceLines])
            return Edit(range: NSRange(location: 0, length: target.utf16.count), replacement: updated.joined(separator: "\n"))
        }
        guard line < b.count else { return nil }
        if sourceLine >= block.sourceLines.upperBound {
            let local = min(max(0, safe - startsB[line]), b[line].utf16.count)
            let length = granularity == .innerLine ? b[line].utf16.count : min(selection.length, b[line].utf16.count - local + (line < b.count - 1 ? 1 : 0))
            guard length > 0 else { return nil }
            return Edit(range: NSRange(location: startsB[line] + (granularity == .innerLine ? 0 : local), length: length), replacement: "")
        }
        guard sourceLine < a.count else { return nil }
        let aa = a[sourceLine], bb = b[line]
        let changes = characterEdits(source: aa, target: bb)
        let local = NSRange(location: max(0, safe - startsB[line]), length: min(selection.length, max(0, bb.utf16.count - (safe - startsB[line]))))
        if granularity == .innerLine {
            guard let change = changes.first(where: { NSLocationInRange(local.location, $0.range) || $0.range.location == local.location || NSMaxRange($0.range) == local.location }) else { return nil }
            return Edit(range: NSRange(location: startsB[line] + change.range.location, length: change.range.length), replacement: change.replacement)
        }
        // Apply every character change touched by the selected text, from end to start.
        guard local.length > 0 else { return nil }
        let chosen = changes.filter { NSIntersectionRange($0.range, local).length > 0 || ($0.range.length == 0 && NSLocationInRange($0.range.location, local)) }
        guard !chosen.isEmpty else { return nil }
        var result = bb
        for change in chosen.reversed() { result = change.applying(to: result) }
        return Edit(range: NSRange(location: startsB[line], length: bb.utf16.count), replacement: result)
    }
    public static func editFromSourceSelection(source: String, target: String, selection: NSRange, granularity: Granularity) -> Edit? {
        let sourceLines = source.components(separatedBy: "\n"), targetLines = target.components(separatedBy: "\n")
        let sourceStarts = starts(sourceLines), targetStarts = starts(targetLines)
        let begin = min(selection.location, source.utf16.count), end = min(NSMaxRange(selection), source.utf16.count)
        let first = sourceStarts.lastIndex(where: { $0 <= begin }) ?? 0
        let last = sourceStarts.lastIndex(where: { $0 <= max(begin, end - 1) }) ?? first
        let diff = TextLineDiff(source: source, target: target)
        var edits: [Edit] = []
        for block in diff.blocks() where block.sourceLines.overlaps(first..<(last + 1)) || (block.sourceLines.isEmpty && abs(block.sourceLines.lowerBound - first) <= 1) {
            if block.sourceLines.isEmpty || block.targetLines.isEmpty {
                let lower = block.targetLines.lowerBound < targetStarts.count ? targetStarts[block.targetLines.lowerBound] : target.utf16.count
                let upper = block.targetLines.upperBound < targetStarts.count ? targetStarts[block.targetLines.upperBound] : target.utf16.count
                let a = max(first, block.sourceLines.lowerBound), b = min(last + 1, block.sourceLines.upperBound)
                var chosen = block.sourceLines.isEmpty ? "" : sourceLines[a..<max(a,b)].joined(separator: "\n") + (b < sourceLines.count ? "\n" : "")
                if !chosen.isEmpty, block.targetLines.isEmpty, lower == target.utf16.count, !target.isEmpty, !target.hasSuffix("\n") { chosen = "\n" + chosen }
                edits.append(Edit(range: NSRange(location: lower, length: upper - lower), replacement: chosen)); continue
            }
            let pairedCount = min(block.sourceLines.count, block.targetLines.count)
            if block.sourceLines.count > pairedCount {
                let addedStart = max(first, block.sourceLines.lowerBound + pairedCount)
                let addedEnd = min(last + 1, block.sourceLines.upperBound)
                if addedEnd > addedStart {
                    let at = block.targetLines.upperBound < targetStarts.count ? targetStarts[block.targetLines.upperBound] : target.utf16.count
                    var replacement = sourceLines[addedStart..<addedEnd].joined(separator: "\n")
                    if addedEnd < sourceLines.count { replacement += "\n" }
                    if at == target.utf16.count, !target.isEmpty, !target.hasSuffix("\n") { replacement = "\n" + replacement }
                    edits.append(Edit(range: NSRange(location: at, length: 0), replacement: replacement))
                }
            }
            if block.targetLines.count > pairedCount, let sourceLast = block.sourceLines.last, (first...last).contains(sourceLast),
               granularity == .line || (granularity == .selection && begin <= sourceStarts[sourceLast] && end >= sourceStarts[sourceLast] + sourceLines[sourceLast].utf16.count) {
                let deletedStart = block.targetLines.lowerBound + pairedCount
                let lower = deletedStart < targetStarts.count ? targetStarts[deletedStart] : target.utf16.count
                let upper = block.targetLines.upperBound < targetStarts.count ? targetStarts[block.targetLines.upperBound] : target.utf16.count
                edits.append(Edit(range: NSRange(location: lower, length: upper - lower), replacement: ""))
            }
            for line in block.sourceLines where (first...last).contains(line) {
                let targetLine = block.targetLines.lowerBound + line - block.sourceLines.lowerBound
                guard targetLines.indices.contains(targetLine), targetLine < block.targetLines.upperBound else { continue }
                if granularity == .line {
                    edits.append(Edit(range: NSRange(location: targetStarts[targetLine], length: targetLines[targetLine].utf16.count), replacement: sourceLines[line])); continue
                }
                var shift = 0
                for change in characterEdits(source: sourceLines[line], target: targetLines[targetLine]) {
                    let sourceRange = NSRange(location: sourceStarts[line] + change.range.location + shift, length: change.replacement.utf16.count)
                    let touched = granularity == .innerLine ? (begin >= sourceRange.location && begin <= NSMaxRange(sourceRange)) : (NSIntersectionRange(sourceRange, NSRange(location: begin, length: end - begin)).length > 0 || (sourceRange.length == 0 && sourceRange.location >= begin && sourceRange.location <= end))
                    if touched { edits.append(Edit(range: NSRange(location: targetStarts[targetLine] + change.range.location, length: change.range.length), replacement: change.replacement)) }
                    shift += change.replacement.utf16.count - change.range.length
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        var value = target
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { value = edit.applying(to: value) }
        return Edit(range: NSRange(location: 0, length: target.utf16.count), replacement: value)
    }
    private static func starts(_ lines: [String]) -> [Int] {
        var offset = 0
        return lines.map { line in defer { offset += line.utf16.count + 1 }; return offset }
    }
    public static func characterEdits(source: String, target: String) -> [Edit] {
        let a = Array(source), b = Array(target)
        guard a.count <= 16_384, b.count <= 16_384 else { return [] }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change { case .remove(let i, _, _): removed.insert(i); case .insert(let i, _, _): inserted.insert(i) }
        }
        let anchors = Array(zip(a.indices.filter { !removed.contains($0) }, b.indices.filter { !inserted.contains($0) }))
        let offsets = starts(b.map(String.init)).enumerated().map { $0.element - $0.offset }
        var previous = (-1, -1), result: [Edit] = []
        for next in anchors + [(a.count, b.count)] {
            let ar = (previous.0 + 1)..<next.0, br = (previous.1 + 1)..<next.1
            if !ar.isEmpty || !br.isEmpty {
                let start = br.lowerBound < offsets.count ? offsets[br.lowerBound] : target.utf16.count
                let end = br.upperBound < offsets.count ? offsets[br.upperBound] : target.utf16.count
                result.append(Edit(range: NSRange(location: start, length: end - start), replacement: String(a[ar])))
            }
            previous = next
        }
        return result
    }
}

public extension ComparisonRules {
    /// Display-only filtering. The original patch remains the authority for staging.
    func filteringPatch(_ patch: String) -> String {
        guard ignoreCase || ignoreWhitespace || ignoreLineEndings else { return patch }
        let lines = patch.components(separatedBy: "\n")
        var header: [String] = [], result: [String] = [], hunk: [String] = []
        func filteredHunk(_ values: [String]) -> [String] {
            guard let first = values.first else { return [] }
            var output = [first], i = 1, hasChanges = false
            while i < values.count {
                if values[i].hasPrefix("-") || values[i].hasPrefix("+") {
                    var removed: [String] = [], added: [String] = []
                    while i < values.count, values[i].hasPrefix("-") || values[i].hasPrefix("+") {
                        if values[i].hasPrefix("-") { removed.append(String(values[i].dropFirst())) }
                        else { added.append(String(values[i].dropFirst())) }
                        i += 1
                    }
                    if removed.count == added.count, zip(removed, added).allSatisfy({ key(for: $0.0) == key(for: $0.1) }) {
                        output += removed.map { " " + $0 }
                    } else { output += removed.map { "-" + $0 } + added.map { "+" + $0 }; hasChanges = true }
                } else { output.append(values[i]); i += 1 }
            }
            return hasChanges ? output : []
        }
        for line in lines {
            if line.hasPrefix("@@ ") {
                if !hunk.isEmpty { result += filteredHunk(hunk) }
                hunk = [line]
            } else if hunk.isEmpty { header.append(line) }
            else { hunk.append(line) }
        }
        result += filteredHunk(hunk)
        return result.isEmpty ? "" : (header + result).joined(separator: "\n")
    }
}
