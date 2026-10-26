import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

@MainActor
final class DisabledDialogButtonTests: XCTestCase {
    func testDisabledPrimaryButtonHasReadableTextInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: DialogButton("Continue", prominent: true) {}.disabled(true))
            host.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> KeyViewProxy.Button? {
                (view as? KeyViewProxy.Button) ?? view.subviews.lazy.compactMap(find).first
            }
            let button = try XCTUnwrap(find(host))
            XCTAssertFalse(button.isEnabled)
            XCTAssertFalse(button.acceptsFirstResponder)
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            func luminance(_ color: NSColor) -> Double {
                let rgb = color.usingColorSpace(.sRGB)!
                func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
            }
            var levels: [Double] = []
            for y in (bitmap.pixelsHigh / 3)..<(bitmap.pixelsHigh * 2 / 3) {
                for x in (bitmap.pixelsWide / 4)..<(bitmap.pixelsWide * 3 / 4) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.95 { levels.append(luminance(color)) }
                }
            }
            let contrast = (try XCTUnwrap(levels.max()) + 0.05) / (try XCTUnwrap(levels.min()) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Disabled title must remain readable in \(appearance)")
        }
    }
}
