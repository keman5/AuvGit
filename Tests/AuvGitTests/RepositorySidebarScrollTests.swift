import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

@MainActor
final class RepositorySidebarScrollTests: XCTestCase {
    func testSwitchingProjectsPreservesBottomScrollPositionWithoutTakingFocus() async throws {
        let first = RepositoryStore(persistsSession: false)
        let second = RepositoryStore(persistsSession: false)
        let projects = WorkspaceProjects(initial: first)
        second.workspaceProjects = projects
        defer { first.closeTransientSession(); second.closeTransientSession() }
        let paths = (0..<60).map { "/fixture/project-\($0)" }
        first.recentPaths = paths; second.recentPaths = paths
        let firstHost = host(first, active: true)
        let secondHost = host(second, active: false)
        let firstWindow = window(firstHost), secondWindow = window(secondHost)
        defer { firstWindow.close(); secondWindow.close() }
        await settle(firstHost, secondHost)
        let outgoing = try XCTUnwrap(scrollView(in: firstHost))
        let incoming = try XCTUnwrap(scrollView(in: secondHost))
        let bottom = try XCTUnwrap(outgoing.documentView).bounds.height - outgoing.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 500)
        outgoing.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        outgoing.reflectScrolledClipView(outgoing.contentView)
        await settle(firstHost, secondHost)
        let expected = outgoing.contentView.bounds.origin.y
        let responder = secondWindow.firstResponder

        firstHost.rootView = sidebar(first, active: false)
        secondHost.rootView = sidebar(second, active: true)
        await settle(firstHost, secondHost)

        XCTAssertEqual(incoming.contentView.bounds.origin.y, expected, accuracy: 1,
                       "The incoming project's sidebar must keep the viewport from the clicked project")
        XCTAssertTrue(secondWindow.firstResponder === responder, "Restoring scroll must not move keyboard focus")

        incoming.contentView.scroll(to: NSPoint(x: 0, y: expected - 150))
        incoming.reflectScrolledClipView(incoming.contentView)
        await settle(firstHost, secondHost)
        // A hidden sidebar's layout must not overwrite the visible list position.
        outgoing.contentView.scroll(to: .zero)
        secondHost.rootView = sidebar(second, active: false)
        firstHost.rootView = sidebar(first, active: true)
        await settle(firstHost, secondHost)
        XCTAssertEqual(outgoing.contentView.bounds.origin.y, expected - 150, accuracy: 1)
    }

    func testRecreatedSidebarRestoresViewportBeforeOutgoingHostDeactivatesAndClampsShortLists() async throws {
        let store = RepositoryStore(persistsSession: false)
        let projects = WorkspaceProjects(initial: store)
        defer { store.closeTransientSession() }
        let paths = (0..<60).map { "/fixture/project-\($0)" }
        store.recentPaths = paths
        let originalHost = host(store, active: true)
        let originalWindow = window(originalHost)
        defer { originalWindow.close() }
        await settle(originalHost)
        let original = try XCTUnwrap(scrollView(in: originalHost))
        original.contentView.scroll(to: NSPoint(x: 0, y: 800))
        await settle(originalHost)

        let recreatedHost = host(store, active: true)
        let recreatedWindow = window(recreatedHost)
        defer { recreatedWindow.close() }
        await settle(recreatedHost)
        originalHost.rootView = sidebar(store, active: false)
        await settle(originalHost, recreatedHost)
        let recreated = try XCTUnwrap(scrollView(in: recreatedHost))
        XCTAssertEqual(recreated.contentView.bounds.origin.y, 800, accuracy: 1)

        store.recentPaths = Array(paths.prefix(2))
        await settle(originalHost, recreatedHost)
        XCTAssertEqual(recreated.contentView.bounds.origin.y, 0, accuracy: 1)
        recreatedHost.rootView = sidebar(store, active: false)
        await settle(recreatedHost)
        store.recentPaths = paths
        originalHost.rootView = sidebar(store, active: true)
        await settle(originalHost, recreatedHost)
        XCTAssertEqual(original.contentView.bounds.origin.y, 0, accuracy: 1,
                       "Removing projects must not leave a stale offset for the next activation")
        withExtendedLifetime(projects) {}
    }

    private func sidebar(_ store: RepositoryStore, active: Bool) -> AnyView {
        AnyView(RepositorySidebar(store: store, onAction: { _, _ in }, isActiveProject: active))
    }

    private func host(_ store: RepositoryStore, active: Bool) -> NSHostingView<AnyView> {
        NSHostingView(rootView: sidebar(store, active: active))
    }

    private func window(_ host: NSHostingView<AnyView>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func settle(_ hosts: NSView...) async {
        for _ in 0..<6 {
            for host in hosts { host.layoutSubtreeIfNeeded() }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
