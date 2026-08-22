import Foundation
import Observation
import GMCCDaemonKit

/// Session recency from ONE unfiltered FILE_CHANGE_LIST: the daemon returns a
/// global newest-first feed (`ORDER BY fc.id DESC`) with `session_uuid` +
/// `created_at` on every row, so a `sessionUuid → newest activity` map falls
/// out of a single round trip — no per-session fan-out on the fairness-free
/// serial queue.
///
/// Refresh ONLY on `.changes`/`.topology` invalidations, never on a timer:
/// the handler runs an N+1 range subquery per row, so the limit stays modest.
/// Sessions past the horizon fall back to their stubs' created/updated dates.
/// The real fix — `last_activity_at` on SESSION_LIST — is written as daemon
/// goal #1.
@Observable
@MainActor
final class SessionActivityModel {
    /// Newest file-change instant per session uuid.
    private(set) var latestBySession: [String: Date] = [:]
    private(set) var hasLoaded = false

    private static let horizon = 250
    private let service = GMCCDaemonService.shared
    private let parser = ISO8601DateFormatter()
    private var inFlight: Task<Void, Never>?

    /// Coalesced: every landing window drives this; concurrent callers share
    /// one round trip (the handler N+1s per row, so duplicates are expensive).
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
            let rows = try await service.listFileChanges(FileChangeListRequest(
                sessionUuid: nil, promptUuid: nil, relativePath: nil, limit: Self.horizon))
            var latest: [String: Date] = [:]
            // Newest-first: first hit per session wins.
            for row in rows where latest[row.sessionUuid] == nil {
                if let date = parser.date(from: row.createdAt) {
                    latest[row.sessionUuid] = date
                }
            }
            if latestBySession != latest { latestBySession = latest }
            hasLoaded = true
        } catch {
            // Recency is a ranking signal, not correctness — keep the last map.
            hasLoaded = true
        }
    }
}
