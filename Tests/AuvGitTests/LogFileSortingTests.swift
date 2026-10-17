import Foundation
import XCTest
import GitCore
@testable import AuvGit

final class LogFileSortingTests: XCTestCase {
    func testFileLabelsKeepBasenamesAndRepositoryRelativeRenamePaths() {
        let file = GitCommitFile(path: "Sources/新名称.swift", status: "R", originalPath: "旧目录/旧名称.swift")
        XCTAssertEqual(file.logFileName, "新名称.swift")
        XCTAssertEqual(file.logPathHelp, "旧目录/旧名称.swift → Sources/新名称.swift")
        let rootFile = GitCommitFile(path: "README.md", status: "M")
        XCTAssertEqual(rootFile.logFileName, "README.md")
        XCTAssertEqual(rootFile.logPathHelp, "README.md")
    }

    func testAllColumnsCycleAndRestoreOriginalGitOrder() {
        let files = [GitCommitFile(path: "z/file2.swift", status: "M"),
                     GitCommitFile(path: "a/file10.swift", status: "D"),
                     GitCommitFile(path: "b/file1.swift", status: "A")]
        for keyPath in [\GitCommitFile.logFileName, \.status, \.path] {
            let ascending = KeyPathComparator(keyPath, comparator: .localizedStandard)
            let descending = KeyPathComparator(keyPath, comparator: .localizedStandard, order: .reverse)
            var order: [KeyPathComparator<GitCommitFile>] = []
            for _ in 0..<2 {
                order = LogFileSorting.cycle([ascending], after: order)
                XCTAssertEqual(order, [ascending])
                XCTAssertEqual(LogFileSorting.sorted(files, by: order), files.sorted(using: ascending))
                order = LogFileSorting.cycle([descending], after: order)
                XCTAssertEqual(order, [descending])
                XCTAssertEqual(LogFileSorting.sorted(files, by: order), files.sorted(using: descending))
                order = LogFileSorting.cycle([ascending], after: order)
                XCTAssertTrue(order.isEmpty)
                XCTAssertEqual(LogFileSorting.sorted(files, by: order), files)
            }
        }
        XCTAssertEqual(LogFileSorting.sorted(files, by: [KeyPathComparator(\.logFileName, comparator: .localizedStandard)]).map(\.path),
                       ["b/file1.swift", "z/file2.swift", "a/file10.swift"])
    }

    func testChangingColumnDropsOldSortAndKeepsDuplicateNamesDeterministic() {
        let name = KeyPathComparator(\GitCommitFile.logFileName, order: .reverse)
        let path = KeyPathComparator(\GitCommitFile.path)
        XCTAssertEqual(LogFileSorting.cycle([path, name], after: [name]), [path])
        let files = [GitCommitFile(path: "z/file", status: "M"), GitCommitFile(path: "a/file", status: "M")]
        XCTAssertEqual(LogFileSorting.sorted(files, by: [name]).map(\.path), ["a/file", "z/file"])
    }
}
