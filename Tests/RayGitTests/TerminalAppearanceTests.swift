import AppKit
import XCTest
@testable import RayGit

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testAttachmentAndAppearanceChangesKeepTerminalColorsReadable() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var session: TerminalSession!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            session = TerminalSession(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView!.addSubview(session.view)

        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            let foreground = session.view.nativeForegroundColor.usingColorSpace(.sRGB)!
            let background = session.view.nativeBackgroundColor.usingColorSpace(.sRGB)!
            let terminal = session.view.getTerminal()
            XCTAssertEqual(CGFloat(terminal.foregroundColor.red) / 65535, foreground.redComponent, accuracy: 0.0001)
            XCTAssertEqual(CGFloat(terminal.backgroundColor.red) / 65535, background.redComponent, accuracy: 0.0001)
            if appearance == .darkAqua {
                XCTAssertGreaterThan(foreground.redComponent - background.redComponent, 0.6)
            } else {
                XCTAssertGreaterThan(background.redComponent - foreground.redComponent, 0.6)
            }
        }
    }
}
