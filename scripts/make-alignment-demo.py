#!/usr/bin/env python3
"""Create a disposable repository for strict native two/three-pane alignment QA."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(tempfile.mkdtemp(prefix="auvgit-alignment-"))


def git(*args, conflict=False):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode not in ((0, 1) if conflict else (0,)):
        raise RuntimeError(result.stderr)
    return result.stdout


def write(name, lines):
    (root / name).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="")


def conflicts(choices):
    result = []
    for index, choice in enumerate(choices):
        result += [f"section {index + 1}", *choice]
        result += [f"unchanged separator {index + 1}.{n}" for n in range(12)]
    return result


git("init", "-b", "main")
for key, value in {
    "user.name": "Alignment Fixture", "user.email": "fixture@example.invalid",
    "commit.gpgsign": "false", "core.autocrlf": "false", "rerere.enabled": "false",
    "merge.conflictStyle": "diff3", "core.hooksPath": str(root / ".disabled-hooks"),
}.items():
    git("config", key, value)
long = "Unicode 中文 😀 café e\u0301 — " * 24
base = ["first original", "anchor A", "repeat", "repeat", "repeat", "anchor B", "middle original", long, "anchor C", "end original"]
write("ThreePane.txt", base)
write("TwoPane.txt", base)
write("Conflict.txt", conflicts([["base one"], ["base two"], ["base three", "base extra"]]))
git("add", ".")
git("commit", "-m", "Alignment base")
git("switch", "-c", "incoming")
write("Conflict.txt", conflicts([["their one", "their extra"], ["their replacement"], ["their three"]]))
git("commit", "-am", "Incoming conflict choices")
git("switch", "main")
write("Conflict.txt", conflicts([["our one"], [], ["our three", "our extra", "our third"]]))
git("commit", "-am", "Local conflict choices")
git("merge", "incoming", conflict=True)
if (root / "Conflict.txt").read_text().count("<<<<<<<") != 3:
    raise RuntimeError("expected exactly three genuine conflict blocks")
index = ["first index insert", "first original", "anchor A", "repeat", "repeat", "anchor B", "middle index 1", "middle index 2", long, "anchor C"]
write("ThreePane.txt", index)
git("add", "ThreePane.txt")
worktree = ["first worktree insert 1", "first worktree insert 2", "first original", "anchor A", "repeat", "repeat", "repeat", "repeat", "anchor B", "middle worktree", long + "result wrap extension " * 10, "anchor C", "end worktree 1", "end worktree 2"]
write("ThreePane.txt", worktree)
write("TwoPane.txt", worktree)
# Keep hashes outside Git for byte-level edit/undo and save verification.
hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in ("ThreePane.txt", "TwoPane.txt", "Conflict.txt")}
manifest = root.parent / (root.name + "-original-hashes.json")
manifest.write_text(json.dumps(hashes, indent=2) + "\n")
status = {line[3:]: line[:2] for line in git("status", "--porcelain=v1").splitlines()}
assert status == {"Conflict.txt": "UU", "ThreePane.txt": "MM", "TwoPane.txt": " M"}, status
print(root)
print(f"original byte hashes: {manifest}")
