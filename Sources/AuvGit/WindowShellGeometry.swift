import Foundation

enum WindowShellGeometry {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }
    static func edges(at point: CGPoint, in bounds: CGRect, margin: CGFloat = 5) -> Edges {
        guard bounds.contains(point) else { return [] }
        var edges: Edges = []
        if point.x < bounds.minX + margin { edges.insert(.left) }
        if point.x > bounds.maxX - margin { edges.insert(.right) }
        if point.y < bounds.minY + margin { edges.insert(.bottom) }
        if point.y > bounds.maxY - margin { edges.insert(.top) }
        return edges
    }
    static func resize(_ initial: CGRect, edges: Edges, delta: CGPoint, minimum: CGSize) -> CGRect {
        var frame = initial
        if edges.contains(.left) { frame.origin.x = min(initial.maxX - minimum.width, initial.minX + delta.x); frame.size.width = initial.maxX - frame.minX }
        if edges.contains(.right) { frame.size.width = max(minimum.width, initial.width + delta.x) }
        if edges.contains(.bottom) { frame.origin.y = min(initial.maxY - minimum.height, initial.minY + delta.y); frame.size.height = initial.maxY - frame.minY }
        if edges.contains(.top) { frame.size.height = max(minimum.height, initial.height + delta.y) }
        return frame
    }
    static func restore(_ saved: CGRect, minimum: CGSize, screens: [CGRect]) -> CGRect? {
        guard saved.origin.x.isFinite, saved.origin.y.isFinite, saved.width.isFinite, saved.height.isFinite, saved.width > 0, saved.height > 0 else { return nil }
        var result = saved
        result.size.width = max(minimum.width, result.width)
        result.size.height = max(minimum.height, result.height)
        let title = CGRect(x: result.minX, y: result.maxY - 34, width: result.width, height: 34)
        if screens.contains(where: { title.intersection($0).width >= 80 && title.intersection($0).height >= 20 }) { return result }
        guard let screen = screens.first else { return result }
        result.origin = CGPoint(x: screen.minX + max(0, (screen.width - result.width) / 2), y: screen.maxY - result.height)
        return result
    }
}
