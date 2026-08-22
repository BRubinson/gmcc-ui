import Foundation
import Observation
import GMCCDaemonKit

/// One session surfaced on the landing page's Recent Sessions strip. Recency
/// is the newest file-change activity in the session (SessionActivityModel's
/// one-call fold), falling back to the stub's created/updated dates — the
/// prompt-edit half of "latest prompt or file change" is a written daemon gap
/// (PromptStub carries no timestamps on wire v6).
struct RecentSessionCard: Identifiable, Equatable {
    let windowID: SessionWindowID
    let sessionName: String
    let sessionCode: String
    let projectName: String
    let instanceName: String
    /// Wire-string instance uuid, for CheckoutWatcher lookups.
    let instanceUuid: String
    let activity: Date

    var id: UUID { windowID.sessionUUID }
}

/// One instance row in the landing page's project-organized instance search.
struct InstanceHit: Identifiable, Equatable {
    let instanceUuid: String
    let instanceName: String
    let code: String
    let systemPath: String?
    let sessionCount: Int

    var id: String { instanceUuid }
}

struct ProjectInstanceGroup: Identifiable, Equatable {
    let projectUuid: String
    let projectName: String
    let repositoryName: String?
    let instances: [InstanceHit]

    var id: String { projectUuid }
}

/// Read-only derivation over the CatalogStore snapshot + the activity fold.
/// Owns no persisted state and issues no I/O — the landing view refreshes the
/// catalog/activity (event-driven) and re-derives.
@Observable
@MainActor
final class RecentsModel {
    private(set) var recentSessions: [RecentSessionCard] = []
    private(set) var projectGroups: [ProjectInstanceGroup] = []

    /// Cache parsed ISO-8601 timestamps so re-derivation doesn't re-parse the
    /// whole tree every event.
    private var dateCache: [String: Date] = [:]
    private static let isoFormatter = ISO8601DateFormatter()

    private let sessionLimit: Int

    init(sessionLimit: Int = 8) {
        self.sessionLimit = sessionLimit
    }

    func refresh(catalog: CatalogStore, activity: SessionActivityModel) {
        var sessions: [RecentSessionCard] = []
        var groups: [ProjectInstanceGroup] = []

        for project in catalog.projects {
            var hits: [InstanceHit] = []
            for instance in catalog.instancesByProject[project.uuid] ?? [] {
                let stubs = catalog.sessionsByInstance[instance.uuid] ?? []
                hits.append(InstanceHit(
                    instanceUuid: instance.uuid,
                    instanceName: instance.name,
                    code: instance.code,
                    systemPath: instance.absoluteFileSystemPath.isEmpty ? nil : instance.absoluteFileSystemPath,
                    sessionCount: stubs.count
                ))
                guard let instanceUUID = UUID(uuidString: instance.uuid) else { continue }
                for stub in stubs {
                    // A malformed uuid must skip the row, never mint a random
                    // identity (a fabricated uuid churns SwiftUI ids).
                    guard let sessionUUID = UUID(uuidString: stub.uuid) else { continue }
                    let fallback = max(parse(stub.createdAt), parse(stub.updatedAt))
                    sessions.append(RecentSessionCard(
                        windowID: SessionWindowID(
                            sessionUUID: sessionUUID,
                            instanceUUID: instanceUUID,
                            sessionName: stub.name
                        ),
                        sessionName: stub.name,
                        sessionCode: stub.code,
                        projectName: project.name,
                        instanceName: instance.name,
                        instanceUuid: instance.uuid,
                        activity: activity.latestBySession[stub.uuid] ?? fallback
                    ))
                }
            }
            guard !hits.isEmpty else { continue }
            groups.append(ProjectInstanceGroup(
                projectUuid: project.uuid,
                projectName: project.name,
                repositoryName: project.gitRepoName.isEmpty ? nil : project.gitRepoName,
                instances: hits
            ))
        }

        sessions.sort { $0.activity > $1.activity }
        let topSessions = Array(sessions.prefix(sessionLimit))
        if recentSessions != topSessions { recentSessions = topSessions }
        if projectGroups != groups { projectGroups = groups }
    }

    private func parse(_ raw: String) -> Date {
        if let cached = dateCache[raw] { return cached }
        let parsed = Self.isoFormatter.date(from: raw) ?? .distantPast
        dateCache[raw] = parsed
        return parsed
    }
}
