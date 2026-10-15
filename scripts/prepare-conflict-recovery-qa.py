#!/usr/bin/env python3
"""Create disposable stash-conflict repositories and an isolated copy of the built app."""
import json
import plistlib
import subprocess
import tempfile
import sys
from pathlib import Path

project = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="auvgit-conflict-qa-"))

def git(repo, *args, success=True):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if success:
        result.check_returncode()
    else:
        assert result.returncode != 0
    return result.stdout.strip()

paths, heads = [], {}
for name in ["Discard", "Reset"] + (["Merge", "Rebase"] if "--interactions" in sys.argv else []):
    repo = root / name
    repo.mkdir()
    git(repo, "init", "-b", "main")
    for key, value in [("user.name", "Recovery Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")]:
        git(repo, "config", key, value)
    for filename in ["conflict.txt", "deleted.txt", "normal.txt"]:
        (repo / filename).write_text("base\n")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "Base fixture")
    if name in ["Merge", "Rebase"]:
        git(repo, "switch", "-c", "other")
        (repo / "conflict.txt").write_text("prefix\nother first\nother second\nother third\ntail\n")
        git(repo, "add", "--", "conflict.txt")
        git(repo, "commit", "-m", "Other change")
        git(repo, "switch", "main")
        (repo / "conflict.txt").write_text("prefix\nour change\ntail\n")
        git(repo, "add", "--", "conflict.txt")
        git(repo, "commit", "-m", "Our change")
        git(repo, "merge" if name == "Merge" else "rebase", "other", success=False)
        assert "UU conflict.txt" in git(repo, "status", "--porcelain")
        paths.append(str(repo)); heads[name] = git(repo, "rev-parse", "HEAD")
        continue
    for filename in ["conflict.txt", "deleted.txt"]:
        (repo / filename).write_text("stashed\n")
    git(repo, "stash", "push", "-m", "Saved fixture changes")
    (repo / "conflict.txt").write_text("HEAD version\n")
    git(repo, "rm", "--", "deleted.txt")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "Current HEAD fixture")
    git(repo, "stash", "apply", success=False)
    (repo / "normal.txt").write_text("staged\n")
    git(repo, "add", "--", "normal.txt")
    (repo / "normal.txt").write_text("worktree\n")
    state = git(repo, "status", "--porcelain")
    assert "UU conflict.txt" in state and "DU deleted.txt" in state and "MM normal.txt" in state
    assert not (repo / ".git/MERGE_HEAD").exists()
    paths.append(str(repo))
    heads[name] = git(repo, "rev-parse", "HEAD")

app = root / "AuvGit Recovery QA.app"
subprocess.run(["ditto", str(project / ".artifacts/AuvGit.app"), str(app)], check=True)
info_file = app / "Contents/Info.plist"
info = plistlib.loads(info_file.read_bytes())
bundle_id = "dev.auvgit.recovery-qa-" + root.name.rsplit("-", 1)[-1]
info.update(CFBundleIdentifier=bundle_id, CFBundleName="AuvGit Recovery QA", CFBundleDisplayName="AuvGit Recovery QA")
info_file.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
session = dict(schemaVersion=1, openRepositories=paths, activeRepository=paths[0], repositories={})
preferences = {"appLanguage": "zh-Hans", "window.frameMode": "borderless", "preferences.backgroundRefresh": False,
               "recentRepositories": paths, "repositorySession.v1": json.dumps(session).encode()}
(Path.home() / "Library/Preferences" / (bundle_id + ".plist")).write_bytes(plistlib.dumps(preferences))
metadata = dict(root=str(root), app=str(app), bundle_id=bundle_id, heads=heads)
(root / "fixture.json").write_text(json.dumps(metadata))
Path("/tmp/auvgit-conflict-qa-path").write_text(str(root))
print(json.dumps(metadata, indent=2))
