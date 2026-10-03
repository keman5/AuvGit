#!/usr/bin/env python3
"""Disposable fixtures for editing, three-column comparison and conflicts."""
from pathlib import Path
import subprocess, tempfile
root = Path(tempfile.mkdtemp(prefix='raygit-compare-', dir='/tmp'))
def git(*args, check=True):
    return subprocess.run(['git','-C',str(root),*args],check=check,capture_output=True,text=True)
git('init','-b','main')
git('config','user.name','RayGit Fixture'); git('config','user.email','fixture@example.invalid')
git('config','commit.gpgsign','false'); git('config','core.hooksPath',str(root / '.test-hooks'))
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "HEAD version"\nlet count = 1\n\nfunc greet() {\n    print(title)\n}\n')
(root/'Conflict.txt').write_text('Shared heading\nOriginal value\nShared footer\n')
git('add','.');git('commit','-m','Comparison fixture base')
git('switch','-c','other')
(root/'Conflict.txt').write_text('Shared heading\nTheir value\nShared footer\n')
git('add','.');git('commit','-m','Other side')
git('switch','main')
(root/'Conflict.txt').write_text('Shared heading\nOur value\nShared footer\n')
git('add','.');git('commit','-m','Our side')
git('merge','other',check=False)
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "INDEX version"\nlet count = 2\n\nfunc greet() {\n    print(title)\n}\n')
git('add','Editor.swift')
(root/'Editor.swift').write_text('import Foundation\n\nlet title = "WORKTREE version"\nlet count = 3\n\nfunc greet() {\n    print("Hello", title)\n}\n')
print(root)
