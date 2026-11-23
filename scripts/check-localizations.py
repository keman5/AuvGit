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
helpers = {
    'mainText': 'Main', 'diffText': 'Detail', 'historyText': 'Detail',
    'historyActionText': 'HistoryActions', 'interactionText': 'Interactions',
    'compareText': 'Compare', 'diffControlText': 'DiffControls', 'terminalText': 'Terminal',
    'sessionText': 'SessionWorkflows', 'workflowText': 'Workflow', 'panelText': 'VisualPanels',
    'compareExtra': 'CompareExtras', 'prefsText': 'Preferences', 'gitPrefsText': 'GitPreferences',
    'editorPrefsText': 'EditorPreferences', 'designText': 'DesignWorkflows',
    'designCompareText': 'DesignCompare', 'designWorkspaceText': 'DesignWorkspace',
    'networkText': 'Network', 'logText': 'LogWindow', 'shortcutText': 'KeyboardShortcuts',
    'repositoryContextText': 'RepositoryContext', 'sidebarRefinementText': 'SidebarRefinement',
    'forcePushText': 'ForcePush', 'historyRefinementText': 'HistoryRefinement',
    'aiCommitText': 'AICommit', 'comparisonSearchText': 'ComparisonSearch',
    'fileContextText': 'FileContext', 'previewText': 'TextPreview', 'noticeText': 'FloatingNotice',
    'resolverText': 'Resolver', 'advancedText': 'AdvancedDiff', 'pagedText': 'AdvancedDiff',
    'largeText': 'LargeComparison', 'compactText': 'CompactWorkspace',
    'shellToolbarText': 'ShellToolbar',
    'graphFeatureText': 'HistoryGraphFeatures',
    'historyComparisonText': 'HistoryComparison',
    'comparisonParityText': 'ComparisonParity',
}
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
# Helpers shared across UI files must be checked at every static call site.
# A literal key must end the argument; concatenated prefixes are dynamic keys.
for path in (root / 'Sources/AuvGit').glob('*.swift'):
    source = path.read_text()
    for helper, name in helpers.items():
        for key in re.findall(r'\b' + helper + r'\("([^"\n]+)"(?=\s*[,)])', source):
            assert key in all_tables[name], f'{path.name}: missing {name}/{key}'
    if path.name == 'WorkspaceFilesPane.swift':
        for key in re.findall(r'\b(?:text|actionButton)\("([^"\n]+)"(?=\s*[,)])', source):
            assert key in all_tables['Files'], f'{path.name}: missing Files/{key}'
    for key, name in re.findall(r'L10n\.text\("([^"\n]+)",\s*table:\s*"([^"\n]+)"', source):
        assert key in all_tables[name], f'{path.name}: missing {name}/{key}'
# An app-written GitError must have a translation even when it is reached
# through a dynamic catch/report path. External and interpolated diagnostics
# are handled separately by the failure presenter.
external_diagnostics = {
    'fatal: not a git repository (or any of the parent directories): .git',
    'Git exited but an external helper kept its output stream open.',
}
for module in ('GitCore', 'AuvGit'):
    for path in (root / 'Sources' / module).glob('*.swift'):
        for key in re.findall(r'GitError\("([^"\\\n]+)"(?=\s*(?:\)|,\s*exitCode:))', path.read_text()):
            assert key in all_tables['OperationLog'] or key in external_diagnostics, f'{path.name}: untranslated GitError/{key}'
preferences = (root / 'Sources/AuvGit/PreferencesWindow.swift').read_text()
for key in re.findall(r'choices\("([^"\n]+)"(?=\s*[,)])', preferences):
    assert key in all_tables['Preferences'], f'PreferencesWindow.swift: missing Preferences/{key}'
for key in re.findall(r'\("[^"\n]+", "([^"\n]+)"\)', preferences):
    assert key in all_tables['Preferences'], f'PreferencesWindow.swift: missing picker label Preferences/{key}'
source = (root / 'Sources/AuvGit/AuvGitApp.swift').read_text()
for key in re.findall(r'\b(?:setStatus|setDiffTitle)\("([^"\n]+)"(?=\s*[,)])', source):
    assert key in all_tables['App'], f'RepositoryStore: missing {key}'
print(f'{len(locales)} languages, {len(all_tables)} tables, {sum(map(len, all_tables.values()))} keys: parity and static lookup checks passed')
