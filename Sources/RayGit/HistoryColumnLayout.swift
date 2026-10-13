import Foundation

enum HistoryColumn: String {
    case graph, message, author, date, hash

    var minimumWidth: CGFloat {
        switch self {
        case .graph: 42
        case .message: 220
        case .author: 55
        case .date: 105
        case .hash: 65
        }
    }

    func clampedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return minimumWidth }
        return min(1600, max(minimumWidth, width))
    }

    func resizedWidth(origin: CGFloat, translation: CGFloat) -> CGFloat {
        clampedWidth(origin + translation)
    }
}

/// The compact identity uses only its content width and never exceeds 100 points.
enum HistoryColumnLayout {
    static let leadingInset: CGFloat = 4
    static let trailingInset: CGFloat = 12
    static let laneSpacing: CGFloat = 12
    static let nodeDiameter: CGFloat = 6

    static func nodeDiameter(for kind: HistoryGraphNodeKind) -> CGFloat {
        kind == .merge ? nodeDiameter + 2 : nodeDiameter
    }

    struct GraphMessageWidths {
        let graph: CGFloat
        let message: CGFloat
    }

    static func graphWidth(laneCount: Int) -> CGFloat {
        CGFloat(max(1, laneCount)) * laneSpacing
    }

    static func rowHeight(compact: Bool) -> CGFloat { compact ? 22 : 24 }

    static func graphMessageWidths(activeLaneCount: Int, maximumLaneCount: Int, maximumGraphWidth: CGFloat, baseMessageWidth: CGFloat) -> GraphMessageWidths {
        let maximumLanes = max(1, maximumLaneCount)
        let activeLanes = min(maximumLanes, max(1, activeLaneCount))
        let required = graphWidth(laneCount: maximumLanes)
        let graphBudget = maximumGraphWidth.isFinite ? max(required, maximumGraphWidth) : max(required, HistoryColumn.graph.minimumWidth)
        let graph = graphWidth(laneCount: activeLanes)
        return GraphMessageWidths(graph: graph, message: max(0, baseMessageWidth) + graphBudget - graph)
    }

    static func compactDateWidth(measuredWidth: CGFloat) -> CGFloat {
        guard measuredWidth.isFinite else { return 110 }
        return min(110, max(48, ceil(measuredWidth)))
    }

    static let compactIdentityMaximumWidth: CGFloat = 100
    static let avatarWidth: CGFloat = 18
    static let identitySpacing: CGFloat = 4

    static func compactAuthorNameWidth(measuredWidth: CGFloat, showsAvatar: Bool) -> CGFloat {
        let reserved = showsAvatar ? avatarWidth + identitySpacing : 0
        let budget = min(72, compactIdentityMaximumWidth - reserved)
        guard measuredWidth.isFinite else { return budget }
        return min(budget, max(0, ceil(measuredWidth)))
    }
}
