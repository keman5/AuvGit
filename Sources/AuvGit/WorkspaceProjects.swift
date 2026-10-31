import SwiftUI
import Combine
import GitCore

/// Each project keeps its operation owner when another project becomes visible.
@MainActor
final class WorkspaceProjects: ObservableObject {
    @Published private(set) var active: RepositoryStore
    @Published private(set) var sessions: [RepositoryStore]
    @Published private(set) var residentSessionIDs: Set<UUID> = []
    private var residentOrder: [UUID] = []
    private var observers: [ObjectIdentifier: AnyCancellable] = [:]
    private var sessionObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var creationObservers: [ObjectIdentifier: AnyCancellable] = [:]

    var creationPromptOperation: RepositoryCreationOperation? {
        sessions.lazy.map(\.creationOperation).first { !$0.isPresented && $0.prompt != nil }
    }

    var creationPresentationStore: RepositoryStore? {
        sessions.first { $0.creationOperation.isPresented }
    }

    init(initial supplied: RepositoryStore? = nil) {
        let initial = supplied ?? RepositoryStore()
        active = initial
        sessions = [initial]
        residentSessionIDs = [initial.sessionIdentity]; residentOrder = [initial.sessionIdentity]
        attach(initial)
    }

    private func attach(_ store: RepositoryStore) {
        store.workspaceProjects = self
        observers[ObjectIdentifier(store)] = store.objectWillChange.sink { [weak self, weak store] _ in
            guard let self, self.active === store else { return }
            self.objectWillChange.send()
        }
        if !store.persistsWorkspaceSession {
            sessionObservers[ObjectIdentifier(store)] = store.sessionChanges
                .sink { [weak self] _ in self?.sessions.first?.requestSessionSave() }
        }
        creationObservers[ObjectIdentifier(store)] = store.creationOperation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @discardableResult
    func open(_ url: URL, from source: RepositoryStore, promptsIfUnavailable: Bool) -> Task<Void, Never>? {
        let path = url.standardizedFileURL.path
        let target: RepositoryStore
        if let existing = sessions.first(where: { ($0.pendingRepositoryPath ?? $0.repositoryURL?.standardizedFileURL.path) == path }) {
            target = existing
        } else if source.repository == nil && !source.isBusy {
            target = source
        } else {
            target = source.makeWorkspaceProjectStore()
            sessions.append(target)
            attach(target)
        }
        let shouldActivate = active === source
        source.flushSession()
        if shouldActivate {
            residentOrder.removeAll { $0 == target.sessionIdentity }; residentOrder.append(target.sessionIdentity)
            residentOrder = Array(residentOrder.suffix(3))
            residentSessionIDs = Set(residentOrder)
            active = target
        }
        // An operation owns this session until completion; selecting it must not
        // refresh, cancel, or replace the repository captured by that operation.
        if target.isBusy { return Task {} }
        target.recentPaths = source.recentPaths
        target.openRepositories = Array(Set(source.openRepositories + [path])).sorted()
        return target.requestOpenInSession(url, promptsIfUnavailable: promptsIfUnavailable)
    }

    func isBusy(path: String) -> Bool {
        sessions.contains { $0.repositoryURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path && $0.isBusy }
    }

    func synchronizeProjectList(from source: RepositoryStore) {
        for store in sessions where store !== source {
            if store.recentPaths != source.recentPaths { store.recentPaths = source.recentPaths }
        }
        if sessions.first?.persistsWorkspaceSession == true {
            UserDefaults.standard.set(source.recentPaths, forKey: "recentRepositories")
        }
    }
}

/// Keep background views alive too: authentication and task controllers belong
/// to their project and must survive a selection change.
struct WorkspaceProjectsView: View {
    @ObservedObject var projects: WorkspaceProjects
    var usesBorderlessToolbar = false
    var shellToolbarModel: BorderlessToolbarModel? = nil

    @ViewBuilder private var projectContent: some View {
        if !usesBorderlessToolbar && EightPointWindowShell.usesBorderlessMode {
            MainWindow(store: projects.active)
        } else {
            ZStack {
                ForEach(projects.sessions, id: \.sessionIdentity) { store in
                    WorkspaceProjectHost(store: store, isActive: projects.active === store,
                        retainsPanels: projects.residentSessionIDs.contains(store.sessionIdentity),
                        usesBorderlessToolbar: usesBorderlessToolbar, shellToolbarModel: shellToolbarModel)
                        .equatable()
                }
            }
        }
    }

    var body: some View {
        projectContent
            .auvGitSheet(isPresented: Binding(
                get: { projects.creationPresentationStore != nil },
                set: { presented in
                    if !presented { projects.creationPresentationStore?.creationOperation.isPresented = false }
                }
            )) {
                if let store = projects.creationPresentationStore {
                    CreateRepositorySheet(store: store).environment(\.isEnabled, true)
                }
            }
            .background {
                if let creation = projects.creationPromptOperation {
                    RepositoryCreationAlerts(creation: creation)
                }
            }
    }
}

/// Operations, authentication and drafts retain their owner while only the three
/// most recently used projects keep tables and TextKit surfaces mounted.
private struct WorkspaceProjectHost: View, Equatable {
    let store: RepositoryStore
    let isActive: Bool
    let retainsPanels: Bool
    let usesBorderlessToolbar: Bool
    let shellToolbarModel: BorderlessToolbarModel?
    static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.isActive == b.isActive && a.retainsPanels == b.retainsPanels
            && a.usesBorderlessToolbar == b.usesBorderlessToolbar && a.shellToolbarModel === b.shellToolbarModel
    }
    var body: some View {
        MainWindow(store: store, usesBorderlessToolbar: usesBorderlessToolbar,
            shellToolbarModel: shellToolbarModel, retainsPanels: retainsPanels)
            .opacity(isActive ? 1 : 0).allowsHitTesting(isActive).disabled(!isActive)
            .accessibilityHidden(!isActive).zIndex(isActive ? 1 : 0)
    }
}
