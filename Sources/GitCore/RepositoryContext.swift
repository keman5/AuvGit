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
        return output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
    public func updateRemoteURL(expected: RepositoryRemoteConfiguration, fetchIndex: Int, fetchURL: String, pushURL: String?) async throws {
        guard !fetchURL.isEmpty, !fetchURL.contains("\0"), !fetchURL.contains("\n"), pushURL.map({ !$0.contains("\0") && !$0.contains("\n") }) ?? true else { throw GitError("Enter a valid remote URL.") }
        guard try await remoteConfigurations().contains(expected), expected.fetchURLs.indices.contains(fetchIndex) else { throw GitError("The remote configuration changed. Reload before saving.") }
        let old = expected.fetchURLs[fetchIndex]
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
