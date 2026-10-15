# Accessible Commit Graph Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development while implementing each task.

**Goal:** Render a color-blind-resilient commit graph whose color, line pattern, and node shape encode independent Git semantics.

**Architecture:** Keep `GitCore.CommitGraph` responsible for topology and place all visual classification in a pure AuvGit presentation model. The SwiftUI Canvas consumes resolved styles for segments and nodes, while history labels reuse the same branch color plan.

**Tech Stack:** Swift 6, SwiftUI Canvas, XCTest, Swift Package Manager.

---

### Task 1: Specify branch and commit semantics

**Files:**
- Replace: `Sources/AuvGit/HistoryGraphColors.swift`
- Replace: `Tests/AuvGitTests/HistoryGraphColorsTests.swift`

1. Add failing tests for fixed `main`/`develop` colors, stable feature palette allocation, remote-only purple, merged/unmerged stroke kinds, and tag amber.
2. Add failing tests for ordinary, merge, remote-only, and `HEAD` node kinds.
3. Run `swift test --build-system native --filter HistoryGraphColorsTests` and verify the tests fail for the missing API.
4. Implement `HistoryGraphStylePlan` as a pure value type over `[GitCommit]` and remote branch names.
5. Re-run the focused tests and verify they pass.

### Task 2: Preserve style identity through graph topology

**Files:**
- Modify: `Sources/GitCore/CommitGraph.swift`
- Modify: `Tests/GitCoreTests/CommitGraphTests.swift`

1. Extend the existing lineage tests with unnamed side-lineage and frontier cases.
2. Run `swift test --build-system native --filter CommitGraphTests` and confirm the new assertions fail if lineage identity is lost.
3. Make the minimum topology change needed to preserve lineage hashes consistently.
4. Re-run the focused tests.

### Task 3: Render stroke and node variants

**Files:**
- Modify: `Sources/AuvGit/HistoryPane.swift`
- Modify: `Sources/AuvGit/WorkspaceStyle.swift`

1. Add testable rendering-style helpers for line width, dash pattern, and node kind.
2. Update `CommitGraphCell` to draw background halos, rounded Bezier strokes, filled/ring/hollow nodes, and the `HEAD` outer ring.
3. Keep branch colors visible on selected rows and use the selection color only for the halo.
4. Update reference pills to use the shared style plan and amber tag override.

### Task 4: Enforce accessible graph geometry

**Files:**
- Modify: `Sources/AuvGit/HistoryColumnLayout.swift`
- Modify: `Sources/AuvGit/HistoryPane.swift`
- Modify: `Tests/AuvGitTests/HistoryColumnLayoutTests.swift`

1. Add failing layout tests for 18-point lane spacing and stable graph/message width totals.
2. Run the focused layout tests and confirm failure.
3. Update graph width calculations and set compact/noncompact rows to 24/28 points.
4. Re-run the focused layout tests.

### Task 5: Verify locally

1. Run the focused graph and layout tests.
2. Run `swift test --build-system native`.
3. Run `python3 scripts/check-localizations.py`.
4. Run `git diff --check`.
5. Run `./scripts/build-app.sh` locally.
6. Launch the local app against a merge-heavy fixture and inspect light and dark screenshots.
