import XCTest
import GitCore
@testable import AuvGit

final class WorkspaceTreeCacheTests: XCTestCase {
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
}
