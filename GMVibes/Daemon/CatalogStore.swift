import Foundation
import Observation
import GMCCDaemonKit

/// The whole project → instance → session tree, fetched in three unfiltered
/// Listing calls and grouped in memory. At ckfs scale this is cheaper than the
/// old per-level tree walk, deletes all browse polling, and pre-plumbs
/// cross-instance search. Refreshes are driven by .topology invalidations
/// from the event hub — the store owns no timer. Groups are sorted once at
/// refresh time (never per read).
@Observable @MainActor
final class CatalogStore {
    private(set) var projects: [ProjectRow] = []
    /// Newest-first per group, sorted at refresh.
    private(set) var instancesByProject: [String: [InstanceRow]] = [:]
    private(set) var sessionsByInstance: [String: [SessionStub]] = [:]
    /// By uuid — the session-window path derivations read these.
    private(set) var sessionsByUuid: [String: SessionStub] = [:]
    private(set) var instancesByUuid: [String: InstanceRow] = [:]
    private(set) var lastError: String?
    private(set) var hasLoaded = false

    private let service = GMCCDaemonService.shared
    private var inFlight: Task<Void, Never>?

    /// Coalesced: this store is process-wide and every window's topology loop
    /// calls it per invalidation — N windows must still cost three LIST calls,
    /// not 3N, on the daemon's fairness-free serial queue.
    func refresh() async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performRefresh() async {
        do {
            let projects = try await service.listProjects()
            let instances = try await service.listInstances()
            let sessions = try await service.listSessions()

            let newProjects = projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let newInstances = Dictionary(grouping: instances, by: \.projectUuid)
                .mapValues { $0.sorted { $0.updatedAt > $1.updatedAt } }
            // SESSION_LIST is ORDER BY code — recency sorting is client-side.
            // lastActivityAt is fixed-width ISO-8601 seconds-Z, so lexicographic
            // IS chronological (the daemon's stated contract); no parsing. The
            // code tiebreak matters: Swift's sort is unstable, and an unstable
            // order under equal timestamps would defeat the change-gated
            // publication below and thrash selection state.
            let newSessions = Dictionary(grouping: sessions, by: \.instanceUuid)
                .mapValues { $0.sorted {
                    $0.lastActivityAt == $1.lastActivityAt
                        ? $0.code < $1.code
                        : $0.lastActivityAt > $1.lastActivityAt
                } }
            let newSessionsByUuid = Dictionary(sessions.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            let newInstancesByUuid = Dictionary(instances.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })

            // Change-gated publication (the app's anti-thrash idiom).
            if self.projects != newProjects { self.projects = newProjects }
            if self.instancesByProject != newInstances { self.instancesByProject = newInstances }
            if self.sessionsByInstance != newSessions { self.sessionsByInstance = newSessions }
            if self.sessionsByUuid != newSessionsByUuid { self.sessionsByUuid = newSessionsByUuid }
            if self.instancesByUuid != newInstancesByUuid { self.instancesByUuid = newInstancesByUuid }
            if lastError != nil { lastError = nil }
        } catch let error as DaemonError {
            lastError = error.userMessage
        } catch {
            lastError = String(describing: error)
        }
        // Set on every path: a daemon-up failure must be distinguishable from
        // "still loading" (Landing renders lastError, not an empty launcher).
        hasLoaded = true
    }

    func instances(of project: ProjectRow) -> [InstanceRow] {
        instancesByProject[project.uuid] ?? []
    }

    func sessions(of instance: InstanceRow) -> [SessionStub] {
        sessionsByInstance[instance.uuid] ?? []
    }

    func instance(uuid: String) -> InstanceRow? {
        instancesByUuid[uuid]
    }

}

// MARK: - Search matching over kit rows

nonisolated extension ProjectRow {
    func matches(_ q: SearchQuery) -> Bool {
        q.matchesAny(name, code, gitRepoName)
    }
}

nonisolated extension InstanceRow {
    func matches(_ q: SearchQuery) -> Bool {
        q.matchesAny(name, code, absoluteFileSystemPath)
    }
}

nonisolated extension SessionStub {
    func matches(_ q: SearchQuery) -> Bool {
        q.matchesAny(name, code, CkfsPathResolver.unslugBranch(code))
    }
}
