import XCTest
@testable import GitCore

final class CommitGraphTests: XCTestCase {
    private func commit(_ hash: String, _ parents: [String]) -> GitCommit {
        GitCommit(hash: hash, parents: parents, author: "Test", date: Date(), subject: hash, body: "", refs: [])
    }
    func testLinearHistoryAndPartialFrontier() {
        let graph = CommitGraph(commits: [commit("a", ["b"]), commit("b", ["c"])])
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertEqual(graph.frontier, ["c"])
        XCTAssertEqual(graph.rows[1].segments.count, 2)
    }
    func testForkConvergesOnSharedAncestor() {
        let graph = CommitGraph(commits: [commit("a", ["root"]), commit("b", ["root"]), commit("root", [])])
        XCTAssertEqual(graph.rows[1].nodeLane, 1)
        XCTAssertTrue(graph.rows[1].segments.contains { $0.fromLane == 1 && $0.toLane == 0 })
        XCTAssertTrue(graph.frontier.isEmpty)
    }
    func testMergeSplitsAndRejoinsLanes() {
        let graph = CommitGraph(commits: [commit("merge", ["left", "right"]), commit("left", ["root"]), commit("right", ["root"]), commit("root", [])])
        XCTAssertEqual(graph.laneCount, 2)
        XCTAssertEqual(graph.rows[0].segments.filter { $0.fromY == 0.5 }.count, 2)
        XCTAssertTrue(graph.rows[2].segments.contains { $0.fromLane == 1 && $0.toLane == 0 && $0.toY == 1 })
        XCTAssertTrue(graph.frontier.isEmpty)
    }
    func testSegmentsRetainTheLineageTheyRender() {
        let graph = CommitGraph(commits: [commit("merge", ["left", "right"]), commit("left", ["root"]), commit("right", ["root"]), commit("root", [])])
        let split = graph.rows[0].segments.filter { $0.fromY == 0.5 }
        XCTAssertEqual(Set(split.map(\.lineageHash)), ["left", "right"])
        XCTAssertTrue(graph.rows[1].segments.contains { $0.fromLane == 1 && $0.toLane == 1 && $0.lineageHash == "right" })
        XCTAssertTrue(graph.rows[2].segments.contains { $0.fromLane == 1 && $0.toLane == 0 && $0.lineageHash == "root" })
    }
}
