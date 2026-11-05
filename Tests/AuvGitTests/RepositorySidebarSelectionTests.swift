import XCTest
@testable import AuvGit

final class RepositorySidebarSelectionTests: XCTestCase {
    private let paths = ["first", "second", "third"]

    func testReturningToAProjectReplacesItsOutgoingSelectionOnFirstActivation() {
        var first = RepositorySidebarSelection()
        var second = RepositorySidebarSelection()
        first.click("second", current: "first", shift: false, command: false, orderedIDs: paths)
        second.click("first", current: "second", shift: false, command: false, orderedIDs: paths)
        first.synchronize(primary: "first", orderedIDs: paths, reactivating: true)
        XCTAssertEqual(first.selected(primary: "first", orderedIDs: paths), ["first"])
        first.click("second", current: "first", shift: false, command: false, orderedIDs: paths)
        second.synchronize(primary: "second", orderedIDs: paths, reactivating: true)
        XCTAssertEqual(second.selected(primary: "second", orderedIDs: paths), ["second"])
    }

    func testRefreshPreservesCommandAndShiftSelectionUntilNavigation() {
        var selection = RepositorySidebarSelection()
        selection.click("third", current: "first", shift: true, command: false, orderedIDs: paths)
        selection.synchronize(primary: "first", orderedIDs: paths, reactivating: false)
        XCTAssertEqual(selection.selected(primary: "first", orderedIDs: paths), Set(paths))
        selection.click("second", current: "first", shift: false, command: true, orderedIDs: paths)
        XCTAssertEqual(selection.selected(primary: "first", orderedIDs: paths), ["first", "third"])
        selection.synchronize(primary: "first", orderedIDs: paths, reactivating: true)
        XCTAssertEqual(selection.selected(primary: "first", orderedIDs: paths), ["first"])
        selection.click("third", current: "first", shift: true, command: false, orderedIDs: paths)
        XCTAssertEqual(selection.selected(primary: "first", orderedIDs: paths), Set(paths), "Reactivation resets the range anchor to the active project")
    }

    func testExternalNavigationAndRemovedProjectsReplaceStaleSelection() {
        var selection = RepositorySidebarSelection()
        XCTAssertEqual(selection.selected(primary: "first", orderedIDs: paths), ["first"])
        selection.click("second", current: "first", shift: false, command: true, orderedIDs: paths)
        selection.synchronize(primary: "third", orderedIDs: paths, reactivating: false)
        XCTAssertEqual(selection.selected(primary: "third", orderedIDs: paths), ["third"])
        XCTAssertTrue(selection.selected(primary: "third", orderedIDs: ["first", "second"]).isEmpty)
    }
}
