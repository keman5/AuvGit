import XCTest
@testable import GitCore

final class BackgroundFetchTests: XCTestCase {
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
            if [ "$arg" = "fetch" ]; then
                printf '%s\\n' "$GIT_SSH_COMMAND" "$GIT_ASKPASS" "$SSH_ASKPASS" "$SSH_ASKPASS_REQUIRE" "$GCM_INTERACTIVE" > .git/background-env
                exit 0
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "raygit.git.executablePath", previous = UserDefaults.standard.object(forKey: "raygit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let repo = GitRepository(url: root)
        try await repo.backgroundFetch()
        let environment = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(environment.hasPrefix("ssh -oBatchMode=yes -oBatchMode=no -F /tmp/custom-config -p 2222\n"))
        XCTAssertTrue(environment.contains("/usr/bin/false\n/usr/bin/false\nnever\nNever"))
        let sshKey = "raygit.network.sshCommand", previousSSH = UserDefaults.standard.object(forKey: "raygit.network.sshCommand")
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
