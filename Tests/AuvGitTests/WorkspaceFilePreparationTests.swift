import XCTest
import GitCore
@testable import AuvGit

final class WorkspaceFilePreparationTests: XCTestCase {
    func testRowNamesAndDirectoriesPreserveUnicodeAndDirectoryPaths() {
        for path in ["README.md", "src/资料/文件.swift", "src/.hidden", "ignored/", "src//file.txt", "/file.txt", ""] {
            let row = WorkspaceFileRow(path: path, file: nil)
            XCTAssertEqual(row.name, (path as NSString).lastPathComponent)
            XCTAssertEqual(row.directory, (path as NSString).deletingLastPathComponent)
        }
    }

    func testLargePreparationKeepsFiltersCountsAndNaturalSort() throws {
        let files = (1...10_000).reversed().map { GitFile(path: "src/file\($0).swift", indexStatus: " ", worktreeStatus: "M") }
            + [GitFile(path: ".hidden/file.swift", indexStatus: "?", worktreeStatus: "?")]
        let request = WorkspaceFilePreparation(repository: "/repo", files: files, ignoredPaths: ["src/file2.swift", "src/file10001.swift"], filter: "SRC/", filterCase: "insensitive", category: .all, showHidden: false, showIgnored: true, sort: [.init(column: .name, ascending: true)])
        let result = try request.prepare()
        XCTAssertEqual(result.rows.count, 10_001)
        XCTAssertEqual(result.rows.prefix(3).map(\.path), ["src/file1.swift", "src/file2.swift", "src/file3.swift"])
        XCTAssertEqual(result.rows.last?.path, "src/file10001.swift")
        XCTAssertEqual(result.counts[.all], 10_000)
        XCTAssertEqual(result.counts[.modified], 10_000)
        XCTAssertEqual(result.counts[.untracked, default: 0], 0)
    }

    func testDescendingStatusSortAndRepositoryCacheIsolation() async throws {
        let files = [GitFile(path: "a", indexStatus: "A", worktreeStatus: " "), GitFile(path: "b", indexStatus: "M", worktreeStatus: " ")]
        let first = WorkspaceFilePreparation(repository: "/first", files: files, ignoredPaths: [], filter: "", filterCase: "exact", category: .all, showHidden: true, showIgnored: false, sort: [.init(column: .status, ascending: false)])
        let cache = WorkspaceFilePreparationCache()
        let firstResult = try cache.prepare(first)
        XCTAssertEqual(firstResult.rows.map(\.path), ["b", "a"])
        let second = WorkspaceFilePreparation(repository: "/second", files: [files[0]], ignoredPaths: [], filter: "", filterCase: "exact", category: .all, showHidden: true, showIgnored: false, sort: first.sort)
        let secondResult = try cache.prepare(second)
        XCTAssertEqual(secondResult.paths, ["a"])
        let revisited = try cache.prepare(first)
        XCTAssertEqual(revisited.paths, ["a", "b"])
    }

    func testSynchronousCacheRequiresExactSnapshotAndEvictsLeastRecentlyUsedRepository() throws {
        let cache = WorkspaceFilePreparationCache()
        func request(_ repository: String, filter: String = "") -> WorkspaceFilePreparation {
            WorkspaceFilePreparation(repository: repository, files: [GitFile(path: "file", indexStatus: " ", worktreeStatus: "M")], ignoredPaths: [], filter: filter, filterCase: "exact", category: .all, showHidden: true, showIgnored: false, sort: [])
        }
        XCTAssertNil(cache.cached(request("/first")))
        for path in ["/first", "/second"] + (0..<30).map({ "/repo\($0)" }) { _ = try cache.prepare(request(path)) }
        XCTAssertEqual(cache.cached(request("/first"))?.paths, ["file"])
        XCTAssertNil(cache.cached(request("/first", filter: "missing")))
        _ = try cache.prepare(request("/fourth"))
        XCTAssertNil(cache.cached(request("/second")))
        XCTAssertNotNil(cache.cached(request("/first")))
        _ = try cache.prepare(request("/first", filter: "missing"))
        XCTAssertNil(cache.cached(request("/first")))
        XCTAssertEqual(cache.cached(request("/first", filter: "missing"))?.paths, [])
    }

    func testCancelledPreparationCannotReturnCachedResult() async throws {
        let request = WorkspaceFilePreparation(repository: "/repo", files: [], ignoredPaths: [], filter: "", filterCase: "smart", category: .all, showHidden: true, showIgnored: false, sort: [])
        let cache = WorkspaceFilePreparationCache()
        _ = try cache.prepare(request)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try cache.prepare(request)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled request must not publish a cached result")
        } catch is CancellationError { }
    }
}
