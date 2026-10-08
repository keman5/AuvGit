import AppKit
import XCTest
@testable import RayGit

@MainActor
final class DialogAppearanceTests: XCTestCase {
    func testSheetUsesSharedRadiusWithoutSystemModalFrame() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled, .docModalWindow, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DialogAppearance.style(window)
        XCTAssertEqual(window.styleMask, [.resizable])
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 8)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
        XCTAssertFalse(window.isOpaque)
    }

    func testMainWindowClipsTheFrameContainingTheSheetDimmer() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = EightPointFrameView(content: NSView())
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 8)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
    }
}
