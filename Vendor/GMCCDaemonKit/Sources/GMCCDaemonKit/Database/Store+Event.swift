import Foundation
import GRDB

// EVENT_LIST — the queryable audit trail, plus the replay read SUBSCRIBE uses.

extension Store {
    public func listEvents(_ req: EventListRequest) throws -> EventListResponse {
        try dbQueue.read { db in
            var conditions: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let kind = req.kind {
                conditions.append("kind = ?")
                arguments.append(kind)
            }
            if let subjectUuid = req.subjectUuid {
                conditions.append("subject_uuid = ?")
                arguments.append(subjectUuid)
            }
            if let sinceId = req.sinceId {
                conditions.append("id > ?")
                arguments.append(sinceId)
            }
            if let sinceTime = req.sinceTime {
                conditions.append("created_at >= ?")
                arguments.append(sinceTime)
            }
            if let untilTime = req.untilTime {
                conditions.append("created_at <= ?")
                arguments.append(untilTime)
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let limit = min(max(req.limit ?? 200, 1), 10_000)
            let events = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, subject_uuid, payload, created_at
                    FROM daemon_event
                    \(whereClause)
                    ORDER BY id
                    LIMIT \(limit)
                    """,
                arguments: StatementArguments(arguments)
            ).map { row in
                EventNotification(
                    id: row["id"],
                    kind: row["kind"],
                    subjectUuid: row["subject_uuid"],
                    payload: row["payload"],
                    createdAt: row["created_at"]
                )
            }
            return EventListResponse(events: events)
        }
    }

    /// Highest daemon_event.id — the replay horizon SUBSCRIBE acks with.
    public func lastEventId() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM daemon_event") ?? 0
        }
    }
}
