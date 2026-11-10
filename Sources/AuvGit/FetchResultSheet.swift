import SwiftUI
import GitCore
import AuvGitLocalization

struct FetchResultPrompt: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let outcome: FetchOperationOutcome
}

struct FetchResultNotice {
    let outcome: FetchOperationOutcome

    var message: String {
        var parts = [L10n.text("fetchBranchCounts", table: "Network", arguments: [
            outcome.addedBranches.count, outcome.updatedBranches.count, outcome.prunedBranches.count
        ])]
        if outcome.addedBranches.isEmpty, outcome.updatedBranches.isEmpty, outcome.prunedBranches.isEmpty {
            parts.append(networkText("fetchNoChanges"))
        }
        for (key, names) in [("fetchAdded", outcome.addedBranches), ("fetchUpdated", outcome.updatedBranches), ("fetchPruned", outcome.prunedBranches)] where !names.isEmpty {
            parts.append(networkText(key) + ": " + names.joined(separator: ", "))
        }
        if let missing = outcome.missingUpstream {
            parts.append(L10n.text("fetchMissingUpstream", table: "Network", arguments: [missing.localBranch, missing.trackingBranch]))
        }
        if let failure = outcome.upstreamCheckFailure {
            parts.append(networkText("fetchUpstreamCheckFailed") + "\n" +
                (GitFailureSummary.message(for: failure, localize: { L10n.text($0, table: "OperationLog") }) ?? GitCommandLog.redact(failure)))
        }
        return parts.joined(separator: "\n\n")
    }
}

struct FetchResultSheet: View {
    @ObservedObject var store: RepositoryStore
    let prompt: FetchResultPrompt
    let close: () -> Void
    @State private var trackingBranch = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(networkText("fetchResultTitle")).font(.headline)
            ScrollView {
                Text(FetchResultNotice(outcome: prompt.outcome).message)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            if let missing = prompt.outcome.missingUpstream {
                if missing.availableBranches.isEmpty {
                    Text(networkText("fetchNoTrackingCandidates")).foregroundStyle(.orange)
                } else {
                    Picker(sidebarRefinementText("Remote Branch"), selection: $trackingBranch) {
                        Text(networkText("fetchChooseTracking")).tag("")
                        ForEach(missing.availableBranches, id: \.self) { Text($0).tag($0) }
                    }
                    Text(networkText("fetchTrackingOnly")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                DialogButton(networkText("close"), role: .cancel, action: close).disabled(store.isBusy)
                if let missing = prompt.outcome.missingUpstream, !missing.availableBranches.isEmpty {
                    DialogButton(sidebarRefinementText("Set Tracking Branch…"), prominent: true) {
                        guard store.repository === prompt.repository, !store.isBusy else { return }
                        let selected = trackingBranch
                        store.operation(sidebarRefinementText("Set Tracking Branch…"), onFailure: {
                            error = OperationFailure.message($0, repository: prompt.repository.url)
                        }) { repository in
                            try await repository.repairUpstream(missing, trackingBranch: selected)
                            close()
                        }
                    }.disabled(trackingBranch.isEmpty || store.isBusy)
                }
            }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 520)
        .interactiveDismissDisabled(store.isBusy)
        .onChange(of: store.repositoryURL) { _, _ in close() }
    }
}
