import Foundation

/// A history selection is a revision or a local state, never a fabricated commit.
public enum HistoryEndpoint: Hashable, Sendable, Codable {
    case commit(String)
    case index
    case workingTree

    public var id: String {
        switch self {
        case let .commit(hash): return hash
        case .index: return "@auvgit:index"
        case .workingTree: return "@auvgit:working-tree"
        }
    }
    public init(id: String) {
        switch id {
        case "@auvgit:index": self = .index
        case "@auvgit:working-tree": self = .workingTree
        default: self = .commit(id)
        }
    }
    public var revisionTitle: String {
        switch self {
        case let .commit(hash): return String(hash.prefix(8))
        case .index: return "Index"
        case .workingTree: return "Working Tree"
        }
    }
}

public enum HistoryVirtualRow: String, CaseIterable, Hashable, Sendable {
    case workingTree, index
    public var endpoint: HistoryEndpoint { self == .index ? .index : .workingTree }
    public var id: String { endpoint.id }
}

public struct HistoryComparisonRange: Equatable, Sendable, Codable {
    public let from: HistoryEndpoint
    public let to: HistoryEndpoint
    public init(from: HistoryEndpoint, to: HistoryEndpoint) { self.from = from; self.to = to }
    public var reversed: Self { Self(from: to, to: from) }
    public func target(for file: GitCommitFile) -> DiffTarget {
        .between(from: from, to: to, path: file.path, originalPath: file.originalPath)
    }
}

extension GitRepository {
    /// Default direction follows ancestry and displayed topology, never author clocks.
    public func historyComparisonRange(ids: Set<String>, orderedCommitIDs: [String]) async throws -> HistoryComparisonRange? {
        guard ids.count == 2 else { return nil }
        let endpoints = ids.map(HistoryEndpoint.init(id:))
        let ordered = endpoints.sorted { a, b in
            func rank(_ value: HistoryEndpoint) -> Int {
                switch value {
                case .workingTree: return -2
                case .index: return -1
                case let .commit(hash): return orderedCommitIDs.firstIndex(of: hash) ?? Int.max
                }
            }
            return rank(a) < rank(b)
        }
        if case let .commit(a) = ordered[0], case let .commit(b) = ordered[1] {
            let first = try await workflowRevision(a), second = try await workflowRevision(b)
            let ancestor = try await GitProcess.run(at: url, arguments: ["merge-base", "--is-ancestor", first, second], allowedCodes: [0, 1])
            if ancestor.code == 0 { return HistoryComparisonRange(from: .commit(first), to: .commit(second)) }
        }
        return HistoryComparisonRange(from: ordered[1], to: ordered[0])
    }

    /// Returns literal-path-safe Git arguments. Reverse direction is explicit.
    func historyDiffArguments(from: HistoryEndpoint, to: HistoryEndpoint) async throws -> [String] {
        switch (from, to) {
        case let (.commit(left), .commit(right)): return [try await workflowRevision(left), try await workflowRevision(right)]
        case let (.commit(left), .index): return ["--cached", try await workflowRevision(left)]
        case let (.index, .commit(right)): return ["--cached", "-R", try await workflowRevision(right)]
        case let (.commit(left), .workingTree): return [try await workflowRevision(left)]
        case let (.workingTree, .commit(right)): return ["-R", try await workflowRevision(right)]
        case (.index, .workingTree): return []
        case (.workingTree, .index): return ["-R"]
        case (.index, .index), (.workingTree, .workingTree): return []
        }
    }

    public func comparisonFiles(from: HistoryEndpoint, to: HistoryEndpoint) async throws -> [GitCommitFile] {
        guard from != to else { return [] }
        let args = try await historyDiffArguments(from: from, to: to)
        let output = try await GitProcess.run(at: url, arguments: ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-M", "-z"] + args + ["--"])
        var result: [GitCommitFile] = []
        let fields = output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i + 1 < fields.count {
            let status = fields[i], first = fields[i + 1]; i += 2
            let renamed = status.hasPrefix("R") || status.hasPrefix("C")
            let path = renamed && i < fields.count ? fields[i] : first
            if renamed { i += 1 }
            result.append(GitCommitFile(path: path, status: status, originalPath: renamed ? first : nil))
        }
        if from == .workingTree || to == .workingTree {
            let untracked = try await GitProcess.run(at: url, arguments: ["ls-files", "--others", "--exclude-standard", "-z"])
            for bytes in untracked.data.split(separator: 0) {
                let path = String(decoding: bytes, as: UTF8.self)
                let left = try await historyComparisonContent(endpoint: from, path: path)
                let right = try await historyComparisonContent(endpoint: to, path: path)
                result.removeAll { $0.path == path }
                guard left.exists != right.exists || left.data != right.data || left.gitMode != right.gitMode else { continue }
                result.append(GitCommitFile(path: path, status: !left.exists ? "A" : !right.exists ? "D" : "M"))
            }
            // Git's normal worktree diff omits untracked rename destinations.
            // Pair exact copies without guessing from names; similarity renames
            // between immutable trees/index remain handled by Git's -M above.
            var consumed = Set<String>(), renames: [GitCommitFile] = []
            for added in result where added.status == "A" {
                let target = try await historyComparisonContent(endpoint: to, path: added.path)
                guard let data = target.data else { continue }
                for deleted in result where deleted.status == "D" && !consumed.contains(deleted.path) {
                    let source = try await historyComparisonContent(endpoint: from, path: deleted.path)
                    if source.data == data, source.gitMode == target.gitMode {
                        consumed.insert(added.path); consumed.insert(deleted.path)
                        renames.append(GitCommitFile(path: added.path, status: "R100", originalPath: deleted.path))
                        break
                    }
                }
            }
            result.removeAll { consumed.contains($0.path) }; result += renames
        }
        try Task.checkCancellation()
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

public enum HistoryGraphCommand: Sendable {
    case cherryPick(commits: [String], target: String, expectedHead: String)
    case rebase(target: String, expectedHead: String, branch: String?, expectedSource: String?, commits: [String]?)
    case moveBranch(name: String, target: String, expectedSource: String)
    case reset(target: String, expectedHead: String)
}

extension GitRepository {
    /// The preview pins source and destination OIDs. Every mutable identity is
    /// checked again after confirmation; virtual row IDs cannot resolve here.
    public func executeHistoryGraphCommand(_ command: HistoryGraphCommand) async throws {
        func objectID(_ value: String) throws {
            guard [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) else { throw GitError("Invalid commit object ID") }
        }
        func checkedHead(_ expected: String) async throws {
            try objectID(expected)
            guard try await workflowRevision("HEAD") == expected else { throw GitError("HEAD changed after the graph preview. Review the operation again.") }
        }
        switch command {
        case let .moveBranch(name, target, expected):
            try objectID(target); try objectID(expected)
            guard name.hasPrefix("refs/heads/") else { throw GitError("Only local branches can be moved.") }
            _ = try await workflowRead(["check-ref-format", name])
            let branches = try await branches()
            guard let branch = branches.first(where: { !$0.isRemote && "refs/heads/" + $0.name == name }), !branch.isCurrent, branch.worktreePath == nil else {
                throw GitError("A checked-out branch must be moved with an explicit checkout/reset operation.")
            }
            guard try await workflowRevision(name) == expected else { throw GitError("The branch changed after the graph preview. Review the operation again.") }
            _ = try await workflowRevision(target)
            _ = try await workflowRead(["update-ref", name, target, expected])
        case let .reset(target, expected):
            try objectID(target); try await checkedHead(expected)
            let context = try await resetContext()
            guard context.head == expected else { throw GitError("HEAD changed after the graph preview. Review the operation again.") }
            _ = try await reset(to: target, mode: .mixed, expected: context)
        case let .cherryPick(commits, target, expected):
            try objectID(target); try await checkedHead(expected)
            guard target == expected else { throw GitError("Cherry-pick destination must be the current HEAD. Check out the destination before dragging commits.") }
            guard !commits.isEmpty else { return }
            for hash in commits { try objectID(hash); _ = try await workflowRevision(hash) }
            let traversal = try await workflowRead(["rev-list", "--topo-order"] + commits + ["--"])
            let selected = Set(commits)
            let ordered = traversal.split(separator: "\n").map(String.init).filter(selected.contains).reversed()
            for hash in ordered {
                let parents = try await workflowRead(["rev-list", "--parents", "-n", "1", hash]).split(separator: " ")
                guard parents.count <= 2 else { throw GitError("Select a mainline explicitly before cherry-picking a merge commit.") }
            }
            try await checkedHead(expected)
            _ = try await workflowRead(["cherry-pick"] + ordered)
        case let .rebase(target, expected, branchName, expectedSource, selected):
            try objectID(target); try await checkedHead(expected)
            if let branchName {
                guard branchName.hasPrefix("refs/heads/"), let expectedSource else { throw GitError("Invalid rebase branch") }
                try objectID(expectedSource)
                guard try await workflowRevision(branchName) == expectedSource else { throw GitError("The branch changed after the graph preview. Review the operation again.") }
                let branch = try await branches().first { !$0.isRemote && "refs/heads/" + $0.name == branchName }
                guard let branch, branch.isCurrent || branch.worktreePath == nil else { throw GitError("The source branch is checked out in another worktree.") }
            }
            guard try await status().isEmpty else { throw GitError("Commit or stash local changes before rebasing.") }
            var arguments = ["rebase", target] + (branchName.map { [String($0.dropFirst("refs/heads/".count))] } ?? [])
            if let selected, !selected.isEmpty {
                for hash in selected { try objectID(hash) }
                let chain = try await log(limit: selected.count, ref: "HEAD", firstParent: true)
                guard chain.count == selected.count, Set(chain.map(\.hash)) == Set(selected), chain.allSatisfy({ $0.parents.count == 1 }), let oldest = chain.last, let parent = oldest.parents.first else {
                    throw GitError("Rebase a contiguous first-parent range ending at HEAD, or drag HEAD to rebase the entire branch.")
                }
                arguments = ["rebase", "--onto", target, parent]
            }
            try await checkedHead(expected)
            _ = try await workflowRead(arguments)
        }
    }

    /// Heuristic count of files with overlapping raw changed line positions,
    /// measured in each commit's own parent coordinates. A score is a
    /// review aid, not a prediction that a rebase will or will not conflict.
    public func historyOverlap(selected: String, candidates: [String]) async throws -> [String: Int] {
        let selectedHash = try await workflowRevision(selected)
        let source = try await commitFiles(hash: selectedHash)
        var sourceRanges: [String: (lines: Set<Int>, binary: Bool)] = [:]
        for file in source {
            let patch = DiffParser.parse(try await diff(target: .commit(hash: selectedHash, path: file.path)))
            sourceRanges[file.path] = (Set(patch.lines.filter { $0.kind == .addition || $0.kind == .deletion }.compactMap { $0.oldNumber ?? $0.newNumber }), patch.isBinary)
        }
        var result: [String: Int] = [:]
        for candidate in candidates.prefix(80) where candidate != selectedHash {
            try Task.checkCancellation()
            let hash = try await workflowRevision(candidate)
            let files = try await commitFiles(hash: hash)
            var count = 0
            for file in files {
                guard let other = source.first(where: { $0.path == file.path || $0.originalPath == file.path || $0.path == file.originalPath }) else { continue }
                guard let left = sourceRanges[other.path] else { continue }
                let right = DiffParser.parse(try await diff(target: .commit(hash: hash, path: file.path)))
                let a = left.lines
                let b = Set(right.lines.filter { $0.kind == .addition || $0.kind == .deletion }.compactMap { $0.oldNumber ?? $0.newNumber })
                if left.binary || right.isBinary || !a.isDisjoint(with: b) { count += 1 }
            }
            result[candidate] = count
        }
        return result
    }
}
