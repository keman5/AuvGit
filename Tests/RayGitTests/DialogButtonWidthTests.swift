import XCTest
import AppKit
import SwiftUI
@testable import RayGit

@MainActor
final class DialogButtonWidthTests: XCTestCase {
    func testNativeDialogButtonsKeepMinimumWidthAndGrowForLongTitles() {
        _ = NSApplication.shared
        for prominent in [false, true] {
            let short = NSHostingView(rootView: Button("OK") {}.buttonStyle(RayGitDialogButtonStyle(prominent: prominent)))
            let long = NSHostingView(rootView: Button("Confirm this repository operation") {}.buttonStyle(RayGitDialogButtonStyle(prominent: prominent)))
            XCTAssertGreaterThanOrEqual(short.fittingSize.width, 80)
            XCTAssertGreaterThan(long.fittingSize.width, short.fittingSize.width)
        }
    }

    func testNativeFocusButtonMinimumWidthDoesNotExpandUnrelatedControls() {
        _ = NSApplication.shared
        let action = NSHostingView(rootView: KeyViewProxy(label: "OK", minimumWidth: RayGitDialogButtonStyle.minimumWidth) {})
        let ordinary = NSHostingView(rootView: KeyViewProxy(label: "OK") {})
        XCTAssertGreaterThanOrEqual(action.fittingSize.width, 80)
        XCTAssertLessThan(ordinary.fittingSize.width, 80)
    }
}
