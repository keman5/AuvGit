import XCTest
@testable import AuvGit
@testable import GitCore

final class CloneDestinationTests: XCTestCase {
    func testRemoteNamesAndUnsafeComponents() {
        for source in [" https://github.com/team/hello.git?token=x#fragment ", "ssh://git@example.com:2222/team/hello.git", "git@example.com:team/hello.git", "/tmp/team/hello.git/"] {
            XCTAssertEqual(CloneDestination.repositoryName(source), "hello", source)
        }
        XCTAssertEqual(CloneDestination.repositoryName("https://example.com/my%20repo.git"), "my repo")
        for source in ["https://example.com/..", "https://example.com/.git", "https://example.com/a%2Fb.git", "https://example.com/a%5Cb", "https://example.com/a%00b", "-danger", "https://example.com/a%3Fb.git"] {
            XCTAssertNil(CloneDestination.repositoryName(source), source)
        }
    }
    func testAutomaticOwnershipChooserAndSuccessfulParentPersistence() throws {
        let name = "CloneDestinationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var model = CloneDestination(defaults: defaults, home: URL(fileURLWithPath: "/temporary-home"))
        model.sourceChanged("git@example.com:team/one.git")
        XCTAssertEqual(model.path, "/temporary-home/one")
        model.sourceChanged("https://example.com/two.git")
        XCTAssertEqual(model.path, "/temporary-home/two")
        model.edit("~/custom destination")
        model.sourceChanged("https://example.com/three.git")
        XCTAssertEqual(model.path, "~/custom destination")
        model.chooseParent(URL(fileURLWithPath: "/projects/three"), source: "https://example.com/three.git")
        XCTAssertEqual(model.path, "/projects/three")
        model.rememberSuccessfulClone(URL(fileURLWithPath: "/projects/three"), defaults: defaults)
        var next = CloneDestination(defaults: defaults)
        next.sourceChanged("https://example.com/four.git")
        XCTAssertEqual(next.path, "/projects/four")
        XCTAssertEqual(CloneDestination.targetURL(" ~/custom destination ")?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("custom destination").path)
        XCTAssertNil(CloneDestination.targetURL("relative/repo"))
        XCTAssertNil(CloneDestination.targetURL("/"))
    }
    func testCloneCreatesMissingParentDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        _ = try await GitRepository.initialize(at: source)
        let target = root.appendingPathComponent("missing parent/deep/repository")
        let cloned = try await GitRepository.clone(source: source.path, destination: target)
        XCTAssertEqual(cloned.url.standardizedFileURL, target.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
    }
    func testDraftRestoresCustomDestinationAndAutomaticOwnership() throws {
        let name = "RepositoryDraftTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var draft = RepositoryCreationDraft(defaults: defaults)
        draft.clone = true
        draft.source = "https://example.com/team/one.git"
        draft.cloneDestination.chooseParent(URL(fileURLWithPath: "/projects"), source: draft.source)
        draft.destination = draft.cloneDestination.path
        draft.save(defaults: defaults)
        var restored = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertEqual(restored, draft)
        restored.cloneDestination.sourceChanged("https://example.com/team/two.git")
        XCTAssertEqual(restored.cloneDestination.path, "/projects/two")
        restored.destination = "~/my custom repository"
        restored.cloneDestination.edit(restored.destination)
        restored.save(defaults: defaults)
        var custom = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertEqual(custom.destination, "~/my custom repository")
        XCTAssertFalse(custom.cloneDestination.automatic)
        custom.cloneDestination.sourceChanged("https://example.com/team/three.git")
        XCTAssertEqual(custom.cloneDestination.path, "~/my custom repository")
        custom.cloneDestination.chooseParent(URL(fileURLWithPath: "/other"), source: custom.source)
        custom.destination = custom.cloneDestination.path
        custom.clone = false
        custom.save(defaults: defaults)
        let reopened = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertFalse(reopened.clone)
        XCTAssertEqual(reopened.source, draft.source)
        XCTAssertTrue(reopened.cloneDestination.automatic)
        XCTAssertEqual(reopened.cloneDestination.parent.path, "/other")
    }
    func testEveryOpeningReplacesSavedSourceAndCustomDestinationFromValidClipboard() throws {
        let name = "CloneClipboardTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/projects", forKey: CloneDestination.parentPreference)
        var draft = RepositoryCreationDraft(defaults: defaults)
        draft.source = "https://example.com/old.git"
        draft.destination = "~/custom destination"
        draft.cloneDestination.edit(draft.destination)
        draft.save(defaults: defaults)
        var first = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertTrue(first.applyClipboard("  https://example.com/team/new.git\n"))
        XCTAssertTrue(first.clone); XCTAssertEqual(first.source, "https://example.com/team/new.git")
        XCTAssertTrue(first.cloneDestination.automatic); XCTAssertEqual(first.destination, "/projects/new")
        first.save(defaults: defaults)
        var second = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertTrue(second.applyClipboard("git@example.com:team/another.git"))
        XCTAssertEqual(second.source, "git@example.com:team/another.git")
        XCTAssertEqual(second.destination, "/projects/another")
        let unchanged = second
        for invalid in [nil, "", "normal clipboard text", "just-a-word", "https:///repo.git", "https://example.com", "https://example.com/..", "-danger"] as [String?] {
            XCTAssertFalse(second.applyClipboard(invalid))
            XCTAssertEqual(second, unchanged)
        }
    }
    func testClipboardLocalSourceUsesSyntaxWithoutTouchingDiskAndKeepsSavedParent() throws {
        let name = "CloneClipboardLocalTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/projects/repo", forKey: CloneDestination.parentPreference)
        var draft = RepositoryCreationDraft(defaults: defaults)
        XCTAssertTrue(draft.applyClipboard("/not-created/repo.git"))
        XCTAssertEqual(draft.cloneDestination.parent.path, "/projects/repo")
        XCTAssertEqual(draft.destination, "/projects/repo/repo")
        XCTAssertTrue(draft.applyClipboard("file:///not-created/my%20repo.git"))
        XCTAssertEqual(draft.destination, "/projects/repo/my repo")
        XCTAssertTrue(draft.applyClipboard("ssh://git@example.com:2222/team/repo.git"))
        XCTAssertEqual(draft.destination, "/projects/repo/repo")
    }

    func testCorruptDraftFallsBackWithoutChangingSavedCloneParent() throws {
        let name = "RepositoryDraftTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/projects", forKey: CloneDestination.parentPreference)
        defaults.set(Data("invalid draft".utf8), forKey: RepositoryCreationDraft.preference)
        let draft = RepositoryCreationDraft.load(defaults: defaults)
        XCTAssertFalse(draft.clone)
        XCTAssertEqual(draft.source, "")
        XCTAssertEqual(draft.cloneDestination.parent.path, "/projects")
    }

}
