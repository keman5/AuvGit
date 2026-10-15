# Conflict resolver

AuvGit's text comparison editor uses the SmartGit resolver workflow as its interaction reference: inspect the two sides, choose content for the current conflict, and edit the merge result before saving and marking the file resolved. This describes the implemented workflow, not a claim of complete SmartGit feature parity.

## Layout and versions

For an unmerged file, the comparison editor offers Ours + Result, All three, and Result + Theirs layouts. Ours is Git index stage 2 and Theirs is stage 3. Show merge base replaces the left source pane with stage 1. The merge result remains editable when the file's encoding and size permit editing.

Ours and Theirs describe Git's stages. In a rebase, those stage roles can differ from the everyday meaning of “my branch” and “their branch”; use the displayed version contents to decide.

Two- and three-pane editors align corresponding logical bands by adding display-only vertical space. Real text, newline bytes, and source line numbers remain unchanged; virtual gaps have no invented line numbers. A conflict's source segment begins at the same vertical position as the result's opening marker, rather than at its matching text inside the markers. Shorter segments receive space after their contents so the unchanged context following the conflict starts at the same height in every pane. Wrapped line heights and pane resizing trigger recalculation.

The workspace preview uses the same colored Ours / Result / Theirs stage-aware text surface for conflicts. All three preview panes are read-only and provide no acceptance controls. Open the independent comparison window to edit or accept conflict contents.

## Resolve one block

The conflict toolbar displays the current block number and result line range. Previous/next buttons cycle through unresolved blocks; selecting inside a result block selects that block for the toolbar. The result gutter provides arrows to accept Ours or Theirs at that block.

The toolbar can accept Ours, Theirs, Ours followed by Theirs, or Theirs followed by Ours. Use Base is available when the block includes a diff3/zdiff3 base section. These actions replace only the current conflict block, including its marker lines. Content outside the block remains intact. Each choice is an editor undo operation; the result can also be edited manually.

The parser supports standard and extended-width Git conflict markers, optional base sections, Unicode text, CRLF line endings, and a final marker without a trailing newline. It uses UTF-16 ranges to match AppKit editor positions.

Incomplete markers display a repair message and disable block choices until the result is repaired. Save & Mark Resolved rejects remaining conflict markers, including extended-width and CRLF markers.

## Save and finish

Block choices update the in-memory draft. Save writes the draft; Save & Mark Resolved saves the result and stages the file through Git's resolution flow. Existing file-change checks and marker checks still apply. Choosing a side does not itself stage the file.

The existing Use Version menu replaces the entire draft with a selected version; its scope differs from the toolbar's current-block choices. Auto Merge remains available for a new automatic merge attempt.

## Acceptance evidence

On 2026-10-04, the installed native application verified the shared read-only workspace conflict preview and independent resolver alignment using `/tmp/auvgit-visual-polish-20261004`: Theirs line 14 aligned with the result's opening conflict marker at line 20, empty Ours content left a virtual gap, and following context aligned. Accepting Theirs for the second block reduced three conflicts to two; Cmd-Z restored three and disabled Save again. Inserting a newline and undoing it restored the draft.

The alignment fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/auvgit-alignment-_tmmynsf` verified wrapped workspace two-pane `anchor C` at source line 9/result line 12. In the ordinary three-pane editor, HEAD/result/index lines 1/3/2, `anchor B` 6/9/6, the Unicode line 8/11/9, and `anchor C` 9/12/10 aligned. After two divider adjustments narrowed the result pane to 259.5pt, all three panes reached the bottom with scrollbar value 1 and `anchor C` remained aligned.

Final disk checks confirmed SHA256 hashes for all three alignment-fixture files matched the original manifest. The original resolver fixture's `resolver-demo.txt` retained SHA1 `c923f59cbe92dfad1567c93214cf5d0cbd925766`. Automatic wrapping was restored to off and the panes returned to approximately equal widths.

The final workspace preview also reuses the core pairing and equalizes row heights with wrapping either on or off. After rebuilding and verifying the installed executable, native GUI checks of `ThreePane.txt` confirmed source/result lines 2/3, `anchor B` 6/9, Unicode 9/11, and `anchor C` 10/12 matched pixel heights without wrapping. Addition, deletion, modification, and character colors were correct. With wrapping enabled, both panes reached scrollbar value 1 and `anchor C` remained aligned; wrapping was then switched off.

Latest targeted native tests passed all 23 `ComparisonAlignmentTests`, `TextLineDiffTests`, and `ConflictDraftTests` (`/tmp/auvgit-alignment-final-tests.log`); the earlier full-suite run passed 112 tests (`/tmp/auvgit-alignment-tests.log`). The final local Release build passed (`/tmp/auvgit-alignment-final-build.log`), four-language localization checks passed for 22 tables and 879 keys, and the installed `/Applications/AuvGit.app` passed signature verification and executable comparison with the built artifact. This verifies the exercised fixtures and geometry; all languages, themes, and large-file performance have not received comprehensive GUI acceptance. The following evidence records the earlier resolver acceptance run.

On 2026-10-03, the complete native test suite passed: 108 tests, zero failures (`/tmp/auvgit-resolver-tests.log`). The local Release build passed (`/tmp/auvgit-resolver-release.log`), as did deep strict application signature verification, four-language localization checks (22 tables, 878 keys), and `git diff --check`.

Native application verification used the isolated three-block conflict fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/auvgit-resolver-j8g5ibze`. Accepting Theirs for the second block preserved the other blocks; Cmd-Z restored the complete original draft and Shift-Cmd-Z reapplied the choice. Ours followed by Theirs produced the expected four lines in the third block. Base selection and undo, followed by Theirs then Ours, produced the expected first-block contents and ordering. Switching to Ours + Result retained the draft, and the first block's gutter arrow accepted Ours. An incomplete marker displayed the repair message, disabled choices, and was removable by undo.

Before saving, the fixture still had three marker blocks on disk and three index stage entries. Save & Mark Resolved completed successfully; independent Git checks confirmed the index equaled the worktree, no unmerged entries remained, and the final contents matched Ours for block one, Theirs for block two, and Ours then Theirs for block three.

Detailed evidence is recorded in `VALIDATION.md`. The verified artifact is `.artifacts/AuvGit.app`; this run did not update the installed `/Applications/AuvGit.app` copy. The new icon is included in the verified artifact's resources; its source and packaging are documented in `Resources/AppIcon.md`.

An English native screenshot at approximately 1052pt window width confirmed all resolver toolbar text remained readable. Japanese text was confirmed readable at the default window width; Japanese narrow-window layout remains unverified. After the user switched the UI back to Simplified Chinese, language and window changes stopped to respect that interaction.

Complete visual similarity, all source/result scroll alignment cases, and workflows in the user's real repositories remain unverified. This acceptance does not establish complete SmartGit parity: a layout with the merge result below the source panes is not yet implemented.
