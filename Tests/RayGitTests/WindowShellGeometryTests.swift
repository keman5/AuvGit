import XCTest
@testable import RayGit

final class WindowShellGeometryTests: XCTestCase {
    func testAllEdgesAndCornersUseLocalBoundsWhileCenterPassesThrough() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 714)
        let cases: [(CGPoint, WindowShellGeometry.Edges)] = [
            (.init(x: 2, y: 350), .left), (.init(x: 998, y: 350), .right),
            (.init(x: 500, y: 2), .bottom), (.init(x: 500, y: 712), .top),
            (.init(x: 2, y: 2), [.left, .bottom]), (.init(x: 998, y: 2), [.right, .bottom]),
            (.init(x: 2, y: 712), [.left, .top]), (.init(x: 998, y: 712), [.right, .top]),
            (.init(x: 500, y: 350), []), (.init(x: -1, y: 350), [])
        ]
        for (point, edges) in cases { XCTAssertEqual(WindowShellGeometry.edges(at: point, in: bounds), edges) }
    }
    func testOppositeEdgesStayFixedAndMinimumPreventsInversionOnNegativeDisplay() {
        let initial = CGRect(x: -1400, y: 100, width: 1200, height: 800)
        let minimum = CGSize(width: 1000, height: 714)
        let leftBottom = WindowShellGeometry.resize(initial, edges: [.left, .bottom], delta: .init(x: 900, y: 900), minimum: minimum)
        XCTAssertEqual(leftBottom, CGRect(x: -1200, y: 186, width: 1000, height: 714))
        XCTAssertEqual(leftBottom.maxX, initial.maxX); XCTAssertEqual(leftBottom.maxY, initial.maxY)
        let rightTop = WindowShellGeometry.resize(initial, edges: [.right, .top], delta: .init(x: -900, y: -900), minimum: minimum)
        XCTAssertEqual(rightTop, CGRect(x: -1400, y: 100, width: 1000, height: 714))
        let expanded = WindowShellGeometry.resize(initial, edges: [.left, .top], delta: .init(x: -100, y: 50), minimum: minimum)
        XCTAssertEqual(expanded, CGRect(x: -1500, y: 100, width: 1300, height: 850))
    }
    func testRestorePreservesVisibleSecondaryDisplayAndRecoversDisconnectedDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let secondary = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        let minimum = CGSize(width: 1000, height: 714)
        let saved = CGRect(x: -1400, y: 100, width: 1200, height: 800)
        XCTAssertEqual(WindowShellGeometry.restore(saved, minimum: minimum, screens: [primary, secondary]), saved)
        XCTAssertEqual(WindowShellGeometry.restore(saved, minimum: minimum, screens: [primary]), CGRect(x: 200, y: 200, width: 1200, height: 800))
        XCTAssertNil(WindowShellGeometry.restore(CGRect(x: 0, y: 0, width: 0, height: 0), minimum: minimum, screens: [primary]))
    }
}
