# RayGit application icon

用户于 2026-10-04 选择本轮 `round-02` 的 **01 · 极简分支**。使用已有图片，不重新生成或重绘。

Selected source: `Resources/IconConcepts/round-02/raygit-01.png`.
Original generated source: `/Users/kevin/.codex/generated_images/01a0ff36-aba3-7043-8559-be551508e9c3/exec-db955789-ffd3-486f-96ae-139ff994e008.png`.
Generation mode: built-in imagegen, with a transparent exterior as specified in the original prompt.

Shared prompt:

> Use case: logo-brand. Create ONE entirely new standalone production-quality macOS app icon for RayGit, a Git GUI focused on code comparison and history. Square canvas. Front-facing centered macOS rounded-square icon tile filling about 84% of the canvas, consistent generous transparent margin. The tile itself is opaque. Real transparent exterior, clean alpha edges, no backdrop, no mockup scene. One icon only, no grid, no variant sheet, no labels, no app name, no watermark. Distinct original design, not a copy of any existing app icon. Keep the central symbol bold and recognizable at Dock sizes. Art direction:

Selected 01 direction:

> Minimal flat graphic identity: a single bold white branching path with three circular commit nodes, arranged as an asymmetrical elegant Y, on a saturated coral-red rounded square. Precise generous geometry, subtle dimensional tile edge only, virtually flat clean symbol, incredibly legible at 32 pixels.

`AppIcon.png` is a byte-identical copy of the selected source. macOS `sips` generates the 10 standard 16–1024 pixel iconset representations, preserving alpha; `iconutil` creates `AppIcon.icns`. `scripts/build-app.sh` embeds it and sets `CFBundleIconFile` to `AppIcon`.
