# Worktree-aware Repositories Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Register usable linked Git worktrees as RayGit projects and route branch selection to the project that already owns the branch.

**Architecture:** GitCore owns parsing and discovery of Git's worktree porcelain format. RepositoryStore owns application registration and navigation, querying GitCore live before branch switching while retaining the existing checkout and auto-stash behavior for unowned branches.

**Tech Stack:** Swift 6, Swift Package Manager, Swift concurrency, XCTest, Git CLI porcelain output.

---

### Task 1: Add worktree discovery to GitCore

**Files:**
- Modify: `Sources/GitCore/Models.swift`
- Modify: `Sources/GitCore/GitRepository.swift`
- Test: `Tests/GitCoreTests/GitWorktreeTests.swift`

**Step 1: Write the failing tests**

Create tests that build a real repository with a linked worktree and assert discovery returns the main and linked paths with their local branches. Add a parser fixture containing spaces, detached, bare, locked, and prunable entries, asserting only usable branch mappings are retained.

**Step 2: Run tests to verify they fail**

Run: `swift test --filter GitWorktreeTests`

Expected: compilation fails because `GitWorktree` and `GitRepository.worktrees()` do not exist.

**Step 3: Write minimal implementation**

Add a Sendable, Equatable worktree model. Run `git worktree list --porcelain -z`, parse records by NUL fields, normalize `refs/heads/<name>` to the local branch name, and expose all records so callers can decide whether a path is usable.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter GitWorktreeTests`

Expected: all GitWorktreeTests pass.

### Task 2: Synchronize linked worktrees when opening a repository

**Files:**
- Modify: `Sources/RayGit/RayGitApp.swift`
- Test: `Tests/RayGitTests/WorktreeRepositoryStoreTests.swift`

**Step 1: Write the failing test**

Open a fixture repository through a transient `RepositoryStore` and assert both usable worktree paths appear once in `openRepositories` and `recentPaths`, while the explicitly selected repository remains active.

**Step 2: Run test to verify it fails**

Run: `swift test --filter WorktreeRepositoryStoreTests`

Expected: the linked worktree path is absent.

**Step 3: Write minimal implementation**

Add an idempotent repository-list merge helper. During `performOpen`, discover linked worktrees, validate each with `GitRepository.open`, then merge their canonical paths into the session and recent list without changing the active repository.

**Step 4: Run test to verify it passes**

Run: `swift test --filter WorktreeRepositoryStoreTests`

Expected: all WorktreeRepositoryStoreTests pass.

### Task 3: Route occupied branches to their worktree project

**Files:**
- Modify: `Sources/RayGit/BranchSwitch.swift`
- Test: `Tests/RayGitTests/BranchSwitchTests.swift`

**Step 1: Write the failing test**

Create a linked worktree for `other`, open the main repository store, select `other`, and assert the store opens the linked path without invoking checkout or creating a stash.

**Step 2: Run test to verify it fails**

Run: `swift test --filter BranchSwitchTests`

Expected: Git rejects checkout because the branch is already used by another worktree.

**Step 3: Write minimal implementation**

Before starting the existing branch-switch operation, query worktrees and find another non-prunable entry whose branch matches. Verify it is openable and call `requestOpen`; otherwise continue through `BranchSwitch.perform` unchanged.

**Step 4: Run test to verify it passes**

Run: `swift test --filter BranchSwitchTests`

Expected: all BranchSwitchTests pass.

### Task 4: Regression verification

**Files:**
- Verify only.

**Step 1: Run focused tests**

Run: `swift test --filter 'GitWorktreeTests|WorktreeRepositoryStoreTests|BranchSwitchTests'`

Expected: all focused tests pass.

**Step 2: Run the complete suite**

Run: `swift test`

Expected: all tests pass with no failures.

**Step 3: Build the application locally**

Run: `swift build`

Expected: build exits successfully. No VPS build or deployment is involved.
