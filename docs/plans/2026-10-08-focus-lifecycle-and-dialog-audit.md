# Focus Lifecycle and Dialog Audit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the first Tab press work when AuvGit opens a sheet, isolate focus between sheets, popovers, and parent windows, and verify keyboard traversal across the app's dialog surfaces.

**Architecture:** Keep the existing AppKit-backed `NativeFocusCoordinator`, but test and repair it at real SwiftUI presentation boundaries. Each window, sheet, and interactive popover owns one focus scope; AppKit still calculates the key-view loop, while explicit requests only establish initial or dynamically inserted focus once. Native proxies are used only for controls proven absent from the key-view loop.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager.

---

## Constraints

- Work in the current checkout. Do not create a worktree.
- Build and package locally. Do not build on a VPS.
- Follow red-green TDD for every production change.
- Preserve normal Tab input in terminal and code editors; Control-Tab and Control-Shift-Tab leave those editors.
- Do not change the user's global macOS keyboard-navigation setting.
- Do not commit test files unless the user explicitly requests a commit.

### Task 1: Reproduce the real sheet lifecycle

**Files:**
- Modify: `Tests/AuvGitTests/NativeFocusBridgeTests.swift`
- Inspect: `Sources/AuvGit/DialogAppearance.swift`
- Inspect: `Sources/AuvGit/RepositoryTools.swift`

1. Add a fixture that presents `CreateRepositorySheet` through the real `.auvGitSheet` path from a parent window.
2. Use a real Tab key event with the sheet window initially owning first responder.
3. Assert that the first Tab moves into the expected control and that Tab/Shift-Tab complete a stable loop.
4. Run `swift test --build-system native --filter NativeFocusBridgeTests` and confirm the new test fails for the installed behavior.

### Task 2: Repair initial focus and scope lifecycle

**Files:**
- Modify: `Sources/AuvGit/NativeFocusBridge.swift`
- Modify if required: `Sources/AuvGit/DialogAppearance.swift`
- Test: `Tests/AuvGitTests/NativeFocusBridgeTests.swift`

1. Apply initial focus only after a registered target is visible and belongs to the presentation's actual window.
2. Handle a Tab event when the presentation window itself is first responder so the first press enters the key-view loop.
3. Recalculate after hierarchy, enabled-state, hidden-state, or dynamic-control changes without repeatedly stealing focus.
4. Keep parent-window requests suspended while a child sheet is attached, then resume without rebinding scopes.
5. Run the focused tests and confirm green.

### Task 3: Isolate interactive popovers

**Files:**
- Modify: `Sources/AuvGit/NativeFocusBridge.swift`
- Modify: interactive popover owners found by `rg -n '\.popover' Sources/AuvGit`
- Modify: `Sources/AuvGit/ComparisonSearchField.swift`
- Test: `Tests/AuvGitTests/NativeFocusBridgeTests.swift`

1. Add a failing test proving an interactive popover does not rebind its parent window's coordinator.
2. Give interactive popovers independent focus roots and initial-focus requests.
3. Move comparison search away from its one-shot asynchronous focus flag to the shared request mechanism.
4. Verify closing the popover restores normal parent-window traversal.

### Task 4: Audit dialog controls

**Files:**
- Inspect and modify only when needed: every `.auvGitSheet`, `auvGitAlert`, custom modal panel, and Settings surface under `Sources/AuvGit`
- Test: `Tests/AuvGitTests/NativeFocusBridgeTests.swift`

1. Exercise representative forms containing text fields, secure fields, buttons, toggles, pickers, tables, and dynamically disabled controls.
2. Confirm Cancel/Escape and default/Return behavior remain intact and disabled controls are skipped.
3. Add `KeyViewProxy` or a focused native wrapper only where a real control is unreachable.
4. Cover clone/authentication, alerts, workspace commit/search, tags, network operations, reset/rebase, repository context, and Settings.

### Task 5: Regression and installed-app verification

**Files:**
- Use: `scripts/build-app.sh`
- Output: `.artifacts/AuvGit.app`
- Output: `.artifacts/AuvGit.dmg`

1. Run focused focus and shortcut tests.
2. Run localization validation and the full test suite with `--build-system native`.
3. Run `git diff --check` and inspect the source diff for unrelated changes.
4. Build locally with `scripts/build-app.sh`, create and verify the DMG, and install `/Applications/AuvGit.app`.
5. Launch the installed app and manually verify first Tab, forward/backward loops, dynamic HTTPS fields, representative alerts/popovers, and editor Control-Tab behavior.
6. Confirm the installed executable matches the built executable and remains running.
