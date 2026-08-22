import Foundation
import GRDB

// SESSION_GET / SESSION_UPDATE.

extension Store {
    public func getSession(_ req: SessionGetRequest) throws -> SessionGetResponse {
        try dbQueue.read { db in
            guard let session = try self.fetchSessionRow(db, uuid: req.sessionUuid) else {
                throw StoreError.notFound(entity: "session", key: req.sessionUuid)
            }
            let prompts = try self.fetchPromptStubs(db, sessionUuid: req.sessionUuid)
            let changeSummary = try self.changeSummary(
                db, where: "session_uuid = ?", arguments: [req.sessionUuid])
            let promptChanges = try self.promptChangeSummaries(db, sessionUuid: req.sessionUuid)
            return SessionGetResponse(
                session: session,
                prompts: prompts,
                changeSummary: changeSummary,
                promptChanges: promptChanges
            )
        }
    }

    public func updateSession(_ req: SessionUpdateRequest) throws -> SessionRow {
        try dbQueue.write { db in
            var set: [String: (any DatabaseValueConvertible)?] = [:]
            if let name = req.name { set["name"] = name }
            if let backstory = req.backstory { set["backstory"] = backstory }
            if let goal = req.goal { set["goal"] = goal }
            if let status = req.status { set["status"] = status.rawValue }
            guard !set.isEmpty else {
                throw StoreError.emptyUpdate(entity: "session")
            }
            try self.updateBase(
                db, table: "session", uuid: req.sessionUuid,
                expectedVersion: req.expectedVersion, set: set)
            try self.appendEvent(
                db, kind: .updateSession, subjectUuid: req.sessionUuid,
                payload: Store.jsonPayload(["fields": set.keys.sorted()]))
            guard let row = try self.fetchSessionRow(db, uuid: req.sessionUuid) else {
                throw StoreError.notFound(entity: "session", key: req.sessionUuid)
            }
            return row
        }
    }

    // MARK: - Shared fetch helpers

    func fetchSessionRow(_ db: Database, uuid: String) throws -> SessionRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, code, name, backstory, goal, status, created_at, updated_at
                FROM session WHERE uuid = ?
                """,
            arguments: [uuid]
        ) else { return nil }
        return SessionRow(
            uuid: row["uuid"],
            version: row["version"],
            code: row["code"],
            name: row["name"],
            backstory: row["backstory"],
            goal: row["goal"],
            status: row["status"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    func fetchPromptStubs(_ db: Database, sessionUuid: String) throws -> [PromptStub] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, seq, code, name, status, version
                FROM prompt WHERE session_uuid = ? ORDER BY seq
                """,
            arguments: [sessionUuid]
        ).map { row in
            PromptStub(
                uuid: row["uuid"],
                seq: row["seq"],
                code: row["code"],
                name: row["name"],
                status: row["status"],
                version: row["version"]
            )
        }
    }

    /// One grouped aggregation: file_change row count, distinct files touched,
    /// and total line span from the joined ranges.
    func changeSummary(
        _ db: Database,
        where condition: String,
        arguments: StatementArguments
    ) throws -> ChangeSummary {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(DISTINCT fc.uuid) AS change_count,
                    COUNT(DISTINCT fc.session_file_uuid) AS distinct_files,
                    COALESCE(SUM(r.line_end - r.line_start + 1), 0) AS total_line_span
                FROM file_change fc
                LEFT JOIN file_change_range r ON r.file_change_uuid = fc.uuid
                WHERE fc.\(condition)
                """,
            arguments: arguments
        )
        return ChangeSummary(
            changeCount: row?["change_count"] ?? 0,
            distinctFiles: row?["distinct_files"] ?? 0,
            totalLineSpan: row?["total_line_span"] ?? 0
        )
    }

    func promptChangeSummaries(_ db: Database, sessionUuid: String) throws -> [PromptChangeSummary] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT
                    fc.prompt_uuid AS prompt_uuid,
                    COUNT(DISTINCT fc.uuid) AS change_count,
                    COUNT(DISTINCT fc.session_file_uuid) AS distinct_files,
                    COALESCE(SUM(r.line_end - r.line_start + 1), 0) AS total_line_span
                FROM file_change fc
                LEFT JOIN file_change_range r ON r.file_change_uuid = fc.uuid
                WHERE fc.session_uuid = ?
                GROUP BY fc.prompt_uuid
                ORDER BY fc.prompt_uuid
                """,
            arguments: [sessionUuid]
        ).map { row in
            PromptChangeSummary(
                promptUuid: row["prompt_uuid"],
                summary: ChangeSummary(
                    changeCount: row["change_count"] ?? 0,
                    distinctFiles: row["distinct_files"] ?? 0,
                    totalLineSpan: row["total_line_span"] ?? 0
                )
            )
        }
    }
}
