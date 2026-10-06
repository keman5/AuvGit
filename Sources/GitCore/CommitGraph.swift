import Foundation

/// A topologically ordered log retains unresolved parents as lanes at its lower frontier.
public struct CommitGraph: Sendable {
    public struct Segment: Hashable, Sendable {
        public let fromLane: Int
        public let toLane: Int
        public let fromY: Double
        public let toY: Double
        public let colorLane: Int
    }
    public struct Row: Sendable {
        public let hash: String
        public let nodeLane: Int
        public let laneCount: Int
        public let segments: [Segment]
    }
    public let rows: [Row]
    public let laneCount: Int
    public let frontier: [String]

    public init(commits: [GitCommit], firstParent: Bool = false) {
        var lanes: [String] = []
        var result: [Row] = []
        var maximum = 1
        for commit in commits {
            let parents = firstParent ? Array(commit.parents.prefix(1)) : commit.parents
            let wasKnown = lanes.contains(commit.hash)
            if !wasKnown { lanes.append(commit.hash) }
            let before = lanes
            let node = before.firstIndex(of: commit.hash)!
            lanes.remove(at: node)
            var insertion = min(node, lanes.count)
            for parent in parents where !lanes.contains(parent) {
                lanes.insert(parent, at: insertion)
                insertion += 1
            }
            var segments: [Segment] = []
            for (index, hash) in before.enumerated() {
                if hash != commit.hash || wasKnown {
                    segments.append(Segment(fromLane: index, toLane: index, fromY: 0, toY: 0.5, colorLane: index))
                }
                if hash != commit.hash, let target = lanes.firstIndex(of: hash) {
                    segments.append(Segment(fromLane: index, toLane: target, fromY: 0.5, toY: 1, colorLane: index))
                }
            }
            for parent in parents {
                if let target = lanes.firstIndex(of: parent) {
                    segments.append(Segment(fromLane: node, toLane: target, fromY: 0.5, toY: 1, colorLane: target))
                }
            }
            let count = max(1, before.count, lanes.count)
            maximum = max(maximum, count)
            result.append(Row(hash: commit.hash, nodeLane: node, laneCount: count, segments: segments))
        }
        rows = result
        laneCount = maximum
        frontier = lanes
    }
}
