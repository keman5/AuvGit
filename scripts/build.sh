#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if command -v go >/dev/null 2>&1; then go clean -cache; fi
if [[ "${1:-}" == --test-select-all ]]; then
  swift test --build-system native --filter 'NativeSelectAllTests|NativeFocusAppearanceTests|WorkspaceKeyboardShortcutsTests|ComparisonKeyboardShortcutsTests|HistoryKeyboardShortcutsTests'
  exit
fi
if [[ "${1:-}" == --test-localizations ]]; then
  python3 scripts/check-localizations.py
  swift test --build-system native --filter LocalizationTests
  exit
fi
if [[ "${1:-}" == --test-disabled-buttons ]]; then
  swift test --build-system native --filter 'DisabledDialogButtonTests|DialogButtonWidthTests|ControlTypographyTests|NativeFocusBridgeTests.testWorkspaceUntrackedCheckboxSupportsTabAndSpace'
  exit
fi
if [[ "${1:-}" == --test-dialog-focus ]]; then
  swift test --build-system native --filter 'DialogAppearanceTests|NativeFocusBridgeTests|NativeFocusAppearanceTests|DialogButtonWidthTests|RemoteAuthenticationLayoutTests'
  exit
fi
if [[ "${1:-}" == --test-default-action ]]; then
  swift test --build-system native --filter "${AUVGIT_DEFAULT_ACTION_TEST_FILTER:-DialogAppearanceTests.testDefaultActionCueSupportsSpaceWithoutTakingFirstResponder|DialogAppearanceTests.testRealPullSheetWaitsForTabAndCyclesButtonsOnEveryPresentation|DialogAppearanceTests.testPullDefaultActionIsPullWithoutTakingKeyboardFocus|DialogAppearanceTests.testDefaultButtonHighlightDoesNotReplaceDraftEditorFocus|DialogAppearanceTests.testLatePrimaryRegistrationOverridesRewrittenCancelShortcut|NativeFocusAppearanceTests}"
  exit
fi
if [[ "${1:-}" == --test-clone-dialogs ]]; then
  swift test --build-system native --filter "${AUVGIT_CLONE_TEST_FILTER:-RepositoryCreationOperationTests|CloneDestinationTests|CloneAuthenticationTests|CloneCredentialSecurityTests|DialogButtonWidthTests|DialogAppearanceTests|NativeFocusBridgeTests|NativeFocusAppearanceTests|WorkspaceProjectsTests|OperationProgressTests|UserOperationRetentionTests|LocalizationTests}"
  exit
fi
if [[ "${1:-}" == --test-performance-review ]]; then
  swift test --build-system native -c release --filter "${AUVGIT_REVIEW_TEST_FILTER:-Comparison|ConflictPreviewPerformanceTests|RepositorySwitchLatencyTests|RepositoryQuietRefreshTests|ForegroundRefreshTests|DiffPreviewPerformanceTests|FileCompareSessionTests|WorkspaceCommitTests}"
  exit
fi
if [[ "${1:-}" == --test-dialog-buttons ]]; then
  swift test --build-system native --filter 'ControlTypographyTests|DialogButtonWidthTests|DialogAppearanceTests.testLatePrimaryRegistrationOverridesRewrittenCancelShortcut|DialogAppearanceTests.testAlertDefaultSkipsDisabledActionsAndPrefersCancelToDestructive|DialogAppearanceTests.testLongAlertMessagesScrollWhileActionsStayVisibleAndKeyboardReachable|DialogAppearanceTests.testRealSwiftUISheetUsesSharedOuterSilhouetteAndNativeDismissal|NativeFocusBridgeTests.testWorkspaceUntrackedCheckboxSupportsTabAndSpace'
  exit
fi
if [[ "${1:-}" == --test-workspace-preview ]]; then
  swift test --build-system native --filter "${AUVGIT_PREVIEW_TEST_FILTER:-WorkspaceSplitLayoutTests|WorkspaceNativeFilesTableTests|WorkspaceTreeRenderingTests|WorkspaceQuickLookTests}"
  exit
fi
if [[ "${1:-}" == --test-checkbox-focus ]]; then
  swift test --build-system native --filter "${AUVGIT_CHECKBOX_TEST_FILTER:-NativeFocusBridgeTests|NativeFocusAppearanceTests|WorkspaceCommitTests}"
  exit
fi
if [[ "${1:-}" == --test-terminal ]]; then
  swift test --build-system native --filter TerminalAppearanceTests
  exit
fi
if [[ "${1:-}" == --test-context-focus ]]; then
  swift test --build-system native --filter NativeFocusAppearanceTests
  exit
fi
if [[ "${1:-}" == --test-refresh ]]; then
  swift test --build-system native --filter "${AUVGIT_REFRESH_TEST_FILTER:-ForegroundRefreshTests|RepositoryRemoteSyncTests|WorkspaceProjectsTests}"
  exit
fi
if [[ "${1:-}" == --test-file-sorting ]]; then
  swift test --build-system native -c release --filter 'LogFileSortingTests|WorkspaceFilePreparationTests|WorkspaceNativeFilesTableTests|NativeCompactHistoryTableTests|LogWindowSelectionFocusTests'
  exit
fi
INSTALL_APP=true
case "${1:-}" in
  "") ;;
  --no-install) INSTALL_APP=false ;;
  *) print -u2 "Usage: $0 [--no-install|--test-localizations|--test-dialog-focus|--test-clone-dialogs|--test-performance-review|--test-dialog-buttons|--test-file-sorting|--test-refresh|--test-workspace-preview]"; exit 1 ;;
esac
python3 scripts/check-localizations.py
rm -rf -- "$PWD/.artifacts"
# Compile the native icon so macOS 26+ does not wrap the legacy icns in a gray tile.
ICON_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/auvgit-app-icon.XXXXXX")"
trap 'rm -rf -- "$ICON_BUILD_DIR"' EXIT
xcrun actool Resources/AppIcon.icon \
  --compile "$ICON_BUILD_DIR" \
  --app-icon AppIcon \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --target-device mac \
  --output-partial-info-plist "$ICON_BUILD_DIR/icon-info.plist"
if [[ ! -s "$ICON_BUILD_DIR/Assets.car" ]]; then
  print -u2 "Missing compiled application icon: $ICON_BUILD_DIR/Assets.car"
  exit 1
fi
swift build --build-system native -c release
BUILD_BIN_PATH="$(swift build --build-system native -c release --show-bin-path)"
APP="$PWD/.artifacts/AuvGit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$APP/Contents/Resources/Assets.car"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp "$BUILD_BIN_PATH/AuvGit" "$APP/Contents/MacOS/AuvGit"
RESOURCE_BUNDLE="$BUILD_BIN_PATH/AuvGit_AuvGitLocalization.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  print -u2 "Missing localization resource bundle: $RESOURCE_BUNDLE"
  exit 1
fi
# Keep translated resources self-contained in the distributable app.
rm -rf "$APP/Contents/Resources/AuvGit_AuvGitLocalization.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
TERMINAL_RESOURCE_BUNDLE="$BUILD_BIN_PATH/SwiftTerm_SwiftTerm.bundle"
if [[ ! -d "$TERMINAL_RESOURCE_BUNDLE" ]]; then
  print -u2 "Missing terminal resource bundle: $TERMINAL_RESOURCE_BUNDLE"
  exit 1
fi
rm -rf "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle" "$APP/SwiftTerm_SwiftTerm.bundle"
# SwiftTerm probes Contents/Resources directly without the generated Bundle.module accessor.
cp -R "$TERMINAL_RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>AuvGit</string>
<key>CFBundleIdentifier</key><string>dev.auvgit.mac</string>
<key>CFBundleName</key><string>AuvGit</string>
<key>CFBundleDisplayName</key><string>AuvGit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ja</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
# Reusing the bundle directory otherwise leaves Finder's cached icon unchanged.
touch "$APP/Contents/Resources" "$APP/Contents" "$APP"
print "Built $APP"
DMG="$PWD/.artifacts/AuvGit.dmg"
DMG_ROOT="$ICON_BUILD_DIR/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/AuvGit.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname AuvGit -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
print "Packaged $DMG"
if $INSTALL_APP; then
  LOCAL_APP="/Applications/AuvGit.app"
  codesign --verify --strict "$APP"
  swift - "$LOCAL_APP" "/Applications/RayGit.app" <<'SWIFT'
import AppKit
let appURLs = Set(CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL })
let apps = NSWorkspace.shared.runningApplications.filter {
    ["dev.auvgit.mac", "dev.raygit.mac"].contains($0.bundleIdentifier ?? "") &&
    $0.bundleURL.map { appURLs.contains($0.standardizedFileURL) } == true
}
for app in apps where !app.isTerminated {
    guard app.terminate() else {
        fputs("AuvGit could not quit. Quit it before rebuilding.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(15)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
for app in apps where !app.isTerminated { app.forceTerminate() }
let forcedDeadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < forcedDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard apps.allSatisfy({ $0.isTerminated }) else {
    fputs("AuvGit is still running. Local application was not replaced.\n", stderr)
    exit(1)
}
SWIFT
  rm -rf -- "$LOCAL_APP"
  ditto "$APP" "$LOCAL_APP"
  codesign --verify --strict "$LOCAL_APP"
  cmp "$APP/Contents/MacOS/AuvGit" "$LOCAL_APP/Contents/MacOS/AuvGit"
  swift - <<'SWIFT'
import AppKit
let legacyApps = [URL(fileURLWithPath: "/Applications/RayGit.app"),
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".artifacts/RayGit.app")]
for legacy in legacyApps {
    if FileManager.default.fileExists(atPath: legacy.path), Bundle(url: legacy)?.bundleIdentifier == "dev.raygit.mac" {
        try FileManager.default.trashItem(at: legacy, resultingItemURL: nil)
    }
}
let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".artifacts", isDirectory: true)
for artifact in try FileManager.default.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)
    where !["AuvGit.app", "AuvGit.dmg"].contains(artifact.lastPathComponent) {
    try FileManager.default.trashItem(at: artifact, resultingItemURL: nil)
}
SWIFT
  print "Installed $LOCAL_APP"
  swift package clean
fi
