import Foundation

public struct GitFile: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public var isUntracked: Bool { indexStatus == "?" }
    public var isStaged: Bool { ![" ", "?", "!"].contains(indexStatus) }
    public var isUnstaged: Bool { ![" ", "!"].contains(worktreeStatus) }
    public var isConflict: Bool { indexStatus == "U" || worktreeStatus == "U" || ["AA", "DD"].contains(indexStatus + worktreeStatus) }
    public init(path: String, originalPath: String? = nil, indexStatus: String, worktreeStatus: String) { self.path = path; self.originalPath = originalPath; self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus }
}
public struct GitBranch: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstream: String?
    public let worktreePath: String?
    public let ahead: Int?
    public let behind: Int?
    public init(name: String, isCurrent: Bool, isRemote: Bool, upstream: String? = nil, worktreePath: String? = nil, ahead: Int? = nil, behind: Int? = nil) { self.ahead = ahead; self.behind = behind; self.name = name; self.isCurrent = isCurrent; self.isRemote = isRemote; self.upstream = upstream; self.worktreePath = worktreePath }
}
public struct GitWorktree: Equatable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public init(path: String, head: String, branch: String?, isBare: Bool = false, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path; self.head = head; self.branch = branch
        self.isBare = isBare; self.isLocked = isLocked; self.isPrunable = isPrunable
    }
    static func parsePorcelain(_ data: Data) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var path: String?, head = "", branch: String?
        var isBare = false, isLocked = false, isPrunable = false
        func finish() {
            guard let path else { return }
            result.append(GitWorktree(path: path, head: head, branch: branch, isBare: isBare, isLocked: isLocked, isPrunable: isPrunable))
        }
        for bytes in data.split(separator: 0, omittingEmptySubsequences: false) {
            guard !bytes.isEmpty else {
                finish(); path = nil; head = ""; branch = nil; isBare = false; isLocked = false; isPrunable = false
                continue
            }
            let field = String(decoding: bytes, as: UTF8.self)
            if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch refs/heads/") { branch = String(field.dropFirst(18)) }
            else if field == "bare" { isBare = true }
            else if field == "locked" || field.hasPrefix("locked ") { isLocked = true }
            else if field == "prunable" || field.hasPrefix("prunable ") { isPrunable = true }
        }
        finish()
        return result
    }
}
public struct GitCommit: Identifiable, Hashable, Sendable, Codable {
    public var id: String { hash }
    public let hash: String
    public let parents: [String]
    public let author: String
    public let authorEmail: String
    public let committer: String
    public let committerEmail: String
    public let committedDate: Date
    public let date: Date
    public let subject: String
    public let body: String
    public let refs: [String]
    /// Actual parents stay intact; filtered graphs use these visible ancestors.
    public let graphParents: [String]?
    public let signatureStatus: String
    public var shortHash: String { String(hash.prefix(8)) }
    public init(hash: String, parents: [String], author: String, date: Date, subject: String, body: String, refs: [String], authorEmail: String = "", committer: String? = nil, committerEmail: String? = nil, committedDate: Date? = nil, signatureStatus: String = "N", graphParents: [String]? = nil) {
        self.hash = hash; self.parents = parents; self.author = author; self.authorEmail = authorEmail
        self.committer = committer ?? author; self.committerEmail = committerEmail ?? authorEmail
        self.date = date; self.committedDate = committedDate ?? date
        self.subject = subject; self.body = body; self.refs = refs
        self.signatureStatus = signatureStatus; self.graphParents = graphParents
    }
}
extension GitCommit {
    private enum CodingKeys: String, CodingKey {
        case hash, parents, author, authorEmail, committer, committerEmail, committedDate, date, subject, body, refs, graphParents, signatureStatus
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hash: try c.decode(String.self, forKey: .hash), parents: try c.decode([String].self, forKey: .parents),
                  author: try c.decode(String.self, forKey: .author), date: try c.decode(Date.self, forKey: .date),
                  subject: try c.decode(String.self, forKey: .subject), body: try c.decode(String.self, forKey: .body),
                  refs: try c.decode([String].self, forKey: .refs), authorEmail: try c.decodeIfPresent(String.self, forKey: .authorEmail) ?? "",
                  committer: try c.decodeIfPresent(String.self, forKey: .committer), committerEmail: try c.decodeIfPresent(String.self, forKey: .committerEmail),
                  committedDate: try c.decodeIfPresent(Date.self, forKey: .committedDate), signatureStatus: try c.decodeIfPresent(String.self, forKey: .signatureStatus) ?? "N",
                  graphParents: try c.decodeIfPresent([String].self, forKey: .graphParents))
    }
}
public struct GitCommitFile: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let originalPath: String?
    public init(path: String, status: String, originalPath: String? = nil) { self.path = path; self.status = status; self.originalPath = originalPath }
}
public struct GitStash: Identifiable, Hashable, Sendable, Codable {
    public var id: String { ref }
    public let ref: String
    public let subject: String
    public let hash: String
    public let createdDate: Date?
    public init(ref: String, subject: String, hash: String = "", createdDate: Date? = nil) { self.ref = ref; self.subject = subject; self.hash = hash; self.createdDate = createdDate }
}
public enum DiffTarget: Equatable, Sendable {
    case worktree(path: String, untracked: Bool)
    case staged(path: String)
    case commit(hash: String, path: String)
    case between(from: HistoryEndpoint, to: HistoryEndpoint, path: String, originalPath: String? = nil)
}

public extension GitCommit {
    func historyPresentation(parents: [String]? = nil, graphParents: [String]? = nil,
                             refs: [String]? = nil, signatureStatus: String? = nil) -> GitCommit {
        GitCommit(hash: hash, parents: parents ?? self.parents, author: author, date: date,
                  subject: subject, body: body, refs: refs ?? self.refs, authorEmail: authorEmail,
                  committer: committer, committerEmail: committerEmail, committedDate: committedDate,
                  signatureStatus: signatureStatus ?? self.signatureStatus, graphParents: graphParents ?? self.graphParents)
    }
}
