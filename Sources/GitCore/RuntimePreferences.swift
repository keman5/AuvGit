import Foundation

/// App-local options. Never writes repository or global Git configuration.
public final class GitRuntimePreferences: @unchecked Sendable {
    public static let shared = GitRuntimePreferences()
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var executablePath: String { defaults.string(forKey: "auvgit.git.executablePath") ?? "/usr/bin/git" }
    public var timeout: TimeInterval { let v = defaults.double(forKey: "auvgit.git.timeout"); return (5...3600).contains(v) ? v : 120 }
    public var commitCleanup: String { let v = defaults.string(forKey: "auvgit.git.commitCleanup") ?? "default"; return ["default", "whitespace", "strip", "verbatim"].contains(v) ? v : "default" }
    public var proxyMode: String { defaults.string(forKey: "auvgit.network.proxyMode") ?? "inherit" }
    public var proxyURL: String { defaults.string(forKey: "auvgit.network.proxyURL") ?? "" }
    public var sshCommand: String { defaults.string(forKey: "auvgit.network.sshCommand") ?? "" }
    public var fetchPrune: Bool { defaults.object(forKey: "auvgit.network.fetchPrune") == nil ? true : defaults.bool(forKey: "auvgit.network.fetchPrune") }
    public func setGit(path: String, timeout: Double, cleanup: String) throws {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw GitError("Choose an absolute path to an executable Git binary.") }
        guard (5...3600).contains(timeout), ["default", "whitespace", "strip", "verbatim"].contains(cleanup) else { throw GitError("Invalid Git preferences.") }
        defaults.set(path, forKey: "auvgit.git.executablePath"); defaults.set(timeout, forKey: "auvgit.git.timeout"); defaults.set(cleanup, forKey: "auvgit.git.commitCleanup")
    }
    public func setNetwork(mode: String, proxy: String, ssh: String, prune: Bool) throws {
        guard ["inherit", "off", "manual"].contains(mode) else { throw GitError("Invalid proxy mode.") }
        if mode == "manual" {
            guard let u = URLComponents(string: proxy), ["http", "https"].contains(u.scheme ?? ""), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { throw GitError("Enter an HTTP(S) proxy URL without credentials, query or fragment.") }
        }
        guard !ssh.contains("\n"), !ssh.contains("\0") else { throw GitError("SSH command must be one line.") }
        defaults.set(mode, forKey: "auvgit.network.proxyMode"); defaults.set(mode == "manual" ? proxy : "", forKey: "auvgit.network.proxyURL"); defaults.set(ssh, forKey: "auvgit.network.sshCommand"); defaults.set(prune, forKey: "auvgit.network.fetchPrune")
    }
    public func environment(_ original: [String: String]) -> [String: String] {
        var env = original
        if proxyMode != "inherit" {
            for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "no_proxy", "NO_PROXY"] { env.removeValue(forKey: key) }
            if proxyMode == "manual" { env["http_proxy"] = proxyURL; env["https_proxy"] = proxyURL }
        }
        // Explicit environment always wins; Git itself interprets GIT_SSH_COMMAND.
        if env["GIT_SSH_COMMAND"] == nil, !sshCommand.isEmpty { env["GIT_SSH_COMMAND"] = sshCommand }
        return env
    }
    public func resetGit() { for key in ["executablePath", "timeout", "commitCleanup"] { defaults.removeObject(forKey: "auvgit.git." + key) } }
    public func resetNetwork() { for key in ["proxyMode", "proxyURL", "sshCommand", "fetchPrune"] { defaults.removeObject(forKey: "auvgit.network." + key) } }
    public static func validateExecutable(_ path: String) async throws -> String {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw GitError("Choose an absolute path to an executable Git binary.") }
        let output = try await GitProcess.run(at: FileManager.default.temporaryDirectory, arguments: ["--version"], timeout: 10, executable: path)
        guard output.text.hasPrefix("git version ") else { throw GitError("The selected executable is not Git.") }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
