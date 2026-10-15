# Recent Commit Messages Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task.

**Goal:** Replace commit-template actions in the commit editor menu with repository-scoped recent commit messages.

**Architecture:** Persist up to ten successful commit or amend messages per canonical repository path in `UserDefaults`. `RepositoryStore` owns the active repository's published history, records only after `git commit` succeeds, and exposes clear/select behavior to the SwiftUI menu.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, Swift Package Manager

---

### Task 1: Persist repository-scoped history

**Files:**
- Create: `Sources/AuvGit/CommitMessageHistory.swift`
- Create: `Tests/AuvGitTests/CommitMessageHistoryTests.swift`

1. Write failing tests for repository isolation, exact-message de-duplication, newest-first order, ten-item limit, and repository-scoped clearing.
2. Run `swift test --build-system native --filter CommitMessageHistoryTests` and confirm the missing type fails the test build.
3. Implement the minimal `UserDefaults`-backed history store.
4. Re-run the focused tests and confirm they pass.

### Task 2: Record only successful commits and amendments

**Files:**
- Modify: `Sources/AuvGit/AuvGitApp.swift`
- Modify: `Sources/AuvGit/WorkspaceCommit.swift`
- Test: `Tests/AuvGitTests/CommitMessageHistoryTests.swift`

1. Add a failing integration test proving successful commits and amendments are recorded while failed commits are not.
2. Publish the active repository's history from `RepositoryStore` and record after `GitRepository.commit` returns successfully.
3. Run the focused tests and confirm they pass.

### Task 3: Replace the template menu actions

**Files:**
- Modify: `Sources/AuvGit/MainWindow.swift`
- Modify: `Sources/AuvGitLocalization/Resources/en.lproj/MainRefinement.strings`
- Modify: `Sources/AuvGitLocalization/Resources/ja.lproj/MainRefinement.strings`
- Modify: `Sources/AuvGitLocalization/Resources/zh-Hans.lproj/MainRefinement.strings`
- Modify: `Sources/AuvGitLocalization/Resources/zh-Hant.lproj/MainRefinement.strings`

1. Remove the two commit-template actions and their now-unused view helpers.
2. Add a recent-message submenu whose items replace the full editor text.
3. Add a bottom clear action that clears only AuvGit's active-repository history.
4. Run focused tests, the full test suite, and a local debug build.
