#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_FLAGS=()
case "${1:-all}" in
  pull-merge)
    TEST_FILTER='GitRepositoryTests|GuardedForcePushTests|GitCommandLogTests|NetworkAuthenticationPolicyTests|LocalizationTests'
    ;;
  conflict-recovery)
    TEST_FILTER='ConflictRecoveryTests|HistoryResetTests|FileManagementTests|WorkspaceFileActionTargetsTests|WorkspaceContextEligibilityTests|WorkspaceKeyboardShortcutsTests|HistoryKeyboardShortcutsTests'
    ;;
  branch-save|branch-save-core)
    TEST_FILTER='NativeBranchTableTests|GitRepositoryTests.testCreateLocalBranchAtRemotePreservesCheckoutAndDraft|DialogAppearanceTests.testRemoteBranchNamePromptUsesClickableNativeSaveButton|DialogButtonWidthTests'
    if [[ "$1" == branch-save-core ]]; then
      TEST_FLAGS=(--skip 'DialogAppearanceTests.testRemoteBranchNamePromptUsesClickableNativeSaveButton')
    fi
    ;;
  dimming)
    export RAYGIT_DIALOG_CAPTURE=1
    TEST_FILTER='DialogAppearanceTests.testDimmingSurvivesSheetAnimationAndParentRedraw'
    ;;
  sidebar-polish)
    TEST_FILTER='NativeBranchTableTests|DialogAppearanceTests|DialogButtonWidthTests|WorkspaceNativeFilesTableTests|WorkspaceTreeRenderingTests|GitRepositoryTests|RepositoryChangeStateTests|RepositoryPresentationCacheTests|RepositoryPresentationOpeningTests|LocalizationTests'
    ;;
  all)
    TEST_FILTER='MainWindowSwitchPerformanceTests|NativeBranchTableTests|NativeCompactHistoryTableTests|HistoryColumnLayoutTests|HistoryGraphColorsTests|HistoryKeyboardShortcutsTests|HistoryPaginationTests|CommitAvatarCacheTests|WorkspaceNativeFilesTableTests|RepositorySwitchLatencyTests|WorkspaceTableMouseTests|RepositoryPresentationOpeningTests|UnavailableRepositoryTests|GitCommandLogTests|LocalizationTests|RepositoryPresentationCacheTests|WorkspaceFilePreparationTests|WorkspaceTreeCacheTests|WorkspaceTreeRenderingTests|WorkspaceOpeningPreviewTests|ForegroundRefreshTests|RepositoryQuietRefreshTests|RepositoryRemoteSyncTests|CloneDestinationTests|DialogAppearanceTests|DialogButtonWidthTests|FileManagementTests|WorkspaceFileActionTargetsTests|WorkspaceContextMenuTests'
    ;;
  performance)
    TEST_FILTER='MainWindowSwitchPerformanceTests|WorkspaceTableMouseTests'
    TEST_FLAGS=(--skip-build)
    ;;
  cold-text)
    TEST_FILTER='NativeCompactHistoryTableTests.testCellFirstBitmapDrawIncludesSystemAndMonospacedText'
    TEST_FLAGS=(--skip-build)
    ;;
  branches)
    TEST_FILTER='NativeBranchTableTests|MainWindowSwitchPerformanceTests.testCompleteMainWindowCachedSwitchFirstTargetLayout'
    ;;
  branch-icons)
    TEST_FILTER='NativeBranchTableTests'
    TEST_FLAGS=(--skip-build)
    ;;
  dialog-focus)
    TEST_FILTER='NativeBranchTableTests|DialogAppearanceTests|DialogButtonWidthTests|NativeFocusBridgeTests|NativeFocusAppearanceTests|ComparisonSearchTests'
    ;;
  dialog-presentation)
    TEST_FILTER='NativeBranchTableTests|DialogAppearanceTests|DialogButtonWidthTests|ComparisonSearchTests|NativeFocusBridgeTests.testComparisonPopoverDoesNotRebindParentScope|NativeFocusBridgeTests.testComparisonSearchFocusesQueryAfterAttachingToWindow|NativeFocusBridgeTests.testClonePresentationFocusesSourceWithoutStealingFocusOnUpdate|NativeFocusBridgeTests.testRealAlertButtonsAreKeyboardReachableAndSkipDisabled|NativeFocusBridgeTests.testRealCloneSheetStartsInSourceThenTabVisitsDestination|NativeFocusBridgeTests.testRealSwiftUISearchPopoverFocusesQueryOnPresentation'
    ;;
  real)
    export RAYGIT_RESPONSE_REPOSITORIES="$PWD/../raydock
$PWD"
    TEST_FILTER='RealProjectResponseTests'
    ;;
  mutations)
    TEST_FILTER='ForegroundRefreshTests|GitRepositoryTests|GitInteractionTests|FileManagementTests|WorkspaceNativeFilesTableTests|WorkspaceContextEligibilityTests|WorkspaceFileStatusTests'
    ;;
  preview-ui|preview-core|layout-scroll|comparison-polish)
    TEST_FILTER='DiffPreviewPerformanceTests|WorkspaceCommitTests|CommitMessageHistoryTests|DialogAppearanceTests|DialogButtonWidthTests|WorkspaceNativeFilesTableTests|NativeBranchTableTests|WorkspaceTreeRenderingTests|NativeCompactHistoryTableTests|ComparisonDocumentGeometryTests|ComparisonInitialNavigationTests|ComparisonBandNavigationTests|ComparisonSearchTests|WorkspaceSplitLayoutTests|LocalizationTests'
    if [[ "$1" == comparison-polish ]]; then
      TEST_FILTER='NativeBranchTableTests|ComparisonChromeGeometryTests|ComparisonOverviewTests|DiffPreviewPerformanceTests|ComparisonDocumentGeometryTests|ComparisonInitialNavigationTests|ComparisonBandNavigationTests|ComparisonSearchTests|CommitMessageHistoryTests|LocalizationTests'
    fi
    if [[ "$1" == preview-core ]]; then
      TEST_FLAGS=(--skip-build --skip 'DialogAppearanceTests.testRealSwiftUISheetUsesSharedOuterSilhouetteAndNativeDismissal|DialogAppearanceTests.testLongAlertMessagesScrollWhileActionsStayVisibleAndKeyboardReachable')
    fi
    ;;
  preview-html)
    TEST_FILTER='DiffPreviewPerformanceTests'
    TEST_FLAGS=(--skip-build)
    ;;
  dialogs)
    TEST_FILTER='DialogAppearanceTests|DialogButtonWidthTests'
    TEST_FLAGS=(--skip-build)
    ;;
  *) print -u2 "Usage: $0 [all|pull-merge|performance|cold-text|branches|branch-icons|branch-save|branch-save-core|sidebar-polish|dialog-focus|dialog-presentation|dimming|conflict-recovery|real|mutations|preview-ui|preview-core|layout-scroll|comparison-polish|preview-html|dialogs]"; exit 1 ;;
esac
swift test --build-system native -c release "${TEST_FLAGS[@]}" --filter "$TEST_FILTER"
