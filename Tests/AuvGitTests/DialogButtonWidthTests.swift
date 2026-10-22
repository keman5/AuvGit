import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import AuvGit

@MainActor
final class DialogButtonWidthTests: XCTestCase {
    func testWorkspaceCommitButtonsKeepSizeWhenUntrackedCheckboxChangesDefaultAction() async throws {
        _ = NSApplication.shared
        for hasTrackedChanges in [false, true] {
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            let request = WorkspaceCommitRequest(repository: GitRepository(url: URL(fileURLWithPath: "/tmp")),
                message: "Layout only", hasTrackedChanges: hasTrackedChanges)
            let host = NSHostingView(rootView: WorkspaceCommitSheet(store: store, request: request).nativeFocusRoot())
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func buttons(_ view: NSView) -> [KeyViewProxy.Button] {
                (view as? KeyViewProxy.Button).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            func settle() async throws {
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    window.setContentSize(host.fittingSize)
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await settle()
            let checkbox = try XCTUnwrap(buttons(host).first { $0.isCheckbox })
            let actions = buttons(host).filter { !$0.isCheckbox }
            XCTAssertEqual(actions.count, 2)
            let initialSizes = actions.map(\.frame.size)
            for _ in 0..<4 {
                checkbox.performClick(nil)
                try await settle()
                for (button, initialSize) in zip(actions, initialSizes) {
                    XCTAssertEqual(button.frame.size, initialSize, "Checkbox updates must not resize either action")
                    XCTAssertEqual(button.frame.height, 28, accuracy: 0.5, "All dialog actions use a fixed height")
                }
            }
        }
    }

    func testNativeDialogButtonsKeepMinimumWidthAndGrowForLongTitles() {
        _ = NSApplication.shared
        for prominent in [false, true] {
            let short = NSHostingView(rootView: DialogButton("OK", prominent: prominent) {})
            let long = NSHostingView(rootView: DialogButton("Confirm this repository operation", prominent: prominent) {})
            let disabled = NSHostingView(rootView: DialogButton("OK", prominent: prominent) {}.disabled(true).controlSize(.mini))
            XCTAssertGreaterThanOrEqual(short.fittingSize.width, 80)
            XCTAssertGreaterThan(long.fittingSize.width, short.fittingSize.width)
            XCTAssertEqual(short.fittingSize.height, 28)
            XCTAssertEqual(long.fittingSize.height, 28)
            XCTAssertEqual(disabled.fittingSize, short.fittingSize)
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
