import XCTest
@testable import GitCore

final class BackgroundFetchTests: XCTestCase {
    func testPollingFetchesOnlyChangedOrUnseenHeads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer"), clone = root.appendingPathComponent("clone")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: producer, arguments: ["config", "user.email", "test@example.com"])
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "--allow-empty", "-m", "base"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, clone.path])
        let wrapper = root.appendingPathComponent("test-git"), count = clone.appendingPathComponent(".git/fetch-count")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "fetch" ]; then echo fetch >> .git/fetch-count; fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let repo = GitRepository(url: clone)
        let originalHead = try await GitProcess.run(at: clone, arguments: ["rev-parse", "HEAD"]).text
        try await repo.backgroundFetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: count.path), "Unchanged heads only need ls-remote")
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "--allow-empty", "-m", "changed"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        try await repo.backgroundFetch()
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "fetch\n")
        let incoming = try await repo.log(incomingOnly: true)
        XCTAssertEqual(incoming.map(\.subject), ["changed"], "Incoming history excludes every commit already reachable locally")
        let localHistory = try await repo.log(ref: "HEAD")
        XCTAssertEqual(localHistory.map(\.subject), ["base"])
        let emptyIncomingPage = try await repo.log(skip: 1, incomingOnly: true)
        XCTAssertTrue(emptyIncomingPage.isEmpty)
        try await repo.backgroundFetch()
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "fetch\n")
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/new-branch"])
        try await repo.backgroundFetch()
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "fetch\nfetch\n")
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "--delete", "new-branch"])
        try await repo.backgroundFetch()
        let retained = try await GitProcess.run(at: clone, arguments: ["rev-parse", "refs/remotes/origin/new-branch"]).text
        XCTAssertFalse(retained.isEmpty, "Background polling must not prune deleted heads")
        let finalHead = try await GitProcess.run(at: clone, arguments: ["rev-parse", "HEAD"]).text
        XCTAssertEqual(originalHead, finalHead)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "fetch\nfetch\n")
    }

    func testBackgroundSSHIsNoninteractiveAndCustomWrapperIsNotInvoked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        _ = try await GitProcess.run(at: root, arguments: ["remote", "add", "origin", "ssh://example.invalid/repo"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "core.sshCommand", "ssh -oBatchMode=no -F /tmp/custom-config -p 2222"])
        let wrapper = root.appendingPathComponent(".git/test-git"), capture = root.appendingPathComponent(".git/background-env")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "ls-remote" ]; then
                printf '%s\\n' "$GIT_SSH_COMMAND" "$GIT_ASKPASS" "$SSH_ASKPASS" "$SSH_ASKPASS_REQUIRE" "$GCM_INTERACTIVE" > .git/background-env
                exit 0
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let repo = GitRepository(url: root)
        try await repo.backgroundFetch()
        let environment = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(environment.hasPrefix("ssh -oBatchMode=yes -oBatchMode=no -F /tmp/custom-config -p 2222\n"))
        XCTAssertTrue(environment.contains("/usr/bin/false\n/usr/bin/false\nnever\nNever"))
        let sshKey = "auvgit.network.sshCommand", previousSSH = UserDefaults.standard.object(forKey: "auvgit.network.sshCommand")
        defer { if let previousSSH { UserDefaults.standard.set(previousSSH, forKey: sshKey) } else { UserDefaults.standard.removeObject(forKey: sshKey) } }
        UserDefaults.standard.set("ssh -F /tmp/runtime-config", forKey: sshKey)
        try await repo.backgroundFetch()
        XCTAssertTrue(try String(contentsOf: capture, encoding: .utf8).hasPrefix("ssh -oBatchMode=yes -F /tmp/runtime-config\n"))
        UserDefaults.standard.removeObject(forKey: sshKey)
        try FileManager.default.removeItem(at: capture)
        _ = try await GitProcess.run(at: root, arguments: ["config", "core.sshCommand", "/tmp/custom-ssh-wrapper"])
        do { try await repo.backgroundFetch(); XCTFail("Custom wrappers must not run unattended") } catch { XCTAssertTrue(error is GitError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        _ = try await GitProcess.run(at: root, arguments: ["remote", "set-url", "origin", root.appendingPathComponent("local.git").path])
        try await repo.backgroundFetch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path), "SSH wrappers must not block file or HTTPS remotes")
    }
}
