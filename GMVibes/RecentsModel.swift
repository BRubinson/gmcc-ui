import Foundation
import Observation

/// One project surfaced in the landing screen's Recent Projects column, paired with
/// its most-recently-updated sessions (newest first).
struct RecentProject: Identifiable, Equatable {
    let project: GMCCProjectEntry
    let recency: Date
    let sessions: [RecentSession]

    var id: UUID { project.id }
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

        // Derive: per project, gather all sessions across its instances; rank by
        // newest session; keep top N projects with their M newest sessions each.
        var derived: [RecentProject] = []
        for project in index.projects {
            guard let pdata = fs.projectData[project.id] else { continue }
            var sessions: [RecentSession] = []
            for instance in pdata.instances {
                guard let idata = fs.instanceData[instance.id] else { continue }
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
            }
            // Only surface projects that actually have sessions to show.
            guard !sessions.isEmpty else { continue }
            sessions.sort { $0.updated > $1.updated }
            derived.append(RecentProject(
                project: project,
                recency: sessions.first?.updated ?? .distantPast,
                sessions: Array(sessions.prefix(sessionLimit))
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
