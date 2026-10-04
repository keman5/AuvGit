# Public 8pt main-window frame

RayGit uses a public borderless/resizable NSWindow by default. The transparent
window and owned full-window layer create an eight-point outer alpha boundary.
No NSThemeFrame, KVC, private selector or private toolbar view is used.

## Native fallback

Set application-domain UserDefaults `window.frameMode` to `native`, then restart,
or pass `--window-frame native`. This keeps the system frame and existing native
NSToolbar customization. Set `window.frameMode` to `borderless` or remove it to
return to the default shell. The old `window.framePrototype` preference and
`--window-frame-prototype` argument remain accepted for compatibility.

## Window behavior and persistence

The shell has public standard traffic-light buttons, public fullscreen and
window dragging actions, double-click zoom, and public frame-based eight-edge
resize. It hosts the same MainWindow/store. Closing it closes the hidden original
window; reopening creates a new independent shell and controller. Repository
changes explicitly update its NSWindow title.

Normal position and size persist in `window.shellFrame.v1`. Fullscreen transitions
do not overwrite the saved normal frame. A saved frame remains on a connected
secondary display, including displays with negative coordinates. If its titlebar
is no longer reachable on any display, restoration moves it to the primary
visible screen. Minimum size is at least 1000 by 714 points (680 content plus
34 titlebar).

## Toolbar

The shell owns visible SwiftUI controls and a public NSToolbar configuration
model. A four-language configuration sheet supports adding/removing commands,
ordering them, repeatable spaces/flexible spaces, icon-only/icon-and-text modes,
and restoring defaults. Initial supported order and display mode are seeded
from the native toolbar. Shell changes persist in `window.borderlessToolbar.v1`,
preserving original native customization preferences. The toolbar scrolls
horizontally when configured commands exceed window width.

Stage/Unstage/Discard and network operations share native toolbar actions. Apply
has a primary latest-stash action and a menu of actual stash references. Existing
app shortcuts operate on the same RepositoryStore.

## Validation boundary

QA verified the visible eight-point shell, entering/exiting fullscreen, Open
panel and shortcut, title updates, configuration/space/text controls, and reopening
after closing. Computer-use coordinate dragging reported `noWindowsAvailable` for
the borderless window, so physical title dragging and all eight resize handles
remain unverified at runtime. Pure geometry regressions cover edge/corner hit
regions, opposite-edge anchoring, minimum sizes, negative display coordinates and
restoration after a display disconnect. These tests do not replace physical input
acceptance. Public `screencapture -l WINDOW_ID -o output.png` can capture final
window alpha; an internal view bitmap alone does not establish the outer boundary.
