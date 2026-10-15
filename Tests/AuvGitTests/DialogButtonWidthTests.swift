import XCTest
import AppKit
import SwiftUI
@testable import AuvGit

@MainActor
final class DialogButtonWidthTests: XCTestCase {
    func testNativeDialogButtonsKeepMinimumWidthAndGrowForLongTitles() {
        _ = NSApplication.shared
        for prominent in [false, true] {
            let short = NSHostingView(rootView: DialogButton("OK", prominent: prominent) {})
            let long = NSHostingView(rootView: DialogButton("Confirm this repository operation", prominent: prominent) {})
            XCTAssertGreaterThanOrEqual(short.fittingSize.width, 80)
            XCTAssertGreaterThan(long.fittingSize.width, short.fittingSize.width)
        }
    }

    func testNativeFocusButtonMinimumWidthDoesNotExpandUnrelatedControls() {
        _ = NSApplication.shared
        let action = NSHostingView(rootView: KeyViewProxy(label: "OK", minimumWidth: AuvGitDialogButtonStyle.minimumWidth) {})
        let ordinary = NSHostingView(rootView: KeyViewProxy(label: "OK") {})
        XCTAssertGreaterThanOrEqual(action.fittingSize.width, 80)
        XCTAssertLessThan(ordinary.fittingSize.width, 80)
    }
}
