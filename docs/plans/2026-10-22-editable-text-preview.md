# Editable workspace text preview

Text selected in either workspace file view opens a native editor window with
Monokai syntax colors. Other resources retain the system Quick Look panel.

- Space opens/toggles the preview from the file list. Before entering editing,
  Space also closes the text window. Clicking the contents or pressing Tab enters
  editing; Space then inserts text. Escape requests close in either state.
- Save button and Command-S save the original file, preserving its encoding,
  newline convention, and POSIX permissions. No Git staging occurs.
- Modified drafts require save/discard/cancel on close and application quit.
  Changes made outside the preview prevent overwriting the file.
- Lexical highlighting reuses GitCore and runs after a debounce off the main
  thread. Attribute updates preserve the native editor's text and undo history.
- Preserve existing workspace changes. Build, install, and clean through
  scripts/build.sh; verify file views, text edits, keyboard routing, and media.

Verification: targeted workspace tests and installed-app interaction checks.
