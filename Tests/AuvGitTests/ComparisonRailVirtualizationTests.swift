import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class ComparisonRailVirtualizationTests: XCTestCase {
    private final class FlippedRoot: NSView { override var isFlipped: Bool { true } }

    func testOverviewDoesNotCreateControlsUntilAccessibilityRequestsThem() throws {
        _ = NSApplication.shared
        let view = ComparisonOverviewView(frame: NSRect(x: 0, y: 0, width: 15, height: 300))
        view.markers = (0..<2_000).map {
            .init(lower: Double($0) / 2_000, upper: Double($0 + 1) / 2_000, kind: .modification, index: $0)
        }
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.subviews.isEmpty)
        var selected = -1
        view.onSelect = { selected = $0 }
        let children = try XCTUnwrap(view.accessibilityChildren()).compactMap { $0 as? NSButton }
        XCTAssertEqual(children.count, view.markers.count)
        XCTAssertTrue(try XCTUnwrap(children.last).accessibilityPerformPress())
        XCTAssertEqual(selected, 1_999)
    }

    func testRailKeepsOnlyViewportControlsAndRebindsActionsAfterScrolling() throws {
        _ = NSApplication.shared
        let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 30_000))
        text.string = String(repeating: "line\n", count: 1_000)
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        let rail = ComparisonActionRail(frame: NSRect(x: 300, y: 0, width: 56, height: 200))
        root.addSubview(text); root.addSubview(rail)
        var selected = -1
        rail.setEntries((0..<1_000).map { index in
            .init(text: text, range: NSRange(location: index * 5, length: 4), title: "Change \(index)", action: { selected = index })
        })
        let initial = rail.subviews.compactMap { $0 as? NSButton }
        XCTAssertFalse(initial.isEmpty)
        XCTAssertLessThan(initial.count, 30)
        let firstTags = Set(initial.map(\.tag))
        text.setFrameOrigin(NSPoint(x: 0, y: -8_000))
        rail.refresh()
        let next = rail.subviews.compactMap { $0 as? NSButton }
        XCTAssertFalse(next.isEmpty)
        XCTAssertLessThan(next.count, 30)
        XCTAssertTrue(firstTags.isDisjoint(with: next.map(\.tag)))
        let button = try XCTUnwrap(next.first(where: { !$0.isHidden }))
        button.performClick(nil)
        XCTAssertEqual(selected, button.tag)
        XCTAssertEqual(button.accessibilityLabel(), "Change \(button.tag)")
    }
}
