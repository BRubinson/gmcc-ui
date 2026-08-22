import Foundation
import Observation
import GMCCDaemonKit

/// One project surfaced in the landing screen's Recent Projects column, broken out
/// into its instances (each carrying its own newest-first sessions). Ranked by the
/// newest session across all of the project's instances.
struct RecentProject: Identifiable, Equatable {
    let id: UUID
    let name: String
    let recency: Date
    let instances: [RecentInstance]
}

/// One instance within a recent project — preserves per-instance identity
/// (RepName + on-disk checkout) that the old flat session list dropped.
struct RecentInstance: Identifiable, Equatable {
    let id: UUID                     // instance UUID
    let instanceName: String
    let code: String
    let systemPath: String?
    let repositoryName: String?
    let sessions: [RecentSession]
}

struct RecentSession: Identifiable, Equatable {
    let windowID: SessionWindowID
    let name: String
    let code: String
    let branch: String?
    let created: Date
    let updated: Date

    var id: UUID { windowID.sessionUUID }

    func date(for key: SessionSortKey) -> Date {
        key == .created ? created : updated
    }
}

/// Global landing-surface ordering for sessions (and project recency ranking).
/// String raw values so the choice round-trips through @AppStorage.
enum SessionSortKey: String, CaseIterable {
    case created
    case updated

    var label: String {
        switch self {
        case .created: return "Created"
        case .updated: return "Updated"
        }
    }
}

/// Read-only derivation of "recent projects + their newest sessions" over the
/// CatalogStore's daemon-backed snapshot. Owns no persisted state and issues no
/// I/O — the landing view refreshes the catalog (event-driven) and re-derives.
@Observable
@MainActor
final class RecentsModel {
    private(set) var recents: [RecentProject] = []

    /// Cache parsed ISO-8601 timestamps so re-derivation doesn't re-parse the
    /// whole tree every event.
    private var dateCache: [String: Date] = [:]
    private static let isoFormatter = ISO8601DateFormatter()

    private let projectLimit: Int

    init(projectLimit: Int = 5) {
        self.projectLimit = projectLimit
    }

    func refresh(catalog: CatalogStore, gmcc: GMCCEnvironment, sortKey: SessionSortKey = .created) {
        // Derive: per project, one section per instance (carrying RepName +
        // systemPath), each with ALL of its sessions ordered by the global sort
        // key (the card paginates the display). Rank projects by the newest
        // session — same key — across their instances; keep top N projects.
        var derived: [RecentProject] = []
        for project in catalog.projects {
            // A malformed uuid must skip the row, never mint a random identity
            // (a fabricated uuid opens a dead window and churns SwiftUI ids).
            guard let projectUUID = UUID(uuidString: project.uuid) else { continue }
            var instances: [RecentInstance] = []
            for instance in catalog.instancesByProject[project.uuid] ?? [] {
                guard let instanceUUID = UUID(uuidString: instance.uuid) else { continue }
                var sessions: [RecentSession] = []
                for stub in catalog.sessionsByInstance[instance.uuid] ?? [] {
                    guard let sessionUUID = UUID(uuidString: stub.uuid) else { continue }
                    sessions.append(RecentSession(
                        windowID: SessionWindowID(
                            sessionUUID: sessionUUID,
                            instanceUUID: instanceUUID,
                            sessionName: stub.name
                        ),
                        name: stub.name,
                        code: stub.code,
                        branch: CkfsPathResolver.unslugBranch(stub.code),
                        created: parse(stub.createdAt),
                        updated: parse(stub.updatedAt)
                    ))
                }
                // Hide instances with no sessions to show.
                guard !sessions.isEmpty else { continue }
                sessions.sort { $0.date(for: sortKey) > $1.date(for: sortKey) }
                instances.append(RecentInstance(
                    id: instanceUUID,
                    instanceName: instance.name,
                    code: instance.code,
                    systemPath: instance.absoluteFileSystemPath.isEmpty ? nil : instance.absoluteFileSystemPath,
                    repositoryName: project.gitRepoName.isEmpty ? nil : project.gitRepoName,
                    sessions: sessions
                ))
            }
            // Only surface projects with at least one instance that has sessions.
            guard !instances.isEmpty else { continue }
            let recency = instances
                .compactMap { $0.sessions.first?.date(for: sortKey) }
                .max() ?? .distantPast
            derived.append(RecentProject(
                id: projectUUID,
                name: project.name,
                recency: recency,
                instances: instances
            ))
        }
        derived.sort { $0.recency > $1.recency }
        let top = Array(derived.prefix(projectLimit))
        if recents != top { recents = top }
    }

    private func parse(_ raw: String) -> Date {
        if let cached = dateCache[raw] { return cached }
        let parsed = Self.isoFormatter.date(from: raw) ?? .distantPast
        dateCache[raw] = parsed
        return parsed
    }
}
