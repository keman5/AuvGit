#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_FLAGS=()
case "${1:-all}" in
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
  real)
    export RAYGIT_RESPONSE_REPOSITORIES="$PWD/../raydock
$PWD"
    TEST_FILTER='RealProjectResponseTests'
    ;;
  mutations)
    TEST_FILTER='ForegroundRefreshTests|GitRepositoryTests|GitInteractionTests|FileManagementTests|WorkspaceNativeFilesTableTests|WorkspaceContextEligibilityTests|WorkspaceFileStatusTests'
    ;;
  preview-ui|preview-core)
    TEST_FILTER='DiffPreviewPerformanceTests|WorkspaceCommitTests|CommitMessageHistoryTests|DialogAppearanceTests|DialogButtonWidthTests|WorkspaceNativeFilesTableTests|NativeBranchTableTests|WorkspaceTreeRenderingTests|NativeCompactHistoryTableTests|ComparisonDocumentGeometryTests|ComparisonInitialNavigationTests|ComparisonBandNavigationTests|ComparisonSearchTests|LocalizationTests'
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
  *) print -u2 "Usage: $0 [all|performance|cold-text|branches|real|mutations|preview-ui|preview-core|preview-html|dialogs]"; exit 1 ;;
esac
swift test --build-system native -c release "${TEST_FLAGS[@]}" --filter "$TEST_FILTER"
