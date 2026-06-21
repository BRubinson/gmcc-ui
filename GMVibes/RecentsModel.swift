import Foundation
import Observation

/// One project surfaced in the landing screen's Recent Projects column, broken out
/// into its instances (each carrying its own newest-first sessions). Ranked by the
/// newest session across all of the project's instances.
struct RecentProject: Identifiable, Equatable {
    let project: GMCCProjectEntry
    let recency: Date
    let instances: [RecentInstance]

    var id: UUID { project.id }
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
    let updated: Date

    var id: UUID { windowID.sessionUUID }
}

/// Read-only derivation of "recent projects + their newest sessions" over the shared
/// GMCCFileSystemEmulation snapshots. Owns no persisted state and never mutates the
/// singleton — it only calls the existing async refresh APIs to warm the caches, then
/// derives a sorted view model. Page-driven: the landing view runs `loop` via `.task`
/// so it only ticks while visible.
@Observable
@MainActor
final class RecentsModel {
    private(set) var recents: [RecentProject] = []

    /// Cache parsed ISO-8601 timestamps so the refresh loop doesn't re-parse the
    /// whole tree every tick.
    private var dateCache: [String: Date] = [:]
    private static let isoFormatter = ISO8601DateFormatter()

    private let projectLimit: Int
    private let sessionLimit: Int

    init(projectLimit: Int = 5, sessionLimit: Int = 3) {
        self.projectLimit = projectLimit
        self.sessionLimit = sessionLimit
    }

    /// Visible-only refresh loop. A 2s cadence keeps the full-tree prefetch cheap
    /// while still reflecting external edits promptly.
    func loop(fs: GMCCFileSystemEmulation, gmcc: GMCCEnvironment) async {
        while !Task.isCancelled {
            await refresh(fs: fs, gmcc: gmcc)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh(fs: GMCCFileSystemEmulation, gmcc: GMCCEnvironment) async {
        guard let rootPath = gmcc[.projects], !rootPath.isEmpty else {
            recents = []
            return
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        await fs.refreshProjectIndex(rootDirectory: rootURL)
        guard let index = fs.projectIndex else {
            recents = []
            return
        }

        // Warm project_data for each project, then instance_data for each instance.
        for project in index.projects {
            await fs.refreshProjectData(uuid: project.id, at: project.projectDataURL)
            for instance in fs.projectData[project.id]?.instances ?? [] {
                await fs.refreshInstanceData(uuid: instance.id, at: instance.instanceDataURL)
            }
        }

        // Derive: per project, one section per instance (carrying RepName +
        // systemPath), each with its own newest M sessions. Rank projects by the
        // newest session across their instances; keep top N projects.
        var derived: [RecentProject] = []
        for project in index.projects {
            guard let pdata = fs.projectData[project.id] else { continue }
            var instances: [RecentInstance] = []
            for instance in pdata.instances {
                guard let idata = fs.instanceData[instance.id] else { continue }
                var sessions: [RecentSession] = []
                for session in idata.sessions {
                    sessions.append(RecentSession(
                        windowID: SessionWindowID(
                            sessionUUID: session.id,
                            instanceUUID: instance.id,
                            sessionName: session.base.name,
                            promptsDirURL: session.promptsDirectoryURL
                        ),
                        name: session.base.name,
                        code: session.base.code,
                        branch: session.branch,
                        updated: parse(session.base.updatedTime)
                    ))
                }
                // Hide instances with no sessions to show.
                guard !sessions.isEmpty else { continue }
                sessions.sort { $0.updated > $1.updated }
                instances.append(RecentInstance(
                    id: instance.id,
                    instanceName: instance.base.name,
                    code: instance.base.code,
                    systemPath: instance.systemPath ?? idata.systemPath,
                    repositoryName: pdata.repositoryName,
                    sessions: Array(sessions.prefix(sessionLimit))
                ))
            }
            // Only surface projects with at least one instance that has sessions.
            guard !instances.isEmpty else { continue }
            let recency = instances
                .compactMap { $0.sessions.first?.updated }
                .max() ?? .distantPast
            derived.append(RecentProject(
                project: project,
                recency: recency,
                instances: instances
            ))
        }
        derived.sort { $0.recency > $1.recency }
        recents = Array(derived.prefix(projectLimit))
    }

    private func parse(_ raw: String) -> Date {
        if let cached = dateCache[raw] { return cached }
        let parsed = Self.isoFormatter.date(from: raw) ?? .distantPast
        dateCache[raw] = parsed
        return parsed
    }
}
