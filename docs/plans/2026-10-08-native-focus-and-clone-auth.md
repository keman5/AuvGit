# Native Focus and Secure Clone Authentication Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Finish the existing HTTPS username/PAT clone flow securely and make keyboard focus work throughout RayGit using native macOS navigation.

**Architecture:** Install one shared AppKit focus bridge at each SwiftUI window/sheet root. Let AppKit calculate the key-view loop; use declarative initial/dynamic focus requests and a SwiftUI key-view proxy instead of manually linking controls on every page. Keep clone credentials out of process arguments and logs, using a temporary scoped Git credential helper and the existing secure storage integration.

**Tech Stack:** Swift, SwiftUI, AppKit, Swift Package Manager, XCTest, Git credential protocol, macOS Keychain.

---

## Execution constraints and discovery

- Implement with `gpt-6.1-sol` after this Astra plan; use the current checkout, no worktree and no commits.
- Preserve all existing uncommitted work. Run `git status --short` and inspect the current diff before editing.
- Exact existing owner filenames were not available to the planning writer. Resolve the owner checklist below once; record their actual paths in this document before implementation. Do not create duplicate implementations to satisfy a guessed filename.
- Discovery commands: `rg --files Sources Tests scripts`; `rg -n 'StableTextField|ShortcutRecorder|Clone|credential|NSHosting|WindowGroup|\.sheet|\.window' Sources Tests`; `cat Package.swift`.
- Owner checklist: existing `StableTextField` implementation; clone sheet; clone service and credential helper; `ShortcutRecorder`; app window and every sheet root; terminal/code-editor wrappers; localization catalog; packaging/install script.
- New exact paths: `Sources/RayGit/NativeFocusBridge.swift`, `Tests/RayGitTests/NativeFocusBridgeTests.swift`, `Tests/RayGitTests/CloneCredentialSecurityTests.swift`.
- The test commands below assume the existing test target is `RayGitTests`; verify in `Package.swift` and adjust the commands if its name differs.
- Use @superpowers:test-driven-development and @superpowers:verification-before-completion. User instructions override the skill's worktree/commit defaults. Test changes remain local and must not be committed without an explicit request.

## Task 1: Lock down credential-bearing URL validation

### Resolved owners and execution notes

- Native fields: `Sources/RayGit/HistorySearchField.swift`; clone sheet: `Sources/RayGit/RepositoryTools.swift`; authentication classification: `Sources/RayGit/CloneAuthentication.swift`.
- Credential lease and clone lifetime: `Sources/GitCore/RepositoryManagement.swift`; command logging and errors: `Sources/GitCore/GitCommandLog.swift`, `Sources/GitCore/GitProcess.swift`.
- Shared sheet/alert roots: `Sources/RayGit/DialogAppearance.swift`. Main/Settings scene roots: `Sources/RayGit/RayGitApp.swift`. Independent hosting roots: `MainWindow.swift`, `WorkspaceFooterSplit.swift`, `LogWindow.swift`, `CommitDetailWindow.swift`, `CompareWindow.swift`.
- Recorder: `Sources/RayGit/ShortcutRecorder.swift`. Editors: `ComparisonEditor.swift`, `CommitMessageEditor.swift`, `DiffPane.swift`; terminal: `TerminalSession.swift` and existing `TerminalPane.swift` monitor.
- Four locale catalogs: `Sources/RayGitLocalization/Resources/{en,zh-Hans,zh-Hant,ja}.lproj/Workflow.strings`; checker: `python3 scripts/check-localizations.py`; package script: `scripts/build-app.sh` (release packaging/install reserved for the reviewing main agent).
- This Xcode installation's default SwiftPM build system cannot compile SwiftTerm Metal resources. Focused tests use `swift test --build-system native --filter ...` without changing package configuration.
- SwiftTerm's `keyDown` is not open. Its Control-Tab handling reuses the existing window-scoped `TerminalShortcutMonitor` and only handles the active terminal; no new global event monitor is installed.

**Files:** Existing clone service/helper owners resolved above; `Tests/RayGitTests/CloneCredentialSecurityTests.swift`.

1. Add failing table-driven tests for credential-supplied clone URLs: reject userinfo (including username-only or encoded forms), query, fragment, non-HTTPS schemes, and missing host. Cover both present-but-empty and nonempty query/fragment. Accept HTTPS host/path with optional explicit port.
2. Red: `swift test --filter CloneCredentialSecurityTests`; confirm failures come from missing rejection behavior, not compilation/setup errors.
3. Validate parsed URL components before invoking Git whenever credentials are supplied. Require HTTPS, nonempty host, `user == nil`, `password == nil`, `query == nil`, and `fragment == nil`. Keep unauthenticated SSH/local clone paths working as before. Never include the rejected URL or credential values in error messages.
4. Green: `swift test --filter CloneCredentialSecurityTests`.

## Task 2: Exercise the real credential helper and its lifetime

**Files:** Existing clone service/helper and secure-storage owners; `Tests/RayGitTests/CloneCredentialSecurityTests.swift`.

1. Add a process-level test that launches the actual generated helper executable with `get`, writes Git credential input ending in a blank line, and checks the output protocol. A mocked Swift helper alone is insufficient.
2. Cover matching host/default port, explicit nondefault port, mismatched port, unrelated host, deceptive suffix host, malformed input, and a `store` invocation. Normalize host casing; treat omitted HTTPS port and explicit 443 consistently without allowing arbitrary ports.
3. Test real invocation order: `get` supplies a credential without saving; Git's subsequent `store` saves only the matching credential when the user selected persistence. `erase` and malformed/unmatched requests must not accidentally save. Never echo a supplied password in diagnostics.
4. Red: `swift test --filter CloneCredentialSecurityTests`.
5. Scope helper output and storage to the validated protocol/host/port. Disable unintended inherited helpers for this explicit credential flow using nonsecret Git configuration. Keep username/PAT in protected temporary data or private process input, never in executable arguments or the remote URL.
6. Add failure/cancellation/success tests proving temporary files and directories are removed, permissions restrict access, and captured argv/log/error text contain no PAT. Test cleanup after launch failure as well as Git failure; make cleanup unconditional with `defer` at the owner of the temporary material.
7. Green: `swift test --filter CloneCredentialSecurityTests`.
8. Document the actual guarantee in code and relevant UI/help text: Git may call `store` after authentication succeeds even when later checkout/clone work fails. Do not claim persistence waits for the entire clone to succeed.

## Task 3: Build the native focus bridge with hosted-view tests

**Files:** Create `Sources/RayGit/NativeFocusBridge.swift`; create `Tests/RayGitTests/NativeFocusBridgeTests.swift`.

1. Add main-thread tests using a real `NSWindow` containing `NSHostingView`, real text fields, a button, and a toggle. Retain the window and hosting view for each test, run layout, and drain queued main-thread work before checking `firstResponder`.
2. Specify behavior: Tab advances, Shift-Tab reverses, disabled/hidden controls are skipped, sheet boundaries are respected, and newly inserted controls become reachable after recalculation. Check field-editor ownership when the responder is an `NSTextView` rather than comparing directly with its `NSTextField`.
3. Add tests that initial focus is applied once per presentation, normal SwiftUI updates do not steal focus, and a new dynamic focus-request token moves focus exactly once.
4. Red: `swift test --filter NativeFocusBridgeTests`.
5. Implement a root bridge/coordinator that sets `window.autorecalculatesKeyViewLoop = true`, requests `window.recalculateKeyViewLoop()` after relevant hierarchy/layout changes, and delegates navigation to `window.selectNextKeyView(nil)` / `window.selectPreviousKeyView(nil)`.
6. Provide declarative focus target identifiers and request tokens. Defer focus until the target belongs to the visible window; use `makeFirstResponder` once, then acknowledge the request. Cancel pending work when dismantled. Initial focus and explicit later requests are separate state.
7. Include `KeyViewProxy`, an `NSViewRepresentable` backed by an AppKit view that exposes focusability and forwards activation to the SwiftUI control. Give proxies meaningful accessibility labels/actions, preserve native focus indication, and avoid duplicate key stops where SwiftUI already supplies one.
8. Keep the bridge scoped to its window; do not install a global event monitor or hand-assign `nextKeyView` for each page. Recalculate only when required and avoid layout/update feedback loops.
9. Green: `swift test --filter NativeFocusBridgeTests`. Run in an available macOS GUI session; a missing GUI session is a reported test limitation, never a passing result.

## Task 4: Integrate text fields and clone-sheet focus

**Files:** Existing `StableTextField` and clone-sheet owners; `Tests/RayGitTests/NativeFocusBridgeTests.swift`.

1. Add hosted-view tests for source/destination initial focus, the username control inserted when authentication becomes necessary, and repeated state updates while typing.
2. Red: `swift test --filter NativeFocusBridgeTests`.
3. Replace unconditional focus in `StableTextField` updates with the bridge's target/request API. Preserve selection, field-editor ownership, marked text/IME composition, and the current editing callback behavior.
4. On clone-sheet presentation, focus source if it requires input; if source is prefilled, focus destination when that is the next required input. Apply this once per presentation. When an explicit authentication transition reveals username/PAT inputs, issue a fresh username focus request after insertion.
5. Ensure username, secure PAT, save-credential option, destination picker, Cancel, and Clone are reachable in natural native traversal order. Keep secure text entry and the existing pending/error state behavior.
6. Green: `swift test --filter NativeFocusBridgeTests` and `swift test --filter CloneCredentialSecurityTests`.

## Task 5: Install at all roots and preserve specialized key handling

**Files:** All existing window/sheet roots and terminal/code-editor wrappers; existing `ShortcutRecorder`; `Sources/RayGit/NativeFocusBridge.swift`; `Tests/RayGitTests/NativeFocusBridgeTests.swift`.

1. Record every root found by `rg -n 'WindowGroup|Window\(|\.sheet|NSHostingView|NSHostingController' Sources/RayGit`; include preferences, alerts/forms with custom content, repository dialogs, and secondary windows where present.
2. Add hosted tests for two independent windows, sheet presentation/dismissal, recorder browsing versus recording, and editor escape navigation.
3. Red: `swift test --filter NativeFocusBridgeTests`.
4. Install the shared root modifier once at each actual root. Add proxies only where hosted tests/manual checks show native SwiftUI controls do not participate. No per-page linked key-view lists.
5. Outside active shortcut recording, Tab/Shift-Tab browse normally. During explicitly activated recording, preserve shortcut capture semantics and the existing cancel/finish keys; after recording, restore ordinary traversal. Avoid swallowing Tab merely because the recorder has focus.
6. Ordinary controls use Tab/Shift-Tab. Terminal and code-editor content retain Tab for their own input; Control-Tab exits forward and Control-Shift-Tab exits backward through the native loop. Limit handling to the active editor and avoid treating unrelated modifier combinations as traversal.
7. Green: `swift test --filter NativeFocusBridgeTests`.

## Task 6: Localization and regression verification

**Files:** Existing localization catalog(s), clone-sheet help/error strings, and any keyboard-help documentation already present.

1. Localize new credential errors, username/PAT labels, persistence wording, and editor navigation hints using the project's existing localization mechanism. Preserve terminology across every supported locale and do not embed secrets in interpolated strings.
2. Focused verification: `swift test --filter CloneCredentialSecurityTests`; `swift test --filter NativeFocusBridgeTests`.
3. Full verification: `swift test`; `git diff --check`.
4. Review `git diff` for accidental credential output, unrelated modifications, and focus-stealing updates. Inspect helper launch arguments and error formatting explicitly.
5. Manually keyboard-traverse all recorded roots with macOS keyboard navigation enabled. Repeat critical cases with that setting disabled and document behavior; do not modify the user's global setting without permission.
6. Exercise clone authentication failure, retry, cancellation, optional persistence, and post-auth clone failure with a controlled local HTTPS Git fixture or explicitly authorized test remote. Never print live credentials. Confirm Keychain and cleanup behavior separately from clone completion.

## Task 7: Release build, DMG, and installed-app verification

**Files:** Use existing packaging/install scripts discovered in Task 0; do not invent a parallel release pipeline.

1. Build locally: `swift build -c release`. Record the actual exit status and product path.
2. Read the existing packaging script and record its exact invocation here before running it. Produce the repository-standard DMG using that script; verify the DMG exists and inspect its mounted app bundle/version with `hdiutil attach -readonly <verified-dmg-path>`.
3. Resolve the existing installed RayGit target before replacement. Install the verified release app at that known target, following existing signing/bundle rules and preserving app data. Never substitute a debug or older bundle.
4. Launch the installed app, confirm the running executable points to that installation, and repeat clone-sheet focus, normal Tab/Shift-Tab, recorder behavior, and editor Control-Tab checks. Confirm sustained launch without a crash.
5. Report separately: focused/full test results, release build, DMG path, installed target, and manual verification. State any unverified remote-auth scenario plainly. Leave all changes uncommitted.

## Completion evidence

- Native focus implementation has real hosted AppKit tests and one-shot/dynamic focus semantics.
- Every window/sheet root is accounted for; editors and the shortcut recorder preserve their specialized behavior.
- Real helper protocol tests cover get/store order, host/port scope, rejected credential URLs, secret handling, and cleanup.
- Localization, full tests, release build, DMG creation, and installed-app checks are individually evidenced.
- No worktree, VPS build, commit, or unrelated changes were introduced.
