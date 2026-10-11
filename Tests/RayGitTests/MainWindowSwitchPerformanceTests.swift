import AppKit
import SwiftUI
import XCTest
import Vision
import Combine
@testable import GitCore
import RayGitLocalization
@testable import RayGit

@MainActor
final class MainWindowSwitchPerformanceTests: XCTestCase {
    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private func tables(in view: NSView) -> [NSTableView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { self.tables(in: $0) }
    }

    private func containsRetainedTable(in view: NSView) -> Bool {
        view is NSTableView || view.subviews.contains { containsRetainedTable(in: $0) }
    }

    private func rowImage(_ table: NSTableView, row: Int = 0, branchContent: Bool = false, host: NSView? = nil) -> CGImage? {
        var rect = table.numberOfRows > row ? table.rect(ofRow: row) : NSRect(x: 0, y: 0, width: table.bounds.width, height: 22)
        if branchContent {
            // Sidebar density adjusts row height asynchronously; compare its centered
            // label and icon at a fixed size rather than unrelated row spacing.
            rect.origin.y += (rect.height - 18) / 2
            rect.size = NSSize(width: 200, height: 18)
        }
        let capture = host ?? table
        if host != nil { rect = table.convert(rect, to: capture) }
        guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        capture.cacheDisplay(in: rect, to: bitmap)
        return bitmap.cgImage
    }

    private func pixels(_ image: CGImage) -> Data? {
        guard let raw = image.dataProvider?.data as Data? else { return nil }
        let bytes = image.width * image.bitsPerPixel / 8
        var packed = Data(capacity: bytes * image.height)
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            packed.append(raw[start..<(start + bytes)])
        }
        return packed
    }

    private func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func targetImages(in host: NSView, fileCount: Int = 6_001, commitCount: Int = 12) -> (files: CGImage, history: CGImage, branches: CGImage)? {
        let tables = tables(in: host)
        guard let files = tables.first(where: { $0.numberOfRows == fileCount }),
              let history = tables.first(where: { $0.numberOfRows == commitCount }),
              let branches = tables.first(where: { $0.numberOfRows == 16 }),
              let fileImage = rowImage(files), let historyImage = rowImage(history),
              let branchImage = rowImage(branches, row: 2, branchContent: true, host: host) else { return nil }
        return (fileImage, historyImage, branchImage)
    }

    func testCompleteMainWindowCachedSwitchFirstTargetLayout() async throws {
        try await measureCachedSwitch(borderless: false)
    }

    func testProductionBorderlessMainWindowCachedSwitchFirstTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true)
    }

    func testProductionBorderlessEmptyToSixThousandFilesFirstTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, emptySource: true)
    }

    func testProductionBorderlessTwoHundredCommitsAndSixThousandFilesFirstTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, commitCount: 200)
    }

    func testProductionBootstrapToShellTwoLayoutsWithLargeTrackedChanges() async throws {
        try await measureCachedSwitch(borderless: true, commitCount: 200, productionBootstrap: true)
    }

    private final class TestShellWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func testProductionBorderlessTreeCachedSwitchFirstTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, tree: true)
    }

    func testProductionBorderlessDiskCachedFirstSwitchTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, diskFirst: true)
    }

    func testProductionBorderlessDiskCachedColdPreparationFirstSwitchTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, diskFirst: true, coldPreparation: true)
    }

    func testProductionBorderlessDiskCachedFirstTreeSwitchTargetLayout() async throws {
        try await measureCachedSwitch(borderless: true, tree: true, diskFirst: true, coldPreparation: true)
    }

    private func measureCachedSwitch(borderless: Bool, tree: Bool = false, diskFirst: Bool = false, coldPreparation: Bool = false, emptySource: Bool = false, commitCount: Int = 12, productionBootstrap: Bool = false) async throws {
        _ = NSApplication.shared
        let previousFrameMode = UserDefaults.standard.object(forKey: "window.frameMode")
        if productionBootstrap { UserDefaults.standard.set("borderless", forKey: "window.frameMode") }
        defer {
            if let previousFrameMode { UserDefaults.standard.set(previousFrameMode, forKey: "window.frameMode") }
            else { UserDefaults.standard.removeObject(forKey: "window.frameMode") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repositories = ["alpha", "beta"].map { root.appendingPathComponent($0) }
        for repo in repositories {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                _ = try await GitProcess.run(at: repo, arguments: args)
            }
            if productionBootstrap {
                for index in 0..<3_000 {
                    try Data("original\n".utf8).write(to: repo.appendingPathComponent(String(format: "%@-file%05d", repo.lastPathComponent, index)))
                }
                _ = try await GitProcess.run(at: repo, arguments: ["add", "."])
            }
            for index in 0..<commitCount {
                _ = try await GitProcess.run(at: repo, arguments: ["commit", "--allow-empty", "-m", "\(repo.lastPathComponent) history \(index)"])
                if index < 12 { _ = try await GitProcess.run(at: repo, arguments: ["branch", "\(repo.lastPathComponent)-branch-\(index)"]) }
            }
            for index in 0..<(emptySource && repo == repositories[0] ? 0 : 6_001) {
                try (productionBootstrap ? Data("modified\n".utf8) : Data()).write(to: repo.appendingPathComponent(String(format: "%@-file%05d", repo.lastPathComponent, index)))
            }
        }
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "status" ] && [ -f .git/block-status ]; then
                touch .git/status-blocked
                attempts=0
                while [ ! -f .git/release-status ] && [ "$attempts" -lt 1000 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let defaults = UserDefaults.standard
        let keys = ["raygit.git.executablePath", "appLanguage", "workspace.showHiddenFiles", "sidebar.localBranchesExpanded", "sidebar.remoteBranchesExpanded", "sidebar.stashesExpanded", "preferences.historyPageSize"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defaults.set(wrapper.path, forKey: keys[0]); defaults.set("en", forKey: keys[1])
        for key in keys.dropFirst(2).dropLast() { defaults.set(true, forKey: key) }
        defaults.set(200, forKey: "preferences.historyPageSize")
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        var store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: diskFirst ? cache : nil)
        store.showsWorkspaceTree = tree
        defer { store.closeTransientSession() }
        var window: NSWindow = TestShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: borderless && !productionBootstrap ? [.borderless, .closable, .miniaturizable, .resizable] : [.titled], backing: .buffered, defer: false)
        if borderless {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.collectionBehavior = [.managed, .fullScreenPrimary]
        }
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var host: NSView = NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: BorderlessToolbarModel(original: nil), fileTree: tree))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        var content: NSView = borderless ? EightPointFrameView(content: host) : host
        var bootstrapWindow: NSWindow?
        if productionBootstrap {
            let original = window
            bootstrapWindow = original
            let bootstrapHost = NSHostingView(rootView: MainWindow(store: store).nativeFocusRoot())
            bootstrapHost.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            original.contentView = bootstrapHost
            original.orderFront(nil)
            let shellDeadline = Date().addingTimeInterval(3)
            while Date() < shellDeadline {
                bootstrapHost.layoutSubtreeIfNeeded()
                if let shell = NSApp.windows.first(where: { $0 !== original && !previousWindows.contains(ObjectIdentifier($0)) && $0.contentView is EightPointFrameView }) {
                    window = shell
                    content = try XCTUnwrap(shell.contentView)
                    host = try XCTUnwrap(content.subviews.first)
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(window !== original, "Use the shell installed by the real MainWindow bootstrap")
            XCTAssertFalse(original.isVisible)
            XCTAssertFalse(containsRetainedTable(in: bootstrapHost), "The hidden WindowGroup must not retain a second file/branch/history UI")
        } else {
            window.contentView = content
            window.orderFront(nil)
        }
        // OCR verifies target filenames/history once; timed switches compare captured pixels.
        // Busy styling matches the blocked-validation phase being measured below.
        var reference: [String: (files: Data, history: Data, branches: Data)] = [:]
        for repo in repositories {
            await store.open(repo)
            XCTAssertEqual(store.files.count, emptySource && repo == repositories[0] ? 0 : 6_001)
            XCTAssertEqual(store.commits.count, commitCount)
            XCTAssertEqual(store.branches.count, 13)
            if productionBootstrap {
                XCTAssertEqual(store.files.filter { $0.worktreeStatus == "M" }.count, 3_000)
                XCTAssertEqual(store.files.filter { $0.worktreeStatus == "?" }.count, 3_001)
            }
            for _ in 0..<20 {
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            store.isBusy = true
            for _ in 0..<5 {
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertNil(window.toolbar, "Custom toolbar shell must not register an NSToolbar")
            let images = try XCTUnwrap(targetImages(in: host, fileCount: emptySource && repo == repositories[0] ? 0 : 6_001, commitCount: commitCount))
            let fileText = try recognizedText(images.files), historyText = try recognizedText(images.history), branchText = try recognizedText(images.branches)
            print("MAIN_WINDOW_REFERENCE repo=\(repo.lastPathComponent) files=\(fileText) history=\(historyText) branches=\(branchText)")
            if !emptySource || repo != repositories[0] {
                XCTAssertTrue(fileText.contains(repo.lastPathComponent + "-file00000"))
                if !tree {
                    XCTAssertTrue(fileText.contains(productionBootstrap ? "Modified" : "Untracked"), "Status must render without ellipses")
                }
            }
            XCTAssertTrue(historyText.contains(repo.lastPathComponent + " history"))
            XCTAssertTrue(branchText.contains(repo.lastPathComponent + "-branch-"))
            reference[repo.path] = (try XCTUnwrap(pixels(images.files)), try XCTUnwrap(pixels(images.history)), try XCTUnwrap(pixels(images.branches)))
            store.isBusy = false
        }
        if diskFirst {
            // Settle the previous busy-state redraw before measuring the existing fixture read.
            for _ in 0..<5 {
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(1))
            }
            for repo in repositories {
                let deadline = Date().addingTimeInterval(5)
                while await cache.load(repository: repo) == nil, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                let readStart = ContinuousClock.now
                let saved = await cache.load(repository: repo)
                let readDuration = readStart.duration(to: .now).components
                let readMS = Double(readDuration.seconds) * 1000 + Double(readDuration.attoseconds) / 1e15
                let cacheFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: [.fileSizeKey])
                let largestJSONBytes = try cacheFiles.filter { $0.pathExtension == "json" }.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }.max() ?? 0
                print("MAIN_WINDOW_DISK_READ repo=\(repo.lastPathComponent) tree=\(tree) elapsedMs=\(readMS) largestJSONBytes=\(largestJSONBytes)")
                XCTAssertEqual(saved?.files.count, 6_001, "Disk fixture must contain the real prepared snapshot")
                XCTAssertEqual(saved?.commits.count, commitCount)
                XCTAssertEqual(saved?.branches.count, 13)
                XCTAssertNil(saved?.observedState, "Production display snapshots must not duplicate file validation state")
                if tree { XCTAssertEqual(saved?.tree?.count, 6_001) }
            }
            store.closeTransientSession()
            if coldPreparation {
                // Natural LRU eviction simulates a fresh process without product reset APIs.
                for index in 0..<33 {
                    let path = root.appendingPathComponent("eviction-\(index)").path
                    let request = WorkspaceFilePreparation(repository: path, files: [], ignoredPaths: [], filter: "",
                        filterCase: "insensitive", category: .all, showHidden: true, showIgnored: false,
                        sort: [.init(column: .path, ascending: true)])
                    _ = try WorkspaceFilePreparationCache.shared.prepare(request)
                    WorkspaceTreeCache.shared.store([], for: path)
                }
                for repo in repositories {
                    let cachedSnapshot = await cache.load(repository: repo)
                    let saved = try XCTUnwrap(cachedSnapshot)
                    let request = WorkspaceFilePreparation(repository: repo.path, files: saved.files, ignoredPaths: [], filter: "",
                        filterCase: "insensitive", category: .all, showHidden: true, showIgnored: false,
                        sort: [.init(column: .path, ascending: true)])
                    XCTAssertNil(WorkspaceFilePreparationCache.shared.cached(request))
                    XCTAssertNil(WorkspaceTreeCache.shared.nodes(for: repo.path))
                }
            }
            store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
            store.showsWorkspaceTree = tree
            host = NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: BorderlessToolbarModel(original: nil), fileTree: tree))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            content = EightPointFrameView(content: host)
            window.contentView = content
            await store.open(repositories[1])
            for _ in 0..<20 {
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            // Alpha has a persisted snapshot but no live store or retained native pane.
            XCTAssertEqual(store.repositoryURL?.path, repositories[1].path)
        }
        XCTAssertNotEqual(reference[repositories[0].path]?.branches, reference[repositories[1].path]?.branches)
        print("MAIN_WINDOW_MEASURE_START"); fflush(stdout)
        for repo in Array(repeating: repositories, count: 2).flatMap({ $0 }) {
            let gitDirectory = repo.appendingPathComponent(".git")
            try? FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("release-status"))
            try? FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("status-blocked"))
            try Data().write(to: gitDirectory.appendingPathComponent("block-status"))
            XCTAssertNil(window.toolbar, "Repository switching must not create a native toolbar")
            let start = ContinuousClock.now
            var publicationMS: Double?, firstFileMS: Double?, firstHistoryMS: Double?, firstBranchMS: Double?
            let publicationObserver = store.$repositoryURL.sink { url in
                guard url?.path == repo.path, publicationMS == nil else { return }
                let duration = start.duration(to: .now).components
                publicationMS = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            }
            let requestStart = ContinuousClock.now
            let opening = try XCTUnwrap(store.requestOpen(repo))
            let requestMS = milliseconds(requestStart.duration(to: .now))
            var elapsed: Double?
            var lastLayoutMS: Double = 0, lastCaptureMS: Double = 0
            var iterations = 0, maxLayoutIteration = 0
            var totalLayoutMS = 0.0, totalDisplayMS = 0.0, totalCaptureMS = 0.0
            var maxLayoutMS = 0.0, maxDisplayMS = 0.0, maxGapMS = 0.0
            var previousLoopEnd = ContinuousClock.now
            var maxLayoutState = ""
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                iterations += 1
                maxGapMS = max(maxGapMS, milliseconds(previousLoopEnd.duration(to: .now)))
                let stateBefore = "repo=\(store.repositoryURL?.lastPathComponent ?? "nil") pending=\(store.pendingRepositoryPath ?? "nil") busy=\(store.isBusy)"
                let layoutStart = ContinuousClock.now
                bootstrapWindow?.contentView?.layoutSubtreeIfNeeded()
                content.layoutSubtreeIfNeeded()
                if productionBootstrap {
                    // SwiftUI's scene and the visible native shell share the same store.
                    bootstrapWindow?.contentView?.layoutSubtreeIfNeeded()
                    content.layoutSubtreeIfNeeded()
                }
                let layoutOnlyMS = milliseconds(layoutStart.duration(to: .now))
                let displayStart = ContinuousClock.now
                window.displayIfNeeded()
                let displayMS = milliseconds(displayStart.duration(to: .now))
                totalLayoutMS += layoutOnlyMS; totalDisplayMS += displayMS
                maxDisplayMS = max(maxDisplayMS, displayMS)
                if layoutOnlyMS > maxLayoutMS {
                    maxLayoutMS = layoutOnlyMS; maxLayoutIteration = iterations
                    maxLayoutState = stateBefore + " afterRepo=\(store.repositoryURL?.lastPathComponent ?? "nil") afterBusy=\(store.isBusy)"
                }
                let layoutDuration = layoutStart.duration(to: .now).components
                lastLayoutMS = Double(layoutDuration.seconds) * 1000 + Double(layoutDuration.attoseconds) / 1e15
                let captureStart = ContinuousClock.now
                if store.repositoryURL?.path == repo.path, let images = targetImages(in: host, fileCount: emptySource && repo == repositories[0] ? 0 : 6_001, commitCount: commitCount) {
                    // Compare against target rows whose filenames/history were verified by OCR during setup.
                    let captured = start.duration(to: .now).components
                    let captureDuration = captureStart.duration(to: .now).components
                    lastCaptureMS = Double(captureDuration.seconds) * 1000 + Double(captureDuration.attoseconds) / 1e15
                    totalCaptureMS += lastCaptureMS
                    if let expected = reference[repo.path] {
                        let fileMatches = pixels(images.files) == expected.files
                        let historyMatches = pixels(images.history) == expected.history
                        let branchesMatch = pixels(images.branches) == expected.branches
                        let capturedMS = Double(captured.seconds) * 1000 + Double(captured.attoseconds) / 1e15
                        if fileMatches, firstFileMS == nil { firstFileMS = capturedMS }
                        if historyMatches, firstHistoryMS == nil { firstHistoryMS = capturedMS }
                        if branchesMatch, firstBranchMS == nil { firstBranchMS = capturedMS }
                        guard fileMatches && historyMatches && branchesMatch else { previousLoopEnd = .now; try await Task.sleep(for: .milliseconds(1)); continue }
                        elapsed = Double(captured.seconds) + Double(captured.attoseconds) / 1e18
                        XCTAssertTrue(store.isBusy, "Target pixels must appear before Git validation completes")
                        break
                    }
                }
                previousLoopEnd = .now
                try await Task.sleep(for: .milliseconds(1))
            }
            print("MAIN_WINDOW_PHASES repository=\(repo.lastPathComponent) iterations=\(iterations) requestMs=\(requestMS) totalLayoutMs=\(totalLayoutMS) totalDisplayMs=\(totalDisplayMS) totalCaptureMs=\(totalCaptureMS) maxLayoutMs=\(maxLayoutMS) maxLayoutIteration=\(maxLayoutIteration) maxDisplayMs=\(maxDisplayMS) maxSchedulingGapMs=\(maxGapMS) maxLayoutState=\(maxLayoutState)")
            if elapsed == nil, let images = targetImages(in: host, fileCount: emptySource && repo == repositories[0] ? 0 : 6_001, commitCount: commitCount) {
                try NSBitmapImageRep(cgImage: images.branches).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/raygit-branch-current-\(borderless)-\(repo.lastPathComponent).png"))
                if let current = pixels(images.branches), let expected = reference[repo.path]?.branches {
                    let diffs = zip(current, expected).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
                    print("BRANCH_DIFF expectedBytes=\(expected.count) currentBytes=\(current.count) changedBytes=\(diffs.count) firstOffsets=\(Array(diffs.prefix(20)))")
                }
                print("MAIN_WINDOW_MISMATCH filesMs=\(firstFileMS ?? -1) historyMs=\(firstHistoryMS ?? -1) branchMs=\(firstBranchMS ?? -1) branchWidth=\(images.branches.width) branchHeight=\(images.branches.height) stride=\(images.branches.bytesPerRow) bits=\(images.branches.bitsPerPixel) branchText=\(try recognizedText(images.branches))")
            }
            // Git's blocked marker is checked after the visual timer has stopped.
            let blockedDeadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("status-blocked").path), Date() < blockedDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            let blocked = FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("status-blocked").path)
            try Data().write(to: gitDirectory.appendingPathComponent("release-status"))
            await opening.value
            publicationObserver.cancel()
            try FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("block-status"))
            XCTAssertTrue(blocked, "Background status must still require Git validation")
            let latency = try XCTUnwrap(elapsed)
            if let bootstrapHost = bootstrapWindow?.contentView {
                XCTAssertFalse(containsRetainedTable(in: bootstrapHost), "Switching must not recreate lists in the hidden WindowGroup")
            }
            print("MAIN_WINDOW_SWITCH bootstrap=\(productionBootstrap) shell=\(borderless ? "borderless" : "titled") mode=\(tree ? "tree" : "list") diskFirst=\(diskFirst) coldPreparation=\(coldPreparation) repository=\(repo.lastPathComponent) files=\(emptySource && repo == repositories[0] ? 0 : 6001) commits=\(commitCount) branches=13 firstTargetLayoutMs=\(latency * 1000) publicationMs=\(publicationMS ?? -1) firstFilePixelsMs=\(firstFileMS ?? -1) firstHistoryPixelsMs=\(firstHistoryMS ?? -1) firstBranchPixelsMs=\(firstBranchMS ?? -1) finalLayoutDisplayMs=\(lastLayoutMS) rowCaptureMs=\(lastCaptureMS)")
            XCTAssertLessThan(latency, 0.1, "Measure the full target layout, not RepositoryStore publication")
        }
    }
}
