# Conflict resolver

RayGit's text comparison editor uses the SmartGit resolver workflow as its interaction reference: inspect the two sides, choose content for the current conflict, and edit the merge result before saving and marking the file resolved. This describes the implemented workflow, not a claim of complete SmartGit feature parity.

## Layout and versions

For an unmerged file, the comparison editor offers Ours + Result, All three, and Result + Theirs layouts. Ours is Git index stage 2 and Theirs is stage 3. Show merge base replaces the left source pane with stage 1. The merge result remains editable when the file's encoding and size permit editing.

Ours and Theirs describe Git's stages. In a rebase, those stage roles can differ from the everyday meaning of “my branch” and “their branch”; use the displayed version contents to decide.

## Resolve one block

The conflict toolbar displays the current block number and result line range. Previous/next buttons cycle through unresolved blocks; selecting inside a result block selects that block for the toolbar. The result gutter provides arrows to accept Ours or Theirs at that block.

The toolbar can accept Ours, Theirs, Ours followed by Theirs, or Theirs followed by Ours. Use Base is available when the block includes a diff3/zdiff3 base section. These actions replace only the current conflict block, including its marker lines. Content outside the block remains intact. Each choice is an editor undo operation; the result can also be edited manually.

The parser supports standard and extended-width Git conflict markers, optional base sections, Unicode text, CRLF line endings, and a final marker without a trailing newline. It uses UTF-16 ranges to match AppKit editor positions.

Incomplete markers display a repair message and disable block choices until the result is repaired. Save & Mark Resolved rejects remaining conflict markers, including extended-width and CRLF markers.

## Save and finish

Block choices update the in-memory draft. Save writes the draft; Save & Mark Resolved saves the result and stages the file through Git's resolution flow. Existing file-change checks and marker checks still apply. Choosing a side does not itself stage the file.

The existing Use Version menu replaces the entire draft with a selected version; its scope differs from the toolbar's current-block choices. Auto Merge remains available for a new automatic merge attempt.

## Acceptance evidence

On 2026-10-03, the complete native test suite passed: 108 tests, zero failures (`/tmp/raygit-resolver-tests.log`). The local Release build passed (`/tmp/raygit-resolver-release.log`), as did deep strict application signature verification, four-language localization checks (22 tables, 878 keys), and `git diff --check`.

Native application verification used the isolated three-block conflict fixture `/var/folders/p9/706zy1rn35l9bjl5jq98b3m40000gn/T/raygit-resolver-j8g5ibze`. Accepting Theirs for the second block preserved the other blocks; Cmd-Z restored the complete original draft and Shift-Cmd-Z reapplied the choice. Ours followed by Theirs produced the expected four lines in the third block. Base selection and undo, followed by Theirs then Ours, produced the expected first-block contents and ordering. Switching to Ours + Result retained the draft, and the first block's gutter arrow accepted Ours. An incomplete marker displayed the repair message, disabled choices, and was removable by undo.

Before saving, the fixture still had three marker blocks on disk and three index stage entries. Save & Mark Resolved completed successfully; independent Git checks confirmed the index equaled the worktree, no unmerged entries remained, and the final contents matched Ours for block one, Theirs for block two, and Ours then Theirs for block three.

Detailed evidence is recorded in `VALIDATION.md`. The verified artifact is `.artifacts/RayGit.app`; this run did not update the installed `/Applications/RayGit.app` copy. The new icon is included in the verified artifact's resources; its source and packaging are documented in `Resources/AppIcon.md`.

An English native screenshot at approximately 1052pt window width confirmed all resolver toolbar text remained readable. Japanese text was confirmed readable at the default window width; Japanese narrow-window layout remains unverified. After the user switched the UI back to Simplified Chinese, language and window changes stopped to respect that interaction.

Complete visual similarity, all source/result scroll alignment cases, and workflows in the user's real repositories remain unverified. This acceptance does not establish complete SmartGit parity: a layout with the merge result below the source panes is not yet implemented.
