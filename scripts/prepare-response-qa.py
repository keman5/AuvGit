#!/usr/bin/env python3
"""Package the built app with disposable repositories and isolated preferences."""
import json
import base64
import plistlib
import subprocess
import tempfile
from pathlib import Path

project = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="raygit-response-qa-"))

def git(path, *args):
    subprocess.run(["/usr/bin/git", "-C", str(path), *args], check=True, capture_output=True)

seed = root / "source"
seed.mkdir()
git(seed, "init", "-b", "main")
git(seed, "config", "user.name", "Response Fixture")
git(seed, "config", "user.email", "fixture@example.invalid")
git(seed, "config", "commit.gpgsign", "false")
for index in range(80):
    (seed / f"file-{index:03}.txt").write_text("original\n")
git(seed, "add", ".")
git(seed, "commit", "-m", "Response fixture")
git(seed, "branch", "feature/ui/icons")
git(seed, "branch", "feature/ui/layout")
git(seed, "branch", "release/preview")
paths = []
for name in ["Empty", "Changed"] + [f"Project-{i:02}" for i in range(16)]:
    target = root / name
    git(root, "clone", "--quiet", str(seed), str(target))
    paths.append(str(target))
changed = root / "Changed"
for index in range(80):
    (changed / f"file-{index:03}.txt").write_text("staged\n")
git(changed, "add", ".")
for index in range(80):
    (changed / f"file-{index:03}.txt").write_text("worktree\n")
(changed / "untracked.txt").write_text("disposable fixture\n")
preview = root / "PreviewHTML"
preview.mkdir()
git(preview, "init", "-b", "main")
git(preview, "config", "user.name", "Preview Fixture")
git(preview, "config", "user.email", "fixture@example.invalid")
git(preview, "config", "commit.gpgsign", "false")
git(preview, "commit", "--allow-empty", "-m", "HTML preview fixture")
longest = [12550, 8723, 6365, 2763, 2309, 1521, 1311, 1309, 935, 925]
markup = '<span class="feature" data-index="123">Native preview</span>'
lines = []
for index in range(77):
    length = longest[index] if index < len(longest) else 260
    prefix, suffix = f'<section id="row-{index}">', '</section>'
    content_length = length - len(prefix) - len(suffix)
    lines.append(prefix + (markup * (content_length // len(markup) + 1))[:content_length] + suffix)
html = '\n'.join(lines) + '\n'
(preview / "index.html").write_text(html)
(preview / "preview.png").write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII="))
paths.insert(2, str(preview))
app = root / "RayGit Response QA.app"
subprocess.run(["ditto", str(project / ".artifacts/RayGit.app"), str(app)], check=True)
info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
bundle_id = "dev.raygit.response-qa-" + root.name.rsplit("-", 1)[-1]
info.update(CFBundleIdentifier=bundle_id, CFBundleName="RayGit Response QA", CFBundleDisplayName="RayGit Response QA")
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
session = dict(schemaVersion=1, openRepositories=paths, activeRepository=str(changed), repositories={})
preferences = {
    "appLanguage": "zh-Hans", "window.frameMode": "borderless",
    "preferences.backgroundRefresh": True, "editor.wrapLines": True,
    "recentRepositories": paths, "repositorySession.v1": json.dumps(session).encode(),
    "repository.cloneParent.v1": str(root),
}
preference_path = Path.home() / "Library/Preferences" / (bundle_id + ".plist")
preference_path.write_bytes(plistlib.dumps(preferences))
status = subprocess.run(["/usr/bin/git", "-C", str(changed), "status", "--porcelain"], check=True, capture_output=True).stdout.decode().splitlines()
assert sum(line.startswith("MM ") for line in status) == 80
assert any(line == "?? untracked.txt" for line in status)
assert (preview / "index.html").stat().st_size > 50_000
assert len(html.splitlines()) == 77 and max(map(len, html.splitlines())) == 12550
assert app.joinpath("Contents/MacOS/RayGit").is_file()
Path("/tmp/raygit-response-qa-path").write_text(str(root))
print(json.dumps(dict(root=str(root), app=str(app), bundle_id=bundle_id, source=str(seed)), indent=2))
