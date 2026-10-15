import Foundation
import GitCore

struct WorkspaceFileRow: Identifiable, Sendable {
    let path: String
    let file: GitFile?
    var id: String { path }
    var isIgnored: Bool { file == nil }
    let name: String
    let directory: String
    init(path: String, file: GitFile?) {
        self.path = path; self.file = file
        if path.hasSuffix("/") || path.contains("//") {
            name = (path as NSString).lastPathComponent
            directory = (path as NSString).deletingLastPathComponent
        } else if let slash = path.lastIndex(of: "/") {
            name = String(path[path.index(after: slash)...])
            directory = slash == path.startIndex ? "/" : String(path[..<slash])
        } else {
            name = path; directory = ""
        }
    }
    var statusKey: String {
        guard let file else { return "!" }
        return file.isConflict ? "U" : file.isUntracked ? "?" : file.indexStatus != " " ? file.indexStatus : file.worktreeStatus
    }
    var worktreeKey: String { file?.worktreeStatus ?? " " }
    var indexKey: String { file?.indexStatus ?? " " }
}

struct WorkspaceFilePreparation: Equatable, Sendable {
    struct Sort: Equatable, Sendable {
        enum Column: Sendable { case path, name, directory, status, worktree, index }
        let column: Column
        let ascending: Bool
    }
    let repository: String?
    let files: [GitFile]
    let ignoredPaths: [String]
    let filter: String
    let filterCase: String
    let category: WorkspaceStatusFilter
    let showHidden: Bool
    let showIgnored: Bool
    let sort: [Sort]

    struct Result: Sendable {
        let rows: [WorkspaceFileRow]
        let paths: Set<String>
        let counts: [WorkspaceStatusFilter: Int]
    }
    func prepare() throws -> Result {
        var counts: [WorkspaceStatusFilter: Int] = [:]
        var rows: [WorkspaceFileRow] = []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func visible(_ path: String) -> Bool {
            (showHidden || !WorkspaceStatusFilter.isHiddenPath(path)) && (query.isEmpty || AuvGitPreferences.matches(path, query: query, caseMode: filterCase))
        }
        for (offset, file) in files.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            guard showHidden || !WorkspaceStatusFilter.isHiddenPath(file.path) else { continue }
            for item in WorkspaceStatusFilter.allCases where item.includes(file) { counts[item, default: 0] += 1 }
            if category.includes(file), visible(file.path) { rows.append(WorkspaceFileRow(path: file.path, file: file)) }
        }
        if showIgnored, category == .all {
            let existing = Set(files.map(\.path))
            for (offset, path) in ignoredPaths.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                if !existing.contains(path), visible(path) { rows.append(WorkspaceFileRow(path: path, file: nil)) }
            }
        }
        func value(_ row: WorkspaceFileRow, _ column: Sort.Column) -> String {
            switch column {
            case .path: return row.path
            case .name: return row.name
            case .directory: return row.directory
            case .status: return row.statusKey
            case .worktree: return row.worktreeKey
            case .index: return row.indexKey
            }
        }
        rows.sort { lhs, rhs in
            for order in sort {
                let comparison: ComparisonResult
                switch order.column {
                case .path, .name, .directory: comparison = value(lhs, order.column).localizedStandardCompare(value(rhs, order.column))
                case .status, .worktree, .index: comparison = value(lhs, order.column).compare(value(rhs, order.column))
                }
                if comparison != .orderedSame { return order.ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        try Task.checkCancellation()
        return Result(rows: rows, paths: Set(rows.map(\.path)), counts: counts)
    }
}

final class WorkspaceFilePreparationCache: @unchecked Sendable {
    static let shared = WorkspaceFilePreparationCache()
    private let lock = NSLock()
    private var entries: [(WorkspaceFilePreparation, WorkspaceFilePreparation.Result)] = []
    func cached(_ request: WorkspaceFilePreparation) -> WorkspaceFilePreparation.Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.0 == request }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.1
    }
    func prepare(_ request: WorkspaceFilePreparation) throws -> WorkspaceFilePreparation.Result {
        try Task.checkCancellation()
        if let result = cached(request) { return result }
        let result = try request.prepare()
        lock.lock()
        defer { lock.unlock() }
        // Keep a few visited repositories without retaining unbounded large status snapshots.
        if request.files.count + request.ignoredPaths.count + result.rows.count <= 50_000 {
            entries.removeAll { $0.0.repository == request.repository }
            entries.append((request, result))
            while entries.count > 32 || entries.reduce(0, { $0 + $1.0.files.count + $1.0.ignoredPaths.count + $1.1.rows.count }) > 50_000 { entries.removeFirst() }
        }
        return result
    }
}
