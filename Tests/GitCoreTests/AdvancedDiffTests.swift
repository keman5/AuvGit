import XCTest
@testable import GitCore

final class AdvancedDiffTests: XCTestCase {
    func testRepeatedAndMovedLinesBlocksReconstructSource() {
        var samples = [""]
        for count in 1...4 {
            for mask in 0..<(1 << count) {
                samples.append((0..<count).map { mask & (1 << $0) == 0 ? "a" : "b" }.joined(separator: "\n"))
            }
        }
        for source in samples {
            for target in samples {
                let blocks = TextLineDiff(source: source, target: target).blocks()
                var accepted = target
                for block in blocks.reversed() { accepted = TextLineDiff.accepting(block, source: source, target: accepted) }
                XCTAssertEqual(accepted, source, "\(source.debugDescription) / \(target.debugDescription)")
            }
        }
    }
    func testAcceptOneBlockPreservesOtherEdits() {
        let source = "a\nold\ncommon\nsource\n"
        let target = "a\nnew\ncommon\ntarget\n"
        let blocks = TextLineDiff(source: source, target: target).blocks()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(TextLineDiff.accepting(blocks[0], source: source, target: target), "a\nold\ncommon\ntarget\n")
    }
    func testAcceptDeletionAndInsertion() {
        let a = "a\nb\nc", b = "a\nc"
        let insertion = TextLineDiff(source: a, target: b).blocks()[0]
        XCTAssertTrue(insertion.targetLines.isEmpty)
        XCTAssertEqual(TextLineDiff.accepting(insertion, source: a, target: b), a)
        let deletion = TextLineDiff(source: b, target: a).blocks()[0]
        XCTAssertTrue(deletion.sourceLines.isEmpty)
        XCTAssertEqual(TextLineDiff.accepting(deletion, source: b, target: a), b)
    }
    func testUTF16CharacterRanges() {
        let diff = CharacterDiff(source: "😀 old end", target: "😀 new end")
        XCTAssertEqual(diff.source, [NSRange(location: 3, length: 3)])
        XCTAssertEqual(diff.target, [NSRange(location: 3, length: 3)])
    }
    func testSyntaxIgnoresKeywordsInsideCommentAndString() {
        let text = "// let 42\nlet x = \"return 99\""
        let tokens = SyntaxHighlighter.tokens(in: text, path: "file.swift")
        XCTAssertEqual(tokens.map(\.kind), [.comment, .keyword, .string])
        XCTAssertEqual((text as NSString).substring(with: tokens[1].range), "let")
        XCTAssertTrue(SyntaxHighlighter.tokens(in: text, path: "file.txt").isEmpty)
    }
    func testBOMUTF16DoesNotBecomeBinary() {
        for (bom, encoding) in [([UInt8(0xff), 0xfe], String.Encoding.utf16LittleEndian), ([UInt8(0xfe), 0xff], .utf16BigEndian)] {
            var data = Data(bom); data.append("hello 世界\n".data(using: encoding)!)
            let result = ComparisonTextDecoder.decode(data)
            XCTAssertEqual(result.text, "hello 世界\n")
            XCTAssertFalse(result.isBinary)
            XCTAssertNotNil(result.readOnlyReason)
        }
        XCTAssertTrue(ComparisonTextDecoder.decode(Data([0, 1, 2])).isBinary)
    }
    func testPagingBoundaryAndUnicode() {
        let text = (1...1001).map { "\($0) 😀\n" }.joined()
        let second = TextPager.page(text, index: 1)
        XCTAssertEqual(second.firstLine, 501)
        XCTAssertTrue(second.text.hasPrefix("501 😀\n"))
        XCTAssertTrue(second.text.hasSuffix("1000 😀\n"))
        XCTAssertTrue(second.hasNext)
        let last = TextPager.page(text, index: 2)
        XCTAssertEqual(last.text, "1001 😀\n")
        XCTAssertFalse(last.hasNext)
        XCTAssertEqual(TextPager.page("short", index: 5).text, "")
    }
    func testLongLinePagesAreBounded() {
        let text = String(repeating: "😀", count: 100_001)
        let first = TextPager.page(text, index: 0)
        let second = TextPager.page(text, index: 1)
        let third = TextPager.page(text, index: 2)
        XCTAssertLessThanOrEqual(first.text.utf16.count, 100_000)
        XCTAssertEqual(first.text + second.text + third.text, text)
        XCTAssertEqual(second.firstLine, 1)
    }
    func testEmojiChangeDoesNotSplitSurrogatePair() {
        let diff = CharacterDiff(source: "😀", target: "😁")
        XCTAssertEqual(diff.source, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(diff.target, [NSRange(location: 0, length: 2)])
    }
    func testMergeCleanAndConflictingDraft() async throws {
        let clean = try await MergePreview.create(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n")
        XCTAssertFalse(clean.hasConflicts)
        XCTAssertEqual(clean.text, "A\nb\nC\n")
        let conflict = try await MergePreview.create(base: "base\n", ours: "ours\n", theirs: "theirs\n")
        XCTAssertTrue(conflict.hasConflicts)
        XCTAssertTrue(conflict.text.contains("<<<<<<< Ours"))
        XCTAssertTrue(conflict.text.contains("||||||| Base"))
        XCTAssertTrue(conflict.text.contains(">>>>>>> Theirs"))
    }
}
