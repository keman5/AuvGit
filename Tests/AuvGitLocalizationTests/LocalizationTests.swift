import XCTest
import Foundation
@testable import AuvGitLocalization

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "zh-Hans", "zh-Hant", "ja"]

    func testSystemLanguageResolutionAndFallback() {
        let cases: [(String, [String], String)] = [
            ("en", ["ja-JP"], "en"),
            ("zh-Hant", ["en-US"], "zh-Hant"),
            ("system", ["zh-TW"], "zh-Hant"),
            ("system", ["zh-HK"], "zh-Hant"),
            ("system", ["zh-MO"], "zh-Hant"),
            ("system", ["zh-Hant-US"], "zh-Hant"),
            ("system", ["zh-CN"], "zh-Hans"),
            ("system", ["zh-SG"], "zh-Hans"),
            ("system", ["zh-Hans-HK"], "zh-Hans"),
            ("system", ["ja-JP"], "ja"),
            ("system", ["fr-FR", "ja-JP"], "ja"),
            ("system", ["fr-FR", "en-GB"], "en"),
            ("system", ["fr-FR"], "en"),
            ("system", [], "en")
        ]
        for (preference, preferred, expected) in cases {
            XCTAssertEqual(L10n.resolvedLanguage(preference: preference, preferredLanguages: preferred).rawValue, expected, "\(preference) / \(preferred)")
        }
    }

    func testEveryLanguageHasEveryKeyAndMatchingFormatArguments() throws {
        let root = L10n.resourceBundle.bundleURL
        let englishDirectory = try XCTUnwrap(findLocale("en", root: root))
        let tableURLs = try FileManager.default.contentsOfDirectory(at: englishDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "strings" }
        XCTAssertGreaterThanOrEqual(tableURLs.count, 3)
        var total = 0
        for tableURL in tableURLs {
            let source = try readTable(tableURL)
            XCTAssertFalse(source.isEmpty)
            total += source.count
            for language in languages {
                let directory = try XCTUnwrap(findLocale(language, root: root), "Missing locale \(language)")
                let translated = try readTable(directory.appendingPathComponent(tableURL.lastPathComponent))
                XCTAssertEqual(Set(source.keys), Set(translated.keys), "Key parity: \(language)/\(tableURL.lastPathComponent)")
                for (key, value) in source {
                    let localized = try XCTUnwrap(translated[key])
                    XCTAssertFalse(localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(language)/\(key)")
                    XCTAssertEqual(placeholders(value), placeholders(localized), "Format parity: \(language)/\(key)")
                    if placeholders(value).isEmpty {
                        let actual = L10n.text(key, table: tableURL.deletingPathExtension().lastPathComponent, arguments: [], language: try XCTUnwrap(AppLanguage(rawValue: language)))
                        XCTAssertEqual(actual, localized, "Runtime lookup \(language)/\(key)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(total, 60)
    }

    func testFormattedCountsAndUserTextArePreserved() throws {
        let file = "src/日本語 100% ready.swift"
        for code in languages {
            let language = try XCTUnwrap(AppLanguage(rawValue: code))
            let title = L10n.text("%@  ·  HEAD → Index", arguments: [file], language: language)
            XCTAssertTrue(title.hasPrefix(file), "User path changed: \(code)")
            let count = L10n.text("diff.hunkCount", table: "Detail", arguments: [Int(12)], language: language)
            XCTAssertTrue(count.contains("12"), "Count not interpolated: \(code)")
            XCTAssertFalse(count.contains("%ld"))
            let status = L10n.text("Refreshed · %@ changes · %@ staged", arguments: ["3", "2"], language: language)
            XCTAssertTrue(status.contains("3")); XCTAssertTrue(status.contains("2"))
        }
    }

    func testUnknownKeysRemainReadable() throws {
        for code in languages {
            XCTAssertEqual(L10n.text("__missing_translation__", table: "UnknownTable", arguments: [], language: try XCTUnwrap(AppLanguage(rawValue: code))), "__missing_translation__")
        }
    }

    private func findLocale(_ code: String, root: URL) -> URL? {
        let expected = "\(code).lproj".lowercased()
        return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent.lowercased() == expected }
    }
    private func readTable(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
    private func placeholders(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:[-+0 #]*)(?:\d+)?(?:\.\d+)?(?:ll|l|h)?[@diuoxXfFeEgGcs%]"#)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let token = String(value[range]); if token == "%%" { return nil }
            return token.replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression)
        }.sorted()
    }
}
