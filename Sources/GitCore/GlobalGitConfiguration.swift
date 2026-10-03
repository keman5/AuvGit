import Foundation

public struct GlobalGitConfiguration: Sendable {
    public var name = ""
    public var email = ""
    public var signingFormat = ""
    public var signingKey = ""
    public var signCommits = ""
    public init() {}
    private static let keys = ["user.name", "user.email", "gpg.format", "user.signingkey", "commit.gpgsign"]
    public static func load(configFile: URL? = nil) async throws -> GlobalGitConfiguration {
        var values: [String] = []
        for key in keys {
            let output = try await GitProcess.run(at: FileManager.default.temporaryDirectory, arguments: ["config"] + (configFile.map { ["--file", $0.path] } ?? ["--global"]) + ["--get", key], allowedCodes: [0, 1])
            values.append(output.text.trimmingCharacters(in: .newlines))
        }
        var result = GlobalGitConfiguration(); result.name = values[0]; result.email = values[1]; result.signingFormat = values[2]; result.signingKey = values[3]; result.signCommits = values[4]; return result
    }
    /// Writes only changed fields. Empty removes this specific key, leaving all others intact.
    public func apply(changedFrom original: GlobalGitConfiguration, configFile: URL? = nil) async throws {
        let values = [name, email, signingFormat, signingKey, signCommits]
        let old = [original.name, original.email, original.signingFormat, original.signingKey, original.signCommits]
        guard values.allSatisfy({ !$0.contains("\n") && !$0.contains("\0") }) else { throw GitError("Configuration values must be one line.") }
        if signingFormat != original.signingFormat, !["", "openpgp", "x509", "ssh"].contains(signingFormat) { throw GitError("Signing format must be openpgp, x509 or ssh.") }
        if signCommits != original.signCommits, !["", "true", "false"].contains(signCommits.lowercased()) { throw GitError("Sign commits must be true, false or empty.") }
        for (index, key) in Self.keys.enumerated() where values[index] != old[index] {
            let scope = ["config"] + (configFile.map { ["--file", $0.path] } ?? ["--global"])
            let args = scope + (values[index].isEmpty ? ["--unset-all", key] : ["--replace-all", key, values[index]])
            _ = try await GitProcess.run(at: FileManager.default.temporaryDirectory, arguments: args, allowedCodes: values[index].isEmpty ? [0, 5] : [0])
        }
    }
}
