import Foundation

public struct RepositoryViewState: Codable, Equatable, Sendable {
    public var commitMessage = ""
    public var amend = false
    public var historySearch = ""
    public var historyAuthor = ""
    public var historyPath: String?
    public var historyRef: String?
    public var selectedPaths: Set<String> = []
    public var selectedCommit: String?
    public var selectedCommitPath: String?
    public var mode = "workspace"
    public var fileFilter = ""
    public var stagedDiff = false
    public var ignoreWhitespace = false
    public init() {}
}
public struct RepositorySession: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var openRepositories: [String] = []
    public var activeRepository: String?
    public var repositories: [String: RepositoryViewState] = [:]
    public init() {}
    public static func decode(_ data: Data) throws -> RepositorySession {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw GitError("Unsupported repository session version") }
        var normalized = value
        var seen = Set<String>()
        normalized.openRepositories = value.openRepositories.filter { $0.hasPrefix("/") && !$0.contains("\0") && seen.insert($0).inserted }
        if let active = value.activeRepository, !normalized.openRepositories.contains(active) { normalized.activeRepository = normalized.openRepositories.first }
        return normalized
    }
    public static func recover(primary: Data?, backup: Data?) -> (session: RepositorySession, source: Data?, corruptPrimary: Data?) {
        if let primary, let session = try? decode(primary) { return (session, primary, nil) }
        if let backup, let session = try? decode(backup) { return (session, backup, primary) }
        return (RepositorySession(), nil, primary)
    }
    public func restorationCandidates() -> [String] {
        if let activeRepository, openRepositories.contains(activeRepository) { return [activeRepository] + openRepositories.filter { $0 != activeRepository } }
        return openRepositories
    }
    public func firstAccessibleRepository(isAccessible: (String) -> Bool) -> String? { restorationCandidates().first(where: isAccessible) }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(self) }
}
