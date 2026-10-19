import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class RemoteAuthenticationLayoutTests: XCTestCase {
    func testAuthenticationLayoutKeepsFooterStableWhenAnErrorAppears() async throws {
        _ = NSApplication.shared
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://github.com/example/repo.git"))
        let request = RemoteAuthenticationRequest(repository: GitRepository(url: URL(fileURLWithPath: "/tmp/layout-fixture")),
            operation: .push, remoteName: "origin", endpoint: endpoint, preferredUsername: nil,
            preferredSSHUsername: nil, privateKey: nil, retry: { _ in })
        func host(error: String?, submitting: Bool = false) -> NSHostingView<AnyView> {
            let view = NSHostingView(rootView: AnyView(RemoteAuthenticationSheet(request: request, error: error,
                isSubmitting: submitting, submit: { _ in }, cancel: {})
                .environment(\.colorScheme, .light).background(Color.white)))
            view.appearance = NSAppearance(named: .aqua)
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            return view
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let empty = host(error: nil)
        let rejected = host(error: String(repeating: "Authentication rejected. ", count: 10))
        let submitting = host(error: nil, submitting: true)
        XCTAssertEqual(empty.fittingSize.height, rejected.fittingSize.height, accuracy: 0.5)
        XCTAssertEqual(empty.fittingSize.height, submitting.fittingSize.height, accuracy: 0.5)
        let picker = try XCTUnwrap(descendants(empty).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(picker.segmentDistribution, .fillEqually)
        let firstButtons = descendants(empty).compactMap { $0 as? KeyViewProxy.Button }
        let errorButtons = descendants(rejected).compactMap { $0 as? KeyViewProxy.Button }
        XCTAssertEqual(firstButtons.count, 2)
        for (before, after) in zip(firstButtons, errorButtons) {
            XCTAssertEqual(before.frame.height, after.frame.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(before.frame.height, 32)
        }
        let initialHeight = empty.fittingSize.height
        let initialFrames = firstButtons.map { $0.convert($0.bounds, to: empty) }
        let username = try XCTUnwrap(descendants(empty).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && !($0 is NSSecureTextField) })
        let token = try XCTUnwrap(descendants(empty).compactMap { $0 as? NSSecureTextField }.first)
        for value in ["glpat-layout-fixture", "github_pat_layout_fixture", ""] {
            username.stringValue = "layout-user"
            username.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: username))
            token.stringValue = value
            token.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: token))
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)); empty.layoutSubtreeIfNeeded() }
            XCTAssertEqual(empty.fittingSize.height, initialHeight, accuracy: 0.5)
            for (button, frame) in zip(firstButtons, initialFrames) {
                let current = button.convert(button.bounds, to: empty)
                XCTAssertEqual(current.height, frame.height, accuracy: 0.5)
                XCTAssertEqual(current.minY, frame.minY, accuracy: 0.5)
            }
        }
        if let directory = ProcessInfo.processInfo.environment["AUVGIT_AUTH_LAYOUT_PREVIEW"] {
            for (name, host) in [("empty", empty), ("error", rejected), ("submitting", submitting)] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory + "-" + name + ".png"))
            }
        }
        for index in [1, 2, 0] {
            picker.selectedSegment = index
            _ = picker.sendAction(picker.action, to: picker.target)
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)); empty.layoutSubtreeIfNeeded() }
            XCTAssertEqual(picker.selectedSegment, index)
            let buttons = descendants(empty).compactMap { $0 as? KeyViewProxy.Button }
            XCTAssertEqual(buttons.count, 2)
            for (button, frame) in zip(buttons, initialFrames) {
                XCTAssertEqual(button.frame.height, frame.height, accuracy: 0.5)
            }
        }
    }
}
