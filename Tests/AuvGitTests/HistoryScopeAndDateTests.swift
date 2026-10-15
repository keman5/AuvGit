import XCTest
import GitCore
@testable import AuvGit

final class HistoryScopeAndDateTests: XCTestCase {
    func testStashScopeKeepsObjectIdentityWhenStashIndicesMove() {
        let original = GitStash(ref: "stash@{0}", subject: "original", hash: "aaa")
        let checked = HistoryBranchScope.migrate(["stash@{0}", "HEAD"], stashes: [original])
        XCTAssertEqual(checked, ["$stash:aaa", "HEAD"])
        let moved = GitStash(ref: "stash@{1}", subject: "original", hash: "aaa")
        let newer = GitStash(ref: "stash@{0}", subject: "newer", hash: "bbb")
        XCTAssertTrue(checked.contains(HistoryBranchScope.stashRef(moved)))
        XCTAssertFalse(checked.contains(HistoryBranchScope.stashRef(newer)))
        XCTAssertEqual(HistoryBranchScope.migrate(checked, stashes: [newer, moved]), checked)
    }
    func testPerRepositoryScopeRoundTripsEmptyAndFullReferences() throws {
        let suite = "HistoryScopeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/tmp/repository-a"), second = URL(fileURLWithPath: "/tmp/repository-b")
        XCTAssertNil(HistoryBranchScope.load(repository: first, defaults: defaults))
        XCTAssertEqual(HistoryBranchScope.defaultRefs(branches: [], branch: "Detached abc123"), ["HEAD", HistoryBranchScope.allStashes])
        let refs: Set<String> = ["refs/heads/origin/topic", "refs/remotes/origin/topic"]
        HistoryBranchScope.save(refs, repository: first, defaults: defaults)
        HistoryBranchScope.save([], repository: second, defaults: defaults)
        XCTAssertEqual(HistoryBranchScope.load(repository: first, defaults: defaults), refs)
        XCTAssertEqual(HistoryBranchScope.load(repository: second, defaults: defaults), [])
    }
    func testGenericPresentationClearsStaleTagAndPinnedContext() {
        let available: Set<String> = ["refs/heads/main"]
        XCTAssertEqual(HistoryBranchScope.presentationReference(requested: nil, previous: "refs/tags/old", availableBranches: available), "HEAD")
        XCTAssertEqual(HistoryBranchScope.presentationReference(requested: nil, previous: "deadbeef", availableBranches: available), "HEAD")
        XCTAssertEqual(HistoryBranchScope.presentationReference(requested: nil, previous: "refs/heads/main", availableBranches: available), "refs/heads/main")
        XCTAssertEqual(HistoryBranchScope.presentationReference(requested: "refs/tags/requested", previous: "HEAD", availableBranches: available), "refs/tags/requested")
    }
    func testLegacyScopeGainsStashDefaultButNewExplicitEmptyScopeRoundTrips() throws {
        let suite = "HistoryScopeMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = URL(fileURLWithPath: "/tmp/migration-repository")
        defaults.set([HistoryBranchScope.repositoryKey(repository): ["refs/heads/topic"]], forKey: HistoryBranchScope.legacyPreferenceKey)
        XCTAssertEqual(HistoryBranchScope.load(repository: repository, defaults: defaults), ["refs/heads/topic", HistoryBranchScope.allStashes])
        HistoryBranchScope.save([], repository: repository, defaults: defaults)
        XCTAssertEqual(HistoryBranchScope.load(repository: repository, defaults: defaults), [])
    }
    func testDefaultStashesSurviveBranchContextAndCanBeExplicitlyUnchecked() {
        let stashes = [GitStash(ref: "stash@{0}", subject: "latest", hash: "aaa"), GitStash(ref: "stash@{1}", subject: "older", hash: "bbb")]
        let defaults = HistoryBranchScope.defaultRefs(branches: [], branch: "main")
        let branchScope = HistoryBranchScope.preservingStashes(in: defaults, forBranch: "refs/heads/main")
        XCTAssertEqual(Set(HistoryBranchScope.selectedStashHashes(branchScope, stashes: stashes)), ["aaa", "bbb"])
        XCTAssertEqual(HistoryBranchScope.revisionRefs(branchScope, branches: [], stashes: stashes), [])
        let unchecked = HistoryBranchScope.setting("$stash:aaa", checked: false, in: branchScope, stashes: stashes)
        XCTAssertEqual(HistoryBranchScope.selectedStashHashes(unchecked, stashes: stashes), ["bbb"])
        XCTAssertFalse(unchecked.contains(HistoryBranchScope.allStashes))
        XCTAssertEqual(HistoryBranchScope.preservingStashes(in: [], forBranch: "HEAD"), ["HEAD"])
    }
    func testCalendarDatesUseDayBoundariesAndNeverShowSeconds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 0, minute: 5))!
        func day(_ distance: Int) -> Date { calendar.date(byAdding: .day, value: -distance, to: now)!.addingTimeInterval(13 * 3600 + 7 * 60 + 42) }
        XCTAssertEqual(HistoryCalendarDate.text(day(0), now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "Today 13:12")
        XCTAssertEqual(HistoryCalendarDate.text(day(1), now: now, calendar: calendar, locale: Locale(identifier: "zh_Hans")), "昨天 13:12")
        XCTAssertEqual(HistoryCalendarDate.text(day(2), now: now, calendar: calendar, locale: Locale(identifier: "ja_JP")), "一昨日 13:12")
        XCTAssertEqual(HistoryCalendarDate.text(day(3), now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "Thursday 13:12")
        XCTAssertEqual(HistoryCalendarDate.text(day(7), now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "2026-09-27 13:12")
        let yesterdayLate = now.addingTimeInterval(-10 * 60)
        XCTAssertEqual(HistoryCalendarDate.text(yesterdayLate, now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "Yesterday 23:55")
    }
}
