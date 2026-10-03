import Foundation

public struct GitFile: Identifiable, Hashable, Sendable {
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
public struct GitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public init(name: String, isCurrent: Bool, isRemote: Bool) { self.name = name; self.isCurrent = isCurrent; self.isRemote = isRemote }
}
public struct GitCommit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let subject: String
    public let body: String
    public let refs: [String]
    public var shortHash: String { String(hash.prefix(8)) }
    public init(hash: String, parents: [String], author: String, date: Date, subject: String, body: String, refs: [String]) { self.hash = hash; self.parents = parents; self.author = author; self.date = date; self.subject = subject; self.body = body; self.refs = refs }
}
public struct GitCommitFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let originalPath: String?
    public init(path: String, status: String, originalPath: String? = nil) { self.path = path; self.status = status; self.originalPath = originalPath }
}
public struct GitStash: Identifiable, Hashable, Sendable {
    public var id: String { ref }
    public let ref: String
    public let subject: String
    public init(ref: String, subject: String) { self.ref = ref; self.subject = subject }
}
public enum DiffTarget: Equatable, Sendable {
    case worktree(path: String, untracked: Bool)
    case staged(path: String)
    case commit(hash: String, path: String)
}
