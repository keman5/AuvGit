import GitCore

enum HistoryGraphColorToken: CaseIterable, Equatable {
    case blue, cyan, coral, orange, purple, amber, pink, green, gray
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
        case .dashed: [4, 3]
        case .dotted: [4, 3]
        }
    }

    func dashPhase(rowIndex: Int, fromY: Double, rowHeight: Double) -> Double {
        let period = dashPattern.reduce(0, +)
        guard period > 0 else { return 0 }
        return ((Double(rowIndex) + fromY) * rowHeight + Double(variant * 2)).truncatingRemainder(dividingBy: period)
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
    private let currentBranchName: String?
    private let currentRemoteBranchName: String?
    private let unpushedHashes: Set<String>

    init(commits: [GitCommit], remoteBranchNames: Set<String>, localUnpushedHashes: Set<String>? = nil, currentBranch: GitBranch? = nil) {
        let unpushed = localUnpushedHashes ?? []
        unpushedHashes = unpushed
        self.remoteBranchNames = remoteBranchNames
        let remoteNames = Set(remoteBranchNames.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
        self.remoteNames = remoteNames
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
        let currentReference = commits.flatMap(\.refs).first { $0.hasPrefix("HEAD -> ") }
        let currentName = currentBranch?.name ?? currentReference.flatMap {
            Self.branch($0, tip: "", remoteBranchNames: remoteBranchNames, remoteNames: remoteNames)?.name
        }
        currentBranchName = currentName
        let upstream = currentBranch?.upstream ?? (currentBranch == nil ? remote.first(where: { Self.localCounterpart(of: $0.name) == currentName })?.name : nil)
        currentRemoteBranchName = upstream

        let localReachable = Self.reachable(from: local.map(\.tip) + current.sorted(), parents: parents)
        let remoteReachable = Self.reachable(from: remote.map(\.tip), parents: parents)
        let remoteOnly = remoteReachable.subtracting(localReachable)
        remoteOnlyHashes = remoteOnly

        var styles: [String: HistoryGraphLineStyle] = [:]
        for branch in local + remote {
            let isCurrent = branch.remote ? branch.name == upstream : branch.name == currentName
            styles[branch.name] = Self.style(current: isCurrent, unpushed: !branch.remote && unpushed.contains(branch.tip), remoteOnly: remoteOnly.contains(branch.tip))
        }
        branchStyles = styles

        var hashes: [String: HistoryGraphLineStyle] = [:]
        // Current first-parent lanes win shared ancestry; merged side branches
        // remain muted. A shared commit is local even if a remote also reaches it.
        for tip in current.sorted() {
            Self.assignFirstParentLineage(from: tip, style: Self.style(current: true, unpushed: false), parents: parents, to: &hashes)
        }
        let ordered = (local + remote).sorted {
            let left = $0.remote ? $0.name == upstream : $0.name == currentName
            let right = $1.remote ? $1.name == upstream : $1.name == currentName
            if left != right { return left }
            if $0.remote != $1.remote { return !$0.remote }
            return $0.name < $1.name
        }
        for branch in ordered {
            Self.assignFirstParentLineage(from: branch.tip, style: styles[branch.name]!, parents: parents, to: &hashes)
        }
        for commit in commits where hashes[commit.hash] == nil {
            let fallback = Self.style(current: false, unpushed: false)
            Self.assignFirstParentLineage(from: commit.hash, style: fallback, parents: parents, to: &hashes)
        }
        lineStyles = Dictionary(uniqueKeysWithValues: hashes.map { hash, style in
            (hash, Self.style(current: style.color == .blue, unpushed: unpushed.contains(hash), remoteOnly: remoteOnly.contains(hash)))
        })
    }

    func lineStyle(for hash: String) -> HistoryGraphLineStyle {
        unpushedTint(lineStyles[hash] ?? Self.style(current: false, unpushed: false), hash: hash)
    }

    func lineStyle(for segment: CommitGraph.Segment) -> HistoryGraphLineStyle {
        let source = lineStyles[segment.sourceHash] ?? Self.style(current: false, unpushed: false)
        // First-parent edges belong to the child lane all the way to a shared
        // ancestor. Merge edges use the incoming side branch's lane instead.
        let lane = commitsByHash[segment.sourceHash]?.parents.first == segment.lineageHash
            ? source : (lineStyles[segment.lineageHash] ?? Self.style(current: false, unpushed: false))
        let style = lane.color == .green || lane.color == .gray
            ? lane : Self.style(current: true, unpushed: unpushedHashes.contains(segment.sourceHash))
        return unpushedTint(style, hash: segment.sourceHash)
    }

    private func unpushedTint(_ style: HistoryGraphLineStyle, hash: String) -> HistoryGraphLineStyle {
        guard unpushedHashes.contains(hash) else { return style }
        return .init(color: .orange, stroke: style.stroke, lineWidth: style.lineWidth, variant: style.variant)
    }

    func nodeStyle(for hash: String) -> HistoryGraphNodeStyle {
        let kind: HistoryGraphNodeKind
        if remoteOnlyHashes.contains(hash) { kind = .remoteOnly }
        else if (commitsByHash[hash]?.parents.count ?? 0) > 1 { kind = .merge }
        else { kind = .ordinary }
        return HistoryGraphNodeStyle(kind: kind, color: lineStyle(for: hash).color, isHead: currentCommitHashes.contains(hash))
    }

    func referenceStyle(for reference: String, commitHash: String) -> HistoryGraphLineStyle {
        if isTagReference(reference) { return .init(color: .amber, stroke: .solid, lineWidth: 1.2, variant: 0) }
        if let branch = Self.branch(reference, tip: commitHash, remoteBranchNames: remoteBranchNames, remoteNames: remoteNames) {
            if let style = branchStyles[branch.name] { return branch.remote ? style : unpushedTint(style, hash: commitHash) }
            return Self.style(current: branch.remote ? branch.name == currentRemoteBranchName : branch.name == currentBranchName, unpushed: !branch.remote && lineStyle(for: commitHash).stroke == .dashed)
        }
        return lineStyle(for: commitHash)
    }

    func referenceLabel(_ reference: String) -> String {
        if isTagReference(reference) {
            return "tag " + reference.replacingOccurrences(of: "tag: ", with: "").replacingOccurrences(of: "refs/tags/", with: "")
        }
        if let branch = Self.branch(reference, tip: "", remoteBranchNames: remoteBranchNames, remoteNames: remoteNames) {
            return (isCurrentReference(reference) ? "→ " : branch.remote ? "○ " : "● ") + branch.name
        }
        return reference
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
        let explicitRemote = name.hasPrefix("refs/remotes/")
        if name.hasPrefix("refs/heads/") { name = String(name.dropFirst(11)) }
        if name.hasPrefix("refs/remotes/") { name = String(name.dropFirst(13)) }
        guard !name.isEmpty else { return nil }
        let remote = !current && (explicitRemote || remoteBranchNames.contains(name) || remoteNames.contains { name.hasPrefix($0 + "/") })
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

    private static func style(current: Bool, unpushed: Bool, remoteOnly: Bool = false) -> HistoryGraphLineStyle {
        .init(color: remoteOnly ? .green : (current ? .blue : .gray),
              stroke: remoteOnly || unpushed || !current ? .dashed : .solid,
              lineWidth: unpushed ? (current ? 2 : 1.6) : (current ? 1.8 : 1.2), variant: 0)
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

}
