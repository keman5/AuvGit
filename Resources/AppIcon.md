# AuvGit application icon

用户于 2026-10-04 选择本轮 `round-02` 的 **01 · 极简分支**。使用已有图片，不重新生成或重绘。

Selected source: `Resources/IconConcepts/round-02/auvgit-01.png`.
Original generated source: `/Users/kevin/.codex/generated_images/01a0ff36-aba3-7043-8559-be551508e9c3/exec-db955789-ffd3-486f-96ae-139ff994e008.png`.
Generation mode: built-in imagegen, with a transparent exterior as specified in the original prompt.

Shared prompt:

> Use case: logo-brand. Create ONE entirely new standalone production-quality macOS app icon for AuvGit, a Git GUI focused on code comparison and history. Square canvas. Front-facing centered macOS rounded-square icon tile filling about 84% of the canvas, consistent generous transparent margin. The tile itself is opaque. Real transparent exterior, clean alpha edges, no backdrop, no mockup scene. One icon only, no grid, no variant sheet, no labels, no app name, no watermark. Distinct original design, not a copy of any existing app icon. Keep the central symbol bold and recognizable at Dock sizes. Art direction:

Selected 01 direction:

> Minimal flat graphic identity: a single bold white branching path with three circular commit nodes, arranged as an asymmetrical elegant Y, on a saturated coral-red rounded square. Precise generous geometry, subtle dimensional tile edge only, virtually flat clean symbol, incredibly legible at 32 pixels.

`AppIcon.png` preserves the selected red branch artwork while removing disconnected and low-alpha pixels outside the icon body. The cleanup keeps the original pixels inside the retained body mask and clears exterior RGB and alpha together, preventing Finder thumbnails from rendering a gray background or colored fringe.

macOS `sips` generates the 10 standard 16–1024 pixel iconset representations from the cleaned master, preserving alpha; `iconutil` creates `AppIcon.icns`. `scripts/build.sh` embeds it and sets `CFBundleIconFile` to `AppIcon`.

macOS 26 and later can shrink a legacy `.icns` onto a gray compatibility tile in Finder, even when its exterior pixels are transparent. `AppIcon.icon` supplies the native icon instead: `Assets/artwork.png` is an unchanged copy of the existing 1024-pixel iconset image, enlarged by 1.18 within the native canvas to remove the legacy transparent margin. A matching coral fill covers the exterior and the system supplies the final rounded mask. The original red tile and white branch artwork are retained.

The build script requires Xcode's `actool`, compiles `AppIcon.icon` into `Assets.car`, and declares `CFBundleIconName=AppIcon`. It keeps the existing `.icns` for older macOS releases. When updating the master, also refresh `AppIcon.icon/Assets/artwork.png` from `AppIcon.iconset/icon_512x512@2x.png`.
