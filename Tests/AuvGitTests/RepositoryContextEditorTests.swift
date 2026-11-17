import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class RepositoryContextEditorTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }
    private func enter(_ text: String, in field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testEmptyRemoteFormCreatesRemoteInSidebarTargetWithoutChangingCurrentRepository() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try await GitRepository.initialize(at: root.appendingPathComponent("target"))
        let current = try await GitRepository.initialize(at: root.appendingPathComponent("current"))
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(current.url)
        let host = NSHostingView(rootView: RepositoryContextEditor(store: store, target: .init(path: target.url.path, editor: .remote)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 410), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<100 {
            try await settle(host)
            if descendants(host).compactMap({ $0 as? NSTextField }).contains(where: { $0.isEditable && $0.stringValue == "origin" }) { break }
        }
        func field(_ placeholder: String) throws -> NSTextField {
            try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.accessibilityLabel() == repositoryContextText(placeholder) })
        }
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.title == repositoryContextText(title) })
        }
        let name = try field("Remote name"), fetch = try field("Fetch URL"), save = try button("Save")
        XCTAssertEqual(name.stringValue, "origin")
        XCTAssertFalse(save.isEnabled)
        enter("   ", in: fetch)
        try await settle(host)
        XCTAssertFalse(save.isEnabled)
        enter("https://example.test/project.git", in: fetch)
        enter("bad name", in: name)
        try await settle(host)
        XCTAssertFalse(save.isEnabled)
        enter("origin", in: name)
        try button("Edit explicit push URL").performClick(nil)
        try await settle(host)
        let push = try field("Push URL")
        enter("ssh://example.test/push.git", in: push)
        try await settle(host)
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(window.isVisible)
        if let prefix = ProcessInfo.processInfo.environment["AUVGIT_REMOTE_EDITOR_PREVIEW"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-new-remote.png"))
        }
        save.performClick(nil)
        for _ in 0..<200 {
            try await settle(host)
            if !store.isBusy, let values = try? await target.remoteConfigurations(), !values.isEmpty { break }
        }
        XCTAssertNil(store.error)
        let values = try await target.remoteConfigurations()
        XCTAssertEqual(values.first?.name, "origin")
        XCTAssertEqual(values.first?.fetchURLs, ["https://example.test/project.git"])
        XCTAssertEqual(values.first?.pushURLs, ["ssh://example.test/push.git"])
        let refspec = try await target.workflowRead(["config", "--get", "remote.origin.fetch"])
        XCTAssertEqual(refspec.trimmingCharacters(in: .whitespacesAndNewlines), "+refs/heads/*:refs/remotes/origin/*")
        let currentRemotes = try await current.remoteConfigurations()
        XCTAssertTrue(currentRemotes.isEmpty)
        XCTAssertEqual(store.repositoryURL?.standardizedFileURL, current.url.standardizedFileURL)
    }
}
