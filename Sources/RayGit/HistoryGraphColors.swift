import GitCore

enum HistoryGraphColorToken: CaseIterable, Equatable {
    case blue, cyan, coral, purple, amber, pink, green, gray
}

enum HistoryGraphStrokeKind: Equatable {
    case solid, dashed, dotted
}

struct HistoryGraphLineStyle: Equatable {
    let color: HistoryGraphColorToken
    let stroke: HistoryGraphStrokeKind
    let lineWidth: Double
    let variant: Int

    var dashPattern: [Double] {
        switch stroke {
        case .solid: []
        case .dashed: [7 + Double(variant % 3), 5]
        case .dotted: [1, 4 + Double(variant % 3)]
        }
    }
}

enum HistoryGraphNodeKind: Equatable {
    case ordinary, merge, remoteOnly
}

struct HistoryGraphNodeStyle: Equatable {
    let kind: HistoryGraphNodeKind
    let color: HistoryGraphColorToken
    let isHead: Bool
}

struct HistoryGraphStylePlan {
    private struct Branch {
        let name: String
        let tip: String
        let remote: Bool
    }

    private let commitsByHash: [String: GitCommit]
    private let lineStyles: [String: HistoryGraphLineStyle]
    private let branchStyles: [String: HistoryGraphLineStyle]
    private let remoteOnlyHashes: Set<String>
    private let currentCommitHashes: Set<String>
    private let remoteBranchNames: Set<String>
    private let remoteNames: Set<String>

    init(commits: [GitCommit], remoteBranchNames: Set<String>, localUnpushedHashes: Set<String>? = nil) {
        _ = localUnpushedHashes
        self.remoteBranchNames = remoteBranchNames
        remoteNames = Set(remoteBranchNames.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
        commitsByHash = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
        let parents = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0.parents) })

        var local: [Branch] = [], remote: [Branch] = []
        var current = Set<String>()
        for commit in commits {
            for reference in commit.refs {
                if Self.isCurrentReference(reference) { current.insert(commit.hash) }
                guard let branch = Self.branch(reference, tip: commit.hash, remoteBranchNames: remoteBranchNames, remoteNames: remoteNames) else { continue }
                if branch.remote { remote.append(branch) } else { local.append(branch) }
            }
        }
        currentCommitHashes = current
        local = Self.uniqueBranches(local)
        remote = Self.uniqueBranches(remote)

        let localReachable = Self.reachable(from: local.map(\.tip), parents: parents)
        let remoteReachable = Self.reachable(from: remote.map(\.tip), parents: parents)
        remoteOnlyHashes = remoteReachable.subtracting(localReachable)

        let longLived = local.filter { Self.isLongLived($0.name) }
        let features = local.filter { !Self.isLongLived($0.name) }.sorted { $0.name < $1.name }
        let longLivedReachable = Self.reachable(from: longLived.map(\.tip), parents: parents)

        var styles: [String: HistoryGraphLineStyle] = [:]
        for branch in longLived {
            styles[branch.name] = Self.longLivedStyle(branch.name)
        }
        let featurePalette: [HistoryGraphColorToken] = [.coral, .pink, .green, .gray]
        for (index, branch) in features.enumerated() {
            styles[branch.name] = HistoryGraphLineStyle(
                color: featurePalette[index % featurePalette.count],
                stroke: longLivedReachable.contains(branch.tip) ? .dashed : .dotted,
                lineWidth: 2.5,
                variant: index / featurePalette.count
            )
        }
        let localByName = Dictionary(uniqueKeysWithValues: local.compactMap { branch -> (String, HistoryGraphLineStyle)? in
            styles[branch.name].map { (branch.name, $0) }
        })
        let remoteOnly = remote.filter { branch in
            localByName[Self.localCounterpart(of: branch.name)] == nil
        }.sorted { $0.name < $1.name }
        for branch in remote {
            if let matching = localByName[Self.localCounterpart(of: branch.name)] {
                styles[branch.name] = matching
            }
        }
        for (index, branch) in remoteOnly.enumerated() {
            styles[branch.name] = HistoryGraphLineStyle(color: .purple, stroke: .dotted, lineWidth: 2.5, variant: index)
        }
        branchStyles = styles

        var hashes: [String: HistoryGraphLineStyle] = [:]
        for branch in longLived.sorted(by: {
            let left = Self.longLivedPriority($0), right = Self.longLivedPriority($1)
            return left == right ? $0.name < $1.name : left < right
        }) {
            Self.assignFirstParentLineage(from: branch.tip, style: styles[branch.name]!, parents: parents, to: &hashes)
        }
        for branch in features {
            Self.assignFirstParentLineage(from: branch.tip, style: styles[branch.name]!, parents: parents, to: &hashes)
        }
        for branch in remote.sorted(by: { $0.name < $1.name }) {
            Self.assignFirstParentLineage(from: branch.tip, style: styles[branch.name]!, parents: parents, to: &hashes)
        }
        for commit in commits where hashes[commit.hash] == nil {
            let fallback = Self.fallbackStyle(for: commit.hash, merged: longLivedReachable.contains(commit.hash))
            Self.assignFirstParentLineage(from: commit.hash, style: fallback, parents: parents, to: &hashes)
        }
        lineStyles = hashes
    }

    func lineStyle(for hash: String) -> HistoryGraphLineStyle {
        lineStyles[hash] ?? Self.fallbackStyle(for: hash, merged: false)
    }

    func nodeStyle(for hash: String) -> HistoryGraphNodeStyle {
        let kind: HistoryGraphNodeKind
        if (commitsByHash[hash]?.parents.count ?? 0) > 1 { kind = .merge }
        else if remoteOnlyHashes.contains(hash) { kind = .remoteOnly }
        else { kind = .ordinary }
        return HistoryGraphNodeStyle(kind: kind, color: lineStyle(for: hash).color, isHead: currentCommitHashes.contains(hash))
    }

    func referenceStyle(for reference: String, commitHash: String) -> HistoryGraphLineStyle {
        if isTagReference(reference) { return .init(color: .amber, stroke: .solid, lineWidth: 2, variant: 0) }
        if let branch = Self.branch(reference, tip: commitHash, remoteBranchNames: remoteBranchNames, remoteNames: remoteNames) {
            if branch.remote {
                return .init(color: .purple, stroke: .dotted, lineWidth: 2.5,
                             variant: Int(Self.stableHash(branch.name) % 4))
            }
            if let style = branchStyles[branch.name] { return style }
        }
        return lineStyle(for: commitHash)
    }

    func isCurrentCommit(_ hash: String) -> Bool { currentCommitHashes.contains(hash) }
    func isCurrentReference(_ reference: String) -> Bool { Self.isCurrentReference(reference) }
    func isTagReference(_ reference: String) -> Bool { Self.isTagReference(reference) }
    func isRemoteReference(_ reference: String) -> Bool {
        Self.branch(reference, tip: "", remoteBranchNames: remoteBranchNames, remoteNames: remoteNames)?.remote == true
    }

    private static func uniqueBranches(_ branches: [Branch]) -> [Branch] {
        var seen = Set<String>()
        return branches.filter { seen.insert($0.name).inserted }
    }

    private static func branch(_ reference: String, tip: String, remoteBranchNames: Set<String>, remoteNames: Set<String>) -> Branch? {
        let raw = reference.trimmingCharacters(in: .whitespaces)
        guard raw != "HEAD", !isTagReference(raw) else { return nil }
        let current = raw.hasPrefix("HEAD -> ")
        var name = current ? String(raw.dropFirst(8)) : raw
        if name.hasPrefix("refs/heads/") { name = String(name.dropFirst(11)) }
        if name.hasPrefix("refs/remotes/") { name = String(name.dropFirst(13)) }
        guard !name.isEmpty else { return nil }
        let remote = !current && (remoteBranchNames.contains(name) || remoteNames.contains { name.hasPrefix($0 + "/") })
        return Branch(name: name, tip: tip, remote: remote)
    }

    private static func isCurrentReference(_ reference: String) -> Bool {
        let value = reference.trimmingCharacters(in: .whitespaces)
        return value == "HEAD" || value.hasPrefix("HEAD -> ")
    }

    private static func isTagReference(_ reference: String) -> Bool {
        let value = reference.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("tag: ") || value.hasPrefix("refs/tags/")
    }

    private static func isLongLived(_ branch: String) -> Bool {
        let name = branch.split(separator: "/").last.map(String.init)?.lowercased() ?? branch.lowercased()
        return ["main", "master", "develop"].contains(name)
    }

    private static func longLivedStyle(_ branch: String) -> HistoryGraphLineStyle {
        let name = branch.split(separator: "/").last.map(String.init)?.lowercased() ?? branch.lowercased()
        return .init(color: name == "develop" ? .cyan : .blue, stroke: .solid, lineWidth: name == "develop" ? 3 : 3.5, variant: 0)
    }

    private static func longLivedPriority(_ branch: Branch) -> Int {
        let name = branch.name.split(separator: "/").last.map(String.init)?.lowercased() ?? branch.name.lowercased()
        return switch name {
        case "main": 0
        case "master": 1
        default: 2
        }
    }

    private static func localCounterpart(of remote: String) -> String {
        remote.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? remote
    }

    private static func reachable(from tips: [String], parents: [String: [String]]) -> Set<String> {
        var result = Set<String>(), pending = tips
        while let hash = pending.popLast() {
            guard result.insert(hash).inserted else { continue }
            pending.append(contentsOf: parents[hash] ?? [])
        }
        return result
    }

    private static func assignFirstParentLineage(from tip: String, style: HistoryGraphLineStyle,
                                                 parents: [String: [String]], to output: inout [String: HistoryGraphLineStyle]) {
        var hash: String? = tip
        while let current = hash, output[current] == nil {
            output[current] = style
            hash = parents[current]?.first
        }
    }

    private static func fallbackStyle(for hash: String, merged: Bool) -> HistoryGraphLineStyle {
        let palette: [HistoryGraphColorToken] = [.coral, .pink, .green, .gray]
        let value = stableHash(hash)
        return .init(color: palette[Int(value % UInt64(palette.count))], stroke: merged ? .dashed : .dotted,
                     lineWidth: 2.5, variant: Int((value / UInt64(palette.count)) % 4))
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
