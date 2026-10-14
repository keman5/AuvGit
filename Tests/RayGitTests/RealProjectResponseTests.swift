import AppKit
import SwiftUI
import GitCore
import XCTest
@testable import RayGit

@MainActor
final class RealProjectResponseTests: XCTestCase {
    private func tables(_ view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap(tables)
    }
    private struct TableImage {
        let id: String
        let pixels: Data
        let bitmap: NSBitmapImageRep
        let width: Int
        let height: Int
        let rowCount: Int
        let selectedRows: IndexSet
    }
    private func images(_ host: NSView) -> [TableImage]? {
        let tables = tables(host)
        var result: [TableImage] = []
        for id in ["filename", "history", "branch"] {
            guard let table = tables.first(where: { $0.tableColumns.first?.identifier.rawValue == id }) else { return nil }
            let rect = table.numberOfRows == 0 ? NSRect(x: 0, y: 0, width: table.bounds.width, height: 22) : table.rect(ofRow: 0)
            guard let bitmap = table.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            table.cacheDisplay(in: rect, to: bitmap)
            guard let image = bitmap.cgImage, let bytes = image.dataProvider?.data as Data? else { return nil }
            var packed = Data()
            for row in 0..<image.height {
                let start = row * image.bytesPerRow
                packed.append(bytes[start..<(start + image.width * image.bitsPerPixel / 8)])
            }
            result.append(TableImage(id: id, pixels: packed, bitmap: bitmap, width: image.width, height: image.height, rowCount: table.numberOfRows, selectedRows: table.selectedRowIndexes))
        }
        return result
    }
    private func diagnoseMismatch(repository: URL, reference: [TableImage], target: [TableImage]?, store: RepositoryStore) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-real-project-pixels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("REAL_PROJECT_PIXEL_FAILURE repository=\(repository.lastPathComponent) actualRepository=\(store.repositoryURL?.lastPathComponent ?? "nil") busy=\(store.isBusy) files=\(store.files.count) commits=\(store.commits.count) branches=\(store.branches.count) selectedPaths=\(store.selectedPaths.sorted()) artifacts=\(directory.path)")
        for expected in reference {
            let actual = target?.first { $0.id == expected.id }
            let differentBytes = actual.map { image in zip(expected.pixels, image.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } + abs(expected.pixels.count - image.pixels.count) }
            print("REAL_PROJECT_PIXEL_TABLE id=\(expected.id) match=\(actual?.pixels == expected.pixels) differingBytes=\(differentBytes.map(String.init) ?? "missing") reference=\(expected.width)x\(expected.height) referenceRows=\(expected.rowCount) referenceSelection=\(expected.selectedRows) target=\(actual.map { "\($0.width)x\($0.height) rows=\($0.rowCount) selection=\($0.selectedRows)" } ?? "missing")")
            if let png = expected.bitmap.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent(expected.id + "-reference.png")) }
            if let png = actual?.bitmap.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent(expected.id + "-target.png")) }
        }
    }
    func testNamedRealProjectsCachedTargetPixelsWithin100ms() async throws {
        try await measureRealProjectSwitch(includesConflictPreview: false)
    }
    func testNamedRealProjectsLargestConflictPreviewSwitchWithin100ms() async throws {
        try await measureRealProjectSwitch(includesConflictPreview: true)
    }
    func testNamedRealProjectsWrappedConflictPreviewSwitchWithin100ms() async throws {
        let key = "editor.wrapLines", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await measureRealProjectSwitch(includesConflictPreview: true)
    }
    private func previewTexts(_ view: NSView) -> [String] {
        if let text = view as? NSTextView {
            guard !text.isEditable else { return [] }
            var source = text.string
            source.makeContiguousUTF8()
            return [source]
        }
        return view.subviews.flatMap(previewTexts)
    }
    private func measureRealProjectSwitch(includesConflictPreview: Bool) async throws {
        guard let paths = ProcessInfo.processInfo.environment["RAYGIT_RESPONSE_REPOSITORIES"] else {
            throw XCTSkip("Opt in through validate-project-switch.sh real; repositories are only read")
        }
        let repositories = paths.split(separator: "\n").map { URL(fileURLWithPath: String($0)).standardizedFileURL }
        XCTAssertEqual(repositories.count, 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("block")
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = status ]; then
                attempts=0
                while [ -f '\(blocker.path)' ] && [ "$attempts" -lt 1000 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
            fi
        done
        GIT_OPTIONAL_LOCKS=0 exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let previous = UserDefaults.standard.object(forKey: "raygit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: "raygit.git.executablePath")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "raygit.git.executablePath") }
            else { UserDefaults.standard.removeObject(forKey: "raygit.git.executablePath") }
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        store.setApplicationActive(false)
        defer { store.closeTransientSession() }
        let host = NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: BorderlessToolbarModel(original: nil)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = EightPointFrameView(content: host)
        window.orderFront(nil)
        defer { window.close() }
        var expected: [String: [TableImage]] = [:]
        var expectedPreview: [String: [String]] = [:]
        for repo in repositories {
            await store.open(repo)
            XCTAssertEqual(store.repositoryURL?.path, repo.path)
            if includesConflictPreview, let file = store.files.filter(\.isConflict).max(by: {
                let lhs = (try? FileManager.default.attributesOfItem(atPath: repo.appendingPathComponent($0.path).path)[.size] as? NSNumber)?.intValue ?? 0
                let rhs = (try? FileManager.default.attributesOfItem(atPath: repo.appendingPathComponent($1.path).path)[.size] as? NSNumber)?.intValue ?? 0
                return lhs < rhs
            }) {
                store.selectedPaths = [file.path]
                await store.loadDiff()
                XCTAssertNotNil(store.conflictPreview)
            }
            // Capture a settled avatar, not a placeholder that an in-flight image request will replace.
            if let commit = store.commits.first, let url = CommitAvatarIdentity.url(email: commit.authorEmail) {
                _ = await CommitAvatarCache.shared.image(for: url)
            }
            store.isBusy = true
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(1)) }
            expected[repo.path] = try XCTUnwrap(images(host))
            expectedPreview[repo.path] = previewTexts(host)
            print("REAL_PROJECT_REFERENCE repository=\(repo.lastPathComponent) files=\(store.files.count) commits=\(store.commits.count) branches=\(store.branches.count)")
            store.isBusy = false
        }
        for repo in Array(repeating: repositories, count: 3).flatMap({ $0 }) {
            try Data().write(to: blocker)
            let start = ContinuousClock.now
            let opening = try XCTUnwrap(store.requestOpen(repo))
            var elapsed: Double?
            var lastImages: [TableImage]?
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                lastImages = images(host)
                if store.repositoryURL?.path == repo.path, lastImages?.map(\.pixels) == expected[repo.path]?.map(\.pixels),
                   !includesConflictPreview || previewTexts(host) == expectedPreview[repo.path] {
                    let parts = start.duration(to: .now).components
                    elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            if elapsed == nil {
                try diagnoseMismatch(repository: repo, reference: try XCTUnwrap(expected[repo.path]), target: lastImages, store: store)
            }
            try FileManager.default.removeItem(at: blocker)
            await opening.value
            let latency = try XCTUnwrap(elapsed, "Target file/history/branch pixels must all match")
            print("REAL_PROJECT_SWITCH repository=\(repo.lastPathComponent) targetPixelsMs=\(latency * 1000) includesPreview=\(includesConflictPreview)")
            XCTAssertLessThan(latency, 0.1)
        }
    }
}
