#!/usr/bin/env python3
"""Check translation parity and UI source keys using macOS's strings parser."""
import json
from collections import Counter
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
resources = root / 'Sources/AuvGitLocalization/Resources'
locales = ('en', 'zh-Hans', 'zh-Hant', 'ja')
def table(locale, name):
    path = resources / (locale + '.lproj') / (name + '.strings')
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
all_tables = {p.stem: table('en', p.stem) for p in (resources / 'en.lproj').glob('*.strings')}
for name, original in all_tables.items():
    for locale in locales:
        translated = table(locale, name)
        assert set(original) == set(translated), f'{locale}/{name}: key mismatch'
        assert all(translated.values()), f'{locale}/{name}: empty translation'
        for key, value in original.items():
            # Ignore literal %% while retaining conversion type and length modifier.
            def placeholders(text):
                pattern = r'%(?:([1-9]\d*)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?((?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp])'
                return Counter(match.group(2) for match in re.finditer(pattern, text.replace('%%', '')))
            assert placeholders(value) == placeholders(translated[key]), f'{locale}/{name}/{key}: placeholder mismatch'
for filename, helper, name in [('MainWindow.swift', 'mainText', 'Main'), ('DiffPane.swift', 'diffText', 'Detail'), ('HistoryPane.swift', 'historyText', 'Detail')]:
    source = (root / 'Sources/AuvGit' / filename).read_text()
    for key in re.findall(r'\b' + helper + r'\("([^"\n]+)"', source):
        assert key in all_tables[name], f'{filename}: missing {key}'
# Helpers shared across UI files must be checked at every static call site.
for path in (root / 'Sources/AuvGit').glob('*.swift'):
    source = path.read_text()
    for helper, name in [('historyActionText', 'HistoryActions'), ('interactionText', 'Interactions'), ('compareText', 'Compare'), ('diffControlText', 'DiffControls'), ('terminalText', 'Terminal'), ('sessionText', 'SessionWorkflows'), ('workflowText', 'Workflow'), ('panelText', 'VisualPanels'), ('compareExtra', 'CompareExtras'), ('prefsText', 'Preferences'), ('gitPrefsText', 'GitPreferences'), ('editorPrefsText', 'EditorPreferences')]:
        for key in re.findall(r'\b' + helper + r'\("([^"\n]+)"', source):
            assert key in all_tables[name], f'{path.name}: missing {name}/{key}'
    if path.name == 'WorkspaceFilesPane.swift':
        for key in re.findall(r'\b(?:text|actionButton)\("([^"\n]+)"', source):
            assert key in all_tables['Files'], f'{path.name}: missing Files/{key}'
    for key, name in re.findall(r'L10n\.text\("([^"\n]+)",\s*table:\s*"([^"\n]+)"', source):
        assert key in all_tables[name], f'{path.name}: missing {name}/{key}'
preferences = (root / 'Sources/AuvGit/PreferencesWindow.swift').read_text()
for key in re.findall(r'choices\("([^"\n]+)"', preferences):
    assert key in all_tables['Preferences'], f'PreferencesWindow.swift: missing Preferences/{key}'
for key in re.findall(r'\("[^"\n]+", "([^"\n]+)"\)', preferences):
    assert key in all_tables['Preferences'], f'PreferencesWindow.swift: missing picker label Preferences/{key}'
source = (root / 'Sources/AuvGit/AuvGitApp.swift').read_text()
for key in re.findall(r'\b(?:setStatus|setDiffTitle)\("([^"\n]+)"', source):
    assert key in all_tables['App'], f'RepositoryStore: missing {key}'
print(f'{len(locales)} languages, {len(all_tables)} tables, {sum(map(len, all_tables.values()))} keys: parity and static lookup checks passed')
