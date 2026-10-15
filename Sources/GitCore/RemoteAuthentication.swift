import Foundation

public struct RemoteCredentialIdentity: Equatable, Hashable, Sendable {
    public let transport: RemoteEndpoint.Transport
    public let host: String
    public let port: Int
    public let username: String

    public var storageKey: String {
        transport.rawValue + "|" + host + "|" + String(port) + "|" + username
    }
}

public struct RemoteEndpoint: Equatable, Hashable, Sendable {
    public enum Transport: String, Equatable, Hashable, Sendable { case https, ssh }

    public let transport: Transport
    public let host: String
    public let port: Int
    public let username: String?
    public let remoteURL: String

    public func identity(username: String) -> RemoteCredentialIdentity {
        RemoteCredentialIdentity(transport: transport, host: host, port: port, username: username)
    }

    public func convertingToSSH(username: String, port: Int) -> RemoteEndpoint? {
        guard transport == .https, Self.validField(username), (1...65535).contains(port),
              var components = URLComponents(string: remoteURL),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.password == nil, components.query == nil, components.fragment == nil,
              !components.percentEncodedPath.isEmpty else { return nil }
        components.scheme = "ssh"
        components.host = host
        components.user = username
        components.port = port == 22 ? nil : port
        guard let value = components.string else { return nil }
        return Self.parse(value)
    }

    public static func parse(_ value: String) -> RemoteEndpoint? {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return nil }
        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() {
            let transport: Transport
            switch scheme {
            case "https": transport = .https
            case "ssh": transport = .ssh
            default: return nil
            }
            guard let host = components.host?.lowercased(), !host.isEmpty,
                  components.password == nil,
                  components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
            return RemoteEndpoint(transport: transport, host: host,
                                  port: components.port ?? (transport == .https ? 443 : 22),
                                  username: components.user, remoteURL: value)
        }
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex,
              !value[..<colon].contains("/"), !value[..<colon].contains("\\") else { return nil }
        let authority = String(value[..<colon])
        guard let at = authority.lastIndex(of: "@"), at != authority.startIndex,
              authority.index(after: at) != authority.endIndex else { return nil }
        let username = String(authority[..<at])
        let host = String(authority[authority.index(after: at)...]).lowercased()
        guard validField(username), validField(host) else { return nil }
        return RemoteEndpoint(transport: .ssh, host: host, port: 22, username: username, remoteURL: value)
    }

    private static func validField(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == "\0" || $0 == "/" || $0 == "\\" })
    }
}

public struct RemoteAuthenticationTarget: Equatable, Sendable {
    public let remoteName: String
    public let endpoint: RemoteEndpoint
    public let usesPushURL: Bool

    public init(remoteName: String, endpoint: RemoteEndpoint, usesPushURL: Bool = false) {
        self.remoteName = remoteName; self.endpoint = endpoint; self.usesPushURL = usesPushURL
    }
}

public struct RemoteSSHMigrationPlan: Equatable, Sendable {
    public let operation: NetworkOperation
    public let source: RemoteAuthenticationTarget
    public let replacement: RemoteEndpoint
    public let explicitRemoteName: String?
}

public enum NetworkCredential: Sendable {
    case https(username: String, password: String)
    case ssh(username: String, privateKey: URL, passphrase: String?)
}

final class NetworkCredentialLease {
    let gitArguments: [String]
    let environment: [String: String]
    let privateValues: [String]
    let directoryURL: URL?
    let secretURL: URL?
    let askpassURL: URL?
    private let httpsLease: HTTPSCredentialLease?

    init(endpoint: RemoteEndpoint, credential: NetworkCredential) throws {
        switch credential {
        case let .https(username, password):
            guard endpoint.transport == .https else { throw GitError("HTTPS credentials require an HTTPS remote.") }
            var components = URLComponents()
            components.scheme = "https"; components.host = endpoint.host
            if endpoint.port != 443 { components.port = endpoint.port }
            components.path = "/"
            guard let source = components.url else { throw GitError("HTTPS credentials require a valid remote.") }
            let lease = try HTTPSCredentialLease(source: source, credential: .init(username: username, password: password, saveToKeychain: false))
            httpsLease = lease; gitArguments = lease.gitArguments; environment = [:]
            privateValues = [password]; directoryURL = lease.directoryURL
            secretURL = lease.credentialURL; askpassURL = nil
        case let .ssh(username, privateKey, passphrase):
            guard endpoint.transport == .ssh else { throw GitError("SSH credentials require an SSH remote.") }
            guard Self.valid(username), privateKey.isFileURL, privateKey.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: privateKey.path),
                  !privateKey.path.contains("\0"), !privateKey.path.contains("\n"), !privateKey.path.contains("\r") else {
                throw GitError("Choose a valid SSH private key and username.")
            }
            httpsLease = nil
            var command = "ssh -i " + Self.shellQuote(privateKey.path) + " -o IdentitiesOnly=yes"
            command += " -o BatchMode=" + ((passphrase?.isEmpty == false) ? "no" : "yes")
            command += " -p " + String(endpoint.port) + " -l " + Self.shellQuote(username)
            gitArguments = []
            if let passphrase, !passphrase.isEmpty {
                guard Self.valid(passphrase) else { throw GitError("SSH key passphrase must be a single-line value.") }
                let manager = FileManager.default
                let directory = manager.temporaryDirectory.appendingPathComponent("auvgit-ssh-" + UUID().uuidString, isDirectory: true)
                let secret = directory.appendingPathComponent("passphrase")
                let helper = directory.appendingPathComponent("askpass.sh")
                do {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    guard manager.createFile(atPath: secret.path, contents: Data(passphrase.utf8), attributes: [.posixPermissions: 0o600]),
                          manager.createFile(atPath: helper.path, contents: Data(("#!/bin/sh\nexec /bin/cat " + Self.shellQuote(secret.path) + "\n").utf8), attributes: [.posixPermissions: 0o700]) else {
                        throw GitError("Cannot create temporary SSH authentication files.")
                    }
                } catch {
                    try? manager.removeItem(at: directory)
                    throw error
                }
                directoryURL = directory; secretURL = secret; askpassURL = helper
                environment = ["GIT_SSH_COMMAND": command, "SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "auvgit"]
                privateValues = [passphrase]
            } else {
                directoryURL = nil; secretURL = nil; askpassURL = nil
                environment = ["GIT_SSH_COMMAND": command]; privateValues = []
            }
        }
    }

    func remove() {
        httpsLease?.remove()
        if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
    }

    deinit { remove() }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public extension GitRepository {
    func remoteAuthenticationTarget(for operation: NetworkOperation, remoteName: String? = nil) async throws -> RemoteAuthenticationTarget {
        let branchOutput = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], allowedCodes: [0, 1])
        let branch = branchOutput.code == 0 ? branchOutput.text.trimmingCharacters(in: .newlines) : nil
        let names = try await GitProcess.run(at: url, arguments: ["remote"]).text.split(separator: "\n").map(String.init)
        let push = operation == .push || operation == .pushPreview
        let preferred: [String?]
        if push, let branch {
            preferred = [
                try await remoteConfigurationValue("branch." + branch + ".pushRemote"),
                try await remoteConfigurationValue("remote.pushDefault"),
                try await remoteConfigurationValue("branch." + branch + ".remote")
            ]
        } else if let branch {
            preferred = [try await remoteConfigurationValue("branch." + branch + ".remote")]
        } else {
            preferred = []
        }
        if let remoteName, !names.contains(remoteName) { throw GitError("Unknown remote") }
        let remote = remoteName ?? preferred.compactMap { $0 }.first(where: { $0 != "." && names.contains($0) })
            ?? (names.contains("origin") ? "origin" : names.count == 1 ? names[0] : nil)
        guard let remote else { throw GitError("Cannot resolve a single configured remote for authentication.") }
        let arguments = ["remote", "get-url"] + (push ? ["--push"] : []) + [remote]
        let effectiveURL = try await GitProcess.run(at: url, arguments: arguments).text.trimmingCharacters(in: .newlines)
        guard let endpoint = RemoteEndpoint.parse(effectiveURL) else { throw GitError("The configured remote does not use HTTPS or SSH authentication.") }
        let usesPushURL: Bool
        if push {
            let configured = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "remote." + remote + ".pushurl"], allowedCodes: [0, 1])
            usesPushURL = configured.code == 0 && !configured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else { usesPushURL = false }
        return RemoteAuthenticationTarget(remoteName: remote, endpoint: endpoint, usesPushURL: usesPushURL)
    }

    func remoteSSHMigrationPlan(for operation: NetworkOperation, username: String, port: Int, remoteName: String? = nil) async throws -> RemoteSSHMigrationPlan {
        let source = try await remoteAuthenticationTarget(for: operation, remoteName: remoteName)
        guard let replacement = source.endpoint.convertingToSSH(username: username, port: port) else {
            throw GitError("The HTTPS remote cannot be converted to a valid SSH remote.")
        }
        return RemoteSSHMigrationPlan(operation: operation, source: source, replacement: replacement, explicitRemoteName: remoteName)
    }

    func migrateRemoteToSSH(_ plan: RemoteSSHMigrationPlan, credential: NetworkCredential) async throws {
        try await migrateRemoteToSSH(plan, credential: credential) { endpoint, credential in
            let lease = try NetworkCredentialLease(endpoint: endpoint, credential: credential)
            defer { lease.remove() }
            _ = try await GitCommandLog.$privateCredentials.withValue(lease.privateValues) {
                try await GitProcess.run(at: self.url,
                                         arguments: lease.gitArguments + ["ls-remote", "--heads", endpoint.remoteURL],
                                         environmentOverrides: lease.environment)
            }
        }
    }

    func migrateRemoteToSSH(_ plan: RemoteSSHMigrationPlan, credential: NetworkCredential,
                            verify: (RemoteEndpoint, NetworkCredential) async throws -> Void) async throws {
        guard case let .ssh(username, _, _) = credential,
              username == plan.replacement.username else { throw GitError("SSH migration requires the selected SSH credential.") }
        try await verify(plan.replacement, credential)
        let current = try await remoteAuthenticationTarget(for: plan.operation, remoteName: plan.explicitRemoteName)
        guard current == plan.source else { throw GitError("Remote configuration changed during SSH authentication; retry.") }
        var arguments = ["remote", "set-url"]
        if current.usesPushURL { arguments.append("--push") }
        arguments += [current.remoteName, plan.replacement.remoteURL]
        _ = try await GitProcess.run(at: url, arguments: arguments)
    }

    private func remoteConfigurationValue(_ key: String) async throws -> String? {
        let output = try await GitProcess.run(at: url, arguments: ["config", "--get", key], allowedCodes: [0, 1])
        return output.code == 0 ? output.text.trimmingCharacters(in: .newlines) : nil
    }
}
