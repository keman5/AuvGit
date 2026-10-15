# History Message Indentation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task.

**Goal:** Indent each commit message according to the number of graph lanes used by that history row, without shifting the author, date, or hash columns.

**Architecture:** Compute a stable lane spacing from the maximum graph width and maximum lane count. Give each row only the graph width required by its active lanes, then add the unused graph width to that row's message width so the combined graph-message region stays constant.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Swift Package Manager.

---

### Task 1: Define row layout geometry

**Files:**
- Modify: `Sources/AuvGit/HistoryColumnLayout.swift`
- Test: `Tests/AuvGitTests/HistoryColumnLayoutTests.swift`

1. Add a failing test proving that rows with more active lanes receive a wider graph and a larger message indent.
2. Prove that graph width plus message width stays constant for every row.
3. Implement the smallest pure layout helper that satisfies those constraints.
4. Run the focused layout tests.

### Task 2: Apply row-specific graph and message widths

**Files:**
- Modify: `Sources/AuvGit/HistoryPane.swift`

1. Compute row widths from `CommitGraph.Row.laneCount` and the graph-wide maximum lane count.
2. Render each graph cell with its active lane count so lane spacing remains stable.
3. Compensate the message width so author, date, and hash columns remain aligned.
4. Run history and graph tests, the complete Swift test suite, localization validation, `git diff --check`, and the local app build.
