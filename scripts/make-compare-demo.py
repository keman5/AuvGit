#!/usr/bin/env python3
"""Disposable fixtures for automatic two/three-column comparison and real UU conflicts."""
from pathlib import Path
import json, plistlib, subprocess, sys, tempfile
root = Path(tempfile.mkdtemp(prefix='auvgit-compare-', dir='/tmp'))
def git(*args, check=True):
    return subprocess.run(['git','-C',str(root),*args],check=check,capture_output=True,text=True)
git('init','-b','main')
git('config','user.name','AuvGit Fixture'); git('config','user.email','fixture@example.invalid')
git('config','core.autocrlf','false'); git('config','rerere.enabled','false')
git('config','commit.gpgsign','false'); git('config','core.hooksPath',str(root / '.test-hooks'))
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "HEAD version"\nlet count = 1\n\nfunc greet() {\n    print(title)\n}\n')
(root/'Conflict.txt').write_text('Shared heading\nOriginal value\nShared footer\n')
(root/'UnstagedOnly.txt').write_text('HEAD and index are unchanged.\nOriginal value\n')
(root/'StagedOnly.txt').write_text('HEAD original value\n')
mixed = [f'let value{i:03d} = "shared row {i}"\n' for i in range(120)]
mixed[20] = 'let wrapped = "' + '中文 🙂 long wrapped value ' * 24 + '"\n'
def mixed_version(edits):
    lines = mixed.copy()
    for start, end, replacement in sorted(edits, reverse=True):
        lines[start:end] = [line + '\n' for line in replacement]
    return ''.join(lines)
(root/'MixedChanges.swift').write_text(mixed_version([]))
(root/'MixedDiff.swift').write_text(mixed_version([]))
git('add','.');git('commit','-m','Comparison fixture base')
git('switch','-c','other')
(root/'Conflict.txt').write_text('Shared heading\nTheir value\nShared footer\n')
(root/'MixedChanges.swift').write_text(mixed_version([
    (10, 10, ['// inserted first', '// inserted second']), (30, 33, []),
    (45, 46, ['let value045 = "changed value"']),
    (60, 61, ['// theirs first', '// theirs second', '// theirs third']),
    (90, 92, ['// theirs shorter conflict']), (120, 120, ['// added at EOF'])]))
git('add','.');git('commit','-m','Other side')
git('switch','main')
(root/'Conflict.txt').write_text('Shared heading\nOur value\nShared footer\n')
(root/'MixedChanges.swift').write_text(mixed_version([
    (60, 61, ['// ours first', '// ours second']),
    (90, 92, ['// ours longer first', '// ours longer second', '// ours longer third', '// ours longer fourth'])]))
git('add','.');git('commit','-m','Our side')
git('merge','other',check=False)
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "INDEX version"\nlet count = 2\n\nfunc greet() {\n    print(title)\n}\n')
git('add','Editor.swift')
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "WORKTREE version"\nlet count = 3\n\nfunc greet() {\n    print("Hello", title)\n}\n')
(root/'UnstagedOnly.txt').write_text('HEAD and index are unchanged.\nWorking tree change only\n')
(root/'StagedOnly.txt').write_text('Staged value, also present in the working tree.\n')
git('add','StagedOnly.txt')
(root/'Untracked.txt').write_text('New file exists only in the working tree.\nEdit this current result; the index pane is missing.\n')
(root/'MixedDiff.swift').write_text(mixed_version([
    (10, 10, ['// inserted first', '// inserted second']), (30, 33, []),
    (45, 46, ['let value045 = \"changed value\"']), (120, 120, ['// added at EOF'])]))
expected = {'MixedDiff.swift': ' M', 'UnstagedOnly.txt': ' M', 'StagedOnly.txt': 'M ', 'Editor.swift': 'MM', 'Untracked.txt': '??', 'Conflict.txt': 'UU', 'MixedChanges.swift': 'UU'}
actual = {line[3:]: line[:2] for line in git('status','--porcelain=v1').stdout.splitlines()}
for path, state in expected.items():
    if actual.get(path) != state:
        raise RuntimeError(f'{path}: expected {state!r}, found {actual.get(path)!r}')
assert (root/'MixedChanges.swift').read_text().count('<<<<<<< HEAD') == 2
if '--qa-app' in sys.argv:
    app = root / 'AuvGit Comparison QA.app'
    (root / '.git/info/exclude').write_text('/AuvGit Comparison QA.app/\n/qa.json\n')
    project = Path(__file__).resolve().parents[1]
    subprocess.run(['ditto', str(project / '.artifacts/AuvGit.app'), str(app)], check=True)
    info_file = app / 'Contents/Info.plist'
    info = plistlib.loads(info_file.read_bytes())
    bundle_id = 'dev.auvgit.comparison-qa-' + root.name.removeprefix('auvgit-compare-')
    info.update(CFBundleIdentifier=bundle_id, CFBundleName='AuvGit Comparison QA', CFBundleDisplayName='AuvGit Comparison QA')
    info_file.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    session = dict(schemaVersion=1, openRepositories=[str(root)], activeRepository=str(root), repositories={})
    preferences = {'appLanguage': 'zh-Hans', 'preferences.backgroundRefresh': False,
                   'recentRepositories': [str(root)], 'repositorySession.v1': json.dumps(session).encode()}
    (Path.home() / 'Library/Preferences' / (bundle_id + '.plist')).write_bytes(plistlib.dumps(preferences))
    metadata = dict(repository=str(root), app=str(app), bundle_id=bundle_id)
    (root/'qa.json').write_text(json.dumps(metadata))
    print(json.dumps(metadata))
else:
    print(root)
