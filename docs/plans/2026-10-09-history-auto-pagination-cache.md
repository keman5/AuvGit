# History Auto Pagination And Memory Cache Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development while implementing this plan.

**Goal:** Automatically load more commits near the bottom of the history list and retain each repository's loaded history in memory while RayGit remains open.

**Architecture:** `HistoryPane` owns a small, deterministic prefetch gate keyed by the current commit count, so reaching the final rows requests one next page without displaying a button or issuing duplicate requests. `RepositoryStore` keeps process-local snapshots keyed by normalized repository root path; switching away captures the current history and switching back restores it immediately, then refreshes the same loaded depth from Git.

**Tech Stack:** Swift 6, SwiftUI, Swift Concurrency, XCTest, Swift Package Manager.

---

### Task 1: History prefetch policy

**Files:**
- Modify: `Sources/RayGit/HistoryPane.swift`
- Test: `Tests/RayGitTests/HistoryPaginationTests.swift`

1. Add failing tests for the near-bottom threshold, loading/terminal-state suppression, and one request per commit count.
2. Run `swift test --build-system native --filter HistoryPaginationTests` and confirm the new policy symbols are missing.
3. Add the minimal policy and attach it to commit-row appearance.
4. Remove the visible load-more footer while retaining the loading state through existing row/content presentation.
5. Re-run the focused tests.

### Task 2: Process-local per-repository history cache

**Files:**
- Modify: `Sources/RayGit/RayGitApp.swift`
- Test: `Tests/RayGitTests/HistoryPaginationTests.swift`

1. Add a failing integration test that loads more than one page in repository A, switches to B, and switches back to A.
2. Assert repository A restores its previous commit count immediately and a reset refresh requests at least that cached depth.
3. Add an in-memory snapshot containing commits, loaded count, `hasMore`, and local-unpushed hashes, keyed by standardized repository root path.
4. Capture before clearing a repository, restore after opening its root, and make reset loads preserve the restored depth.
5. Re-run the focused tests.

### Task 3: Verification

**Files:**
- Verify only; do not commit or alter unrelated working-tree changes.

1. Run `swift test --build-system native --filter HistoryPaginationTests`.
2. Run `swift test --build-system native`.
3. Run `python3 scripts/check-localizations.py` and `git diff --check`.
4. Build locally with `./scripts/build-app.sh`; do not deploy or replace the installed application unless separately requested.
