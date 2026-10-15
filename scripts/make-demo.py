#!/usr/bin/env python3
"""Create an isolated fixture for interactive acceptance; never edits a real repo."""
from pathlib import Path
import subprocess, tempfile
root = Path(tempfile.mkdtemp(prefix='auvgit-ui-'))
def git(*args):
    subprocess.run(['git', '-C', str(root), *args], check=True, stdout=subprocess.DEVNULL)
def write(name, text):
    (root / name).write_text(text)
git('init', '-b', 'main')
git('config', 'user.name', 'AuvGit Test')
git('config', 'user.email', 'auvgit-test@example.invalid')
write('App.swift', 'import SwiftUI\n\nstruct WelcomeView: View {\n    var body: some View {\n        Text("Hello, world!")\n    }\n}\n')
write('README.md', '# Demo repository\n\nA disposable AuvGit acceptance fixture.\n')
git('add', '.'); git('commit', '-m', 'Create native app skeleton', '-m', 'Initial application and documentation for the acceptance fixture.')
git('switch', '-c', 'feature/history')
write('History.swift', 'struct History {\n    let pageSize = 200\n    let showGraph = true\n}\n')
git('add', '.'); git('commit', '-m', 'Add paginated history and commit graph')
git('switch', 'main')
write('Theme.swift', 'enum Theme { case system, light, dark }\n')
git('add', '.'); git('commit', '-m', 'Support native appearance')
git('merge', '--no-ff', 'feature/history', '-m', 'Merge history feature')
write('README.md', '# Demo repository\n\nA disposable AuvGit acceptance fixture.\n\nSupports staging, diff and history.\n')
git('add', 'README.md')
write('App.swift', 'import SwiftUI\n\nstruct WelcomeView: View {\n    var body: some View {\n        VStack(spacing: 16) {\n            Text("Welcome to AuvGit")\n                .font(.title)\n            Text("Review changes before you commit.")\n        }\n    }\n}\n')
write('Release Notes.txt', 'First preview build\nNative Git client for macOS\n')
print(root)
