import XCTest
import GitCore
@testable import AuvGit

final class WorkspaceTreeCacheTests: XCTestCase {
    @MainActor
    func testLargeFlatTreeHasBoundedFirstFrameAndCompleteBackgroundRows() async throws {
        let nodes = (0..<10_000).map { WorkspaceFileNode(path: "file\($0)", isDirectory: false, children: []) }
        let cache = WorkspaceTreeRowCache()
        let first = cache.rows(nodes: nodes, repository: "/large", generation: UUID(), visiblePaths: nil, expanded: [])
        XCTAssertLessThanOrEqual(first.count, 2_000)
        let complete = await Task.detached { WorkspaceTreeRows.prepare(nodes, visiblePaths: nil, expanded: []) }.value
        XCTAssertEqual(complete.count, nodes.count)
        XCTAssertEqual(complete.last?.path, "file9999")
    }
    @MainActor
    func testSynchronousRevisitPreservesHierarchyAndEvictsLeastRecentlyUsedRepository() {
        let cache = WorkspaceTreeCache()
        let tree = [WorkspaceFileNode(path: "src", isDirectory: true, children: [WorkspaceFileNode(path: "src/a", isDirectory: false, children: [])])]
        for path in ["/first", "/second"] + (0..<30).map({ "/repo\($0)" }) { cache.store(tree, for: path) }
        XCTAssertEqual(cache.nodes(for: "/first")?.first?.children.first?.path, "src/a")
        cache.store([], for: "/fourth")
        XCTAssertNil(cache.nodes(for: "/second"))
        XCTAssertNotNil(cache.nodes(for: "/first"))
        XCTAssertEqual(cache.nodes(for: "/fourth")?.count, 0)
        cache.store([], for: "/first")
        XCTAssertEqual(cache.nodes(for: "/first")?.count, 0)
    }

    @MainActor
    func testCacheBoundsTotalNodesAndDoesNotRetainOversizedTree() {
        let cache = WorkspaceTreeCache()
        let nodes = (0..<25_001).map { WorkspaceFileNode(path: "file\($0)", isDirectory: false, children: []) }
        cache.store(nodes, for: "/first")
        cache.store(nodes, for: "/second")
        XCTAssertNil(cache.nodes(for: "/first"))
        XCTAssertNotNil(cache.nodes(for: "/second"))
        cache.store(nodes + nodes, for: "/second")
        XCTAssertNil(cache.nodes(for: "/second"))
    }
    func testFilteredRowsKeepAncestorsAndRespectExpansion() {
        let nodes = [WorkspaceFileNode(path: "src", isDirectory: true, children: [
            WorkspaceFileNode(path: "src/a", isDirectory: false, children: []),
            WorkspaceFileNode(path: "src/nested", isDirectory: true, children: [
                WorkspaceFileNode(path: "src/nested/b", isDirectory: false, children: [])])])]
        XCTAssertEqual(WorkspaceTreeRows.prepare(nodes, visiblePaths: ["src/nested/b"], expanded: []).map(\.path), ["src"])
        let rows = WorkspaceTreeRows.prepare(nodes, visiblePaths: ["src/nested/b"], expanded: ["src", "src/nested"])
        XCTAssertEqual(rows.map(\.path), ["src", "src/nested", "src/nested/b"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertTrue(WorkspaceTreeRows.prepare(nodes, visiblePaths: [], expanded: ["src"]).isEmpty)
    }

    @MainActor
    func testDerivedRowsInvalidateForGenerationFilterExpansionAndRepository() {
        let cache = WorkspaceTreeRowCache()
        let generation = UUID()
        let nodes = [WorkspaceFileNode(path: "src", isDirectory: true, children: [WorkspaceFileNode(path: "src/a", isDirectory: false, children: [])])]
        func rows(_ repository: String = "/a", generation: UUID, filter: Set<String>? = nil, expanded: Set<String> = []) -> [String] {
            cache.rows(nodes: nodes, repository: repository, generation: generation, visiblePaths: filter, expanded: expanded).map(\.path)
        }
        XCTAssertEqual(rows(generation: generation), ["src"])
        XCTAssertEqual(rows(generation: generation, expanded: ["src"]), ["src", "src/a"])
        XCTAssertEqual(rows(generation: generation, filter: []), [])
        XCTAssertEqual(rows("/b", generation: generation), ["src"])
        XCTAssertEqual(rows(generation: UUID(), expanded: ["src"]), ["src", "src/a"])
    }
}
