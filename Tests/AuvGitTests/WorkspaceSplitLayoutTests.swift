import XCTest
import AppKit
@testable import AuvGit

@MainActor
final class WorkspaceSplitLayoutTests: XCTestCase {
    func testClosingTerminalRestoresAllPaneHeightsIncludingManualDividers() {
        for resizedBeforeModeChange in [false, true] {
            let split = WorkspaceSplitView(compact: false)
            for _ in 0..<3 { split.addArrangedSubview(NSView()) }
            split.setFrameSize(NSSize(width: 900, height: 800)); split.layout()
            split.setPosition(290, ofDividerAt: 0)
            let original = split.subviews.map { $0.frame.height }
            for _ in 0..<3 {
                if resizedBeforeModeChange { split.setFrameSize(NSSize(width: 900, height: 500)) }
                split.compact = true
                split.setFrameSize(NSSize(width: 900, height: 500)); split.layout()
                split.compact = false
                split.setFrameSize(NSSize(width: 900, height: 800)); split.layout()
                for (view, height) in zip(split.subviews, original) {
                    XCTAssertEqual(view.frame.height, height, accuracy: 0.01)
                }
            }
        }
    }
    func testSplitViewsUseSeparateDelegatesForSidebarActionDiscovery() throws {
        let splits: [NSSplitView] = [RepositorySidebarSplitView(), HistoryCommitSplitView(), WorkspaceSplitView(compact: false)]
        for split in splits {
            let delegate = try XCTUnwrap(split.delegate)
            XCTAssertFalse(delegate === split, "A self-delegate recursively forwards toggleSidebar: on macOS 27")
            // Only query the selector after confirming this is safe, so a regression
            // produces an assertion instead of overflowing the test process's stack.
            if delegate !== split {
                XCTAssertFalse(split.responds(to: NSSelectorFromString("toggleSidebar:")))
                XCTAssertEqual(delegate.splitView?(split, canCollapseSubview: NSView()), false)
            }
        }
    }
    func testHistoryStartsAt550AndFitsNarrowWindows() {
        let split = HistoryCommitSplitView()
        for _ in 0..<2 { split.addArrangedSubview(NSView()) }
        split.setFrameSize(NSSize(width: 854, height: 180))
        split.layout()
        XCTAssertEqual(split.subviews[0].frame.width, 550, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(split.subviews[1].frame.width, 280)
        split.setPosition(410, ofDividerAt: 0)
        split.layout()
        XCTAssertEqual(split.subviews[0].frame.width, 410, accuracy: 0.01)
    }
    func testSidebarStartsWith280PointBranchPaneAndRetainsManualDivider() {
        let split = RepositorySidebarSplitView()
        for _ in 0..<2 { split.addArrangedSubview(NSView()) }
        split.setFrameSize(NSSize(width: 240, height: 300)); split.layout()
        split.setFrameSize(NSSize(width: 240, height: 800)); split.layout()
        XCTAssertEqual(split.subviews[1].frame.height, 280, accuracy: 0.01)
        split.setFrameSize(NSSize(width: 240, height: 900)); split.layout()
        XCTAssertEqual(split.subviews[1].frame.height, 280, accuracy: 0.01)
        split.setPosition(450, ofDividerAt: 0); split.layout()
        XCTAssertEqual(split.subviews[0].frame.height, 450, accuracy: 0.01)
        let branchHeight = split.subviews[1].frame.height
        split.setFrameSize(NSSize(width: 240, height: 1000)); split.layout()
        XCTAssertEqual(split.subviews[1].frame.height, branchHeight, accuracy: 0.01)
    }
    func testInitialSmallFrameRecoversDefaultAndLaterResizesPreserveManualHeight() {
        let split = WorkspaceSplitView(compact: false)
        for _ in 0..<3 { split.addArrangedSubview(NSView()) }
        split.setFrameSize(NSSize(width: 900, height: 432))
        split.layout()
        XCTAssertLessThan(split.subviews[0].frame.height, 340)

        split.setFrameSize(NSSize(width: 900, height: 700))
        split.layout()
        XCTAssertEqual(split.subviews[0].frame.height, 340, accuracy: 0.01)

        split.setPosition(220, ofDividerAt: 0)
        XCTAssertEqual(split.subviews[0].frame.height, 220, accuracy: 0.01)
        for height in [CGFloat(650), 800] {
            split.setFrameSize(NSSize(width: 900, height: height))
            split.layout()
            XCTAssertEqual(split.subviews[0].frame.height, 220, accuracy: 0.01)
        }
    }
}
