import Foundation
import GitCore

struct ComparisonEditRequest: Equatable, Sendable {
    let ids: [String]
    let texts: [String]
    let language: String
    let syntax: Bool
    let characters: Bool
    let conflict: Bool
    var baseline: Int { conflict ? (ids.firstIndex(of: "worktree") ?? 0) : 0 }
}

struct ComparisonEditAnalysis: Sendable {
    let diffs: [String: TextLineDiff]
    let alignment: ComparisonAlignment
    let tokens: [[SyntaxToken]]
    let characters: [String: [Int: CharacterDiff]]
    let conflicts: [ConflictDraft.Block]
    let navigation: [[Range<Int>]]
}

/// Serial per editor: superseded edits cannot launch overlapping full-document analyses.
actor ComparisonEditWorker {
    private var previous: (ComparisonEditRequest, ComparisonEditAnalysis)?
    func prepare(_ request: ComparisonEditRequest) throws -> ComparisonEditAnalysis {
        try Task.checkCancellation()
        var diffs: [String: TextLineDiff] = [:]
        for source in request.ids.indices {
            for target in request.ids.indices where source != target {
                try Task.checkCancellation()
                let key = request.ids[source] + "→" + request.ids[target]
                if let (old, result) = previous, old.ids == request.ids,
                   old.texts[source] == request.texts[source], old.texts[target] == request.texts[target], let diff = result.diffs[key] {
                    diffs[key] = diff
                } else { diffs[key] = TextLineDiff(source: request.texts[source], target: request.texts[target]) }
            }
        }
        let tokens = try request.ids.indices.map { index -> [SyntaxToken] in
            try Task.checkCancellation()
            guard request.syntax else { return [] }
            if let (old, result) = previous, old.ids == request.ids, old.syntax, old.language == request.language, old.texts[index] == request.texts[index] { return result.tokens[index] }
            return SyntaxHighlighter.tokens(in: request.texts[index], path: request.language)
        }
        var characters: [String: [Int: CharacterDiff]] = [:]
        if request.characters, let source = request.texts.first {
            let sourceLines = source.components(separatedBy: "\n")
            for target in request.ids.indices.dropFirst() {
                let lines = request.texts[target].components(separatedBy: "\n")
                guard let diff = diffs[request.ids[0] + "→" + request.ids[target]] else { continue }
                for block in diff.blocks() {
                    for (a, b) in zip(block.sourceLines, block.targetLines) {
                        try Task.checkCancellation()
                        characters[request.ids[target], default: [:]][b] = CharacterDiff(source: sourceLines[a], target: lines[b])
                    }
                }
            }
        }
        try Task.checkCancellation()
        let conflicts = request.conflict ? ConflictDraft.blocks(in: request.texts[request.baseline]) : []
        let alignmentDiffs = request.ids.indices.map { target in
            diffs[request.ids[request.baseline] + "→" + request.ids[target]] ?? TextLineDiff(source: request.texts[request.baseline], target: request.texts[target])
        }
        let alignment = ComparisonAlignment(texts: request.texts, baseline: request.baseline, conflictBlocks: conflicts, diffs: alignmentDiffs)
        let navigation = ComparisonChangeNavigation(texts: request.texts, baseline: request.baseline, conflicts: conflicts,
            cachedAlignment: alignment, diffs: Dictionary(uniqueKeysWithValues: alignmentDiffs.enumerated().map { ($0.offset, $0.element) })).bands
        try Task.checkCancellation()
        let result = ComparisonEditAnalysis(diffs: diffs, alignment: alignment, tokens: tokens, characters: characters, conflicts: conflicts, navigation: navigation)
        previous = (request, result)
        return result
    }
}
