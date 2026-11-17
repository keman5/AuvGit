import Foundation

public struct RepositoryRemoteConfiguration: Equatable, Sendable, Identifiable {
    public let name: String
    public let fetchURLs: [String]
    public let pushURLs: [String]
    public var id: String { name }
}

extension GitRepository {
    public func gitignoreSnapshot() throws -> Data? {
        let file = url.appendingPathComponent(".gitignore")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitError("The .gitignore file must be a regular file; symbolic links cannot be edited.") }
            let data = try Data(contentsOf: file)
            guard String(data: data, encoding: .utf8) != nil else { throw GitError("The .gitignore file must use UTF-8.") }
            return data
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw error
        }
    }
    public func remoteConfigurations() async throws -> [RepositoryRemoteConfiguration] {
        let names = try await GitProcess.run(at: url, arguments: ["remote"])
        var result: [RepositoryRemoteConfiguration] = []
        for name in names.text.split(separator: "\n").map(String.init) {
            let fetch = try await remoteValues(name: name, field: "url")
            let push = try await remoteValues(name: name, field: "pushurl")
            result.append(.init(name: name, fetchURLs: fetch, pushURLs: push))
        }
        return result
    }
    private func remoteValues(name: String, field: String) async throws -> [String] {
        let output = try await GitProcess.run(at: url, arguments: ["config", "--local", "--null", "--get-all", "remote.\(name).\(field)"], allowedCodes: [0, 1])
        return output.data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }
    /// Accept Git's URL forms, including SCP syntax and local paths, without network access.
    public static func isValidRemoteURL(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.hasPrefix("-"), value.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        if value.contains("://") {
            guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let components = URLComponents(string: value), let scheme = components.scheme else { return false }
            return scheme == "file" ? !components.path.isEmpty : !(components.host ?? "").isEmpty
        }
        return true
    }
    public static func isValidRemoteName(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.hasPrefix("/") && !value.hasSuffix("/") &&
        !value.contains("..") && !value.contains("//") && !value.contains("@{") &&
        value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock") } &&
        value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "~^:?*[\\"))) == nil
    }
    public func addRemote(name: String, fetchURL: String, pushURL: String? = nil) async throws {
        guard Self.isValidRemoteName(name) else { throw GitError("Enter a valid remote name.") }
        guard Self.isValidRemoteURL(fetchURL), pushURL.map({ $0.isEmpty || Self.isValidRemoteURL($0) }) ?? true else { throw GitError("Enter a valid remote URL.") }
        // Let Git reject an existing name instead of overwriting its config keys.
        // `remote add` also installs the standard fetch refspec.
        _ = try await GitProcess.run(at: url, arguments: ["remote", "add", "--", name, fetchURL])
        if let pushURL, !pushURL.isEmpty {
            _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--add", "remote.\(name).pushurl", pushURL])
        }
    }
    public func updateRemoteURL(expected: RepositoryRemoteConfiguration, fetchIndex: Int, fetchURL: String, pushURL: String?) async throws {
        guard Self.isValidRemoteURL(fetchURL), pushURL.map({ $0.isEmpty || Self.isValidRemoteURL($0) }) ?? true else { throw GitError("Enter a valid remote URL.") }
        guard expected.fetchURLs.indices.contains(fetchIndex) else { throw GitError("The remote configuration changed. Reload before saving.") }
        let old = expected.fetchURLs[fetchIndex]
        let changesPush = pushURL.map { $0.isEmpty ? !expected.pushURLs.isEmpty : $0 != expected.pushURLs.first } ?? false
        guard old != fetchURL || changesPush else { return }
        guard try await remoteConfigurations().contains(expected) else { throw GitError("The remote configuration changed. Reload before saving.") }
        if old != fetchURL {
            _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--fixed-value", "--replace-all", "remote.\(expected.name).url", fetchURL, old])
        }
        if let pushURL {
            let key = "remote.\(expected.name).pushurl"
            if let oldPush = expected.pushURLs.first {
                if pushURL.isEmpty { _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--fixed-value", "--unset-all", key, oldPush]) }
                else if oldPush != pushURL { _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--fixed-value", "--replace-all", key, pushURL, oldPush]) }
            } else if !pushURL.isEmpty { _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--add", key, pushURL]) }
        }
    }
}
