# List range selection

Implement the requested macOS selection behavior in the existing checkout, without a worktree or commits.

- Preserve native Shift range selection and Command toggling in workspace file/tree lists.
- Enable multiple selection in branch/stash and compact history tables. Persist stable selected IDs through reloads; reset on repository/navigation changes.
- Use set bindings in history, reference, changed-file, tag, blame, reflog, ignored-file and repository lists, retaining a primary item for detail previews.
- Keep single-target operations scoped to one item; support copying the selected rows in display order.
- Add regressions for stash selection, refresh, scope changes and selection bindings. Run unshown component tests through scripts/build.sh --test-list-selection.
- Build through scripts/build.sh, increment version, replace the installed app and remove generated .artifacts. Keep verification in the background.
