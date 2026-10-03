#!/usr/bin/env python3
"""Create a disposable real merge with multiple Unicode / empty-side conflicts."""
import argparse
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", nargs="?", help="new, empty fixture directory (default: temporary)")
args = parser.parse_args()
root = pathlib.Path(args.directory).expanduser().resolve() if args.directory else pathlib.Path(tempfile.mkdtemp(prefix="raygit-resolver-"))
root.mkdir(parents=True, exist_ok=True)
if any(root.iterdir()):
    parser.error("fixture directory must be empty")


def git(*arguments, allow_conflict=False):
    result = subprocess.run(["git", *arguments], cwd=root, capture_output=True, text=True)
    if result.returncode not in ([0, 1] if allow_conflict else [0]):
        raise RuntimeError(result.stderr)
    return result


def document(choices):
    sections = []
    for index, choice in enumerate(choices):
        sections.append(f"## Section {index + 1}\n" + choice)
        sections.extend(f"unchanged context {index + 1}.{line}\n" for line in range(10))
    return "".join(sections)


def write(choices):
    (root / "resolver-demo.txt").write_text(document(choices), encoding="utf-8", newline="")


git("init", "-b", "main")
git("config", "user.name", "Resolver Demo")
git("config", "user.email", "resolver-demo@example.invalid")
git("config", "merge.conflictStyle", "diff3")
write(["标题：基础版本 😀\n", "remove or replace\n", "first base\nsecond base\n"])
git("add", ".")
git("commit", "-m", "Base fixture")
git("checkout", "-b", "incoming")
write(["标题：对方版本 🌙\n", "incoming replacement\n", "incoming first\nincoming second\n"])
git("commit", "-am", "Incoming changes")
git("checkout", "main")
write(["标题：我方版本 ☀️\n", "", "local first\nlocal second\n"])
git("commit", "-am", "Local changes")
result = git("merge", "incoming", allow_conflict=True)
if result.returncode != 1 or not git("ls-files", "--unmerged").stdout:
    raise RuntimeError("fixture did not produce the expected real merge conflict")
print(root)
