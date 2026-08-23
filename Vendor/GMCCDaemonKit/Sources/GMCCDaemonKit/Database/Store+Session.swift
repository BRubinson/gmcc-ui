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
                SELECT uuid, version, code, name, backstory, goal, created_at, updated_at
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
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    /// nil sessionUuid = every prompt in the db, grouped by session (seq is
    /// only unique per session, hence the two-column ORDER BY). withReports
    /// attaches the per-prompt clarification/architecture summary stubs via
    /// two grouped aggregate queries folded into dictionaries — one grouped
    /// aggregation, never per-row (a per-prompt fetch here would be the N+1
    /// the enrichment exists to delete).
    func fetchPromptStubs(
        _ db: Database, sessionUuid: String?, withReports: Bool = false
    ) throws -> [PromptStub] {
        let sql: String
        let arguments: StatementArguments
        if let sessionUuid {
            sql = """
                SELECT uuid, session_uuid, seq, code, name, status, version,
                       ckfs_relative_storage_path, created_at, updated_at
                FROM prompt WHERE session_uuid = ? ORDER BY seq
                """
            arguments = [sessionUuid]
        } else {
            sql = """
                SELECT uuid, session_uuid, seq, code, name, status, version,
                       ckfs_relative_storage_path, created_at, updated_at
                FROM prompt ORDER BY session_uuid, seq
                """
            arguments = []
        }
        var clar: [String: ClarificationReportStub] = [:]
        var arch: [String: ArchitectureReportStub] = [:]
        if withReports {
            let scope = sessionUuid == nil
                ? ""
                : "WHERE cs.prompt_uuid IN (SELECT uuid FROM prompt WHERE session_uuid = ?)"
            let scopeArgs: StatementArguments = sessionUuid.map { [$0] } ?? []
            for row in try Row.fetchAll(db, sql: """
                SELECT cs.prompt_uuid, cs.uuid, cs.version, cs.status,
                       cs.refined_goal, cs.backstory_note,
                       COUNT(c.uuid) AS q_count,
                       COALESCE(SUM(c.status = 'open'), 0) AS open_count
                FROM clarification_summary cs
                LEFT JOIN clarification c ON c.clarification_summary_uuid = cs.uuid
                \(scope)
                GROUP BY cs.uuid
                """, arguments: scopeArgs) {
                clar[row["prompt_uuid"]] = ClarificationReportStub(
                    summaryUuid: row["uuid"],
                    version: row["version"],
                    status: row["status"],
                    refinedGoal: row["refined_goal"],
                    backstoryNote: row["backstory_note"],
                    questionCount: row["q_count"],
                    openQuestionCount: row["open_count"]
                )
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT cs.prompt_uuid, cs.uuid, cs.version, cs.status,
                       (SELECT COUNT(*) FROM architecture_persistence_change pc
                        WHERE pc.architecture_summary_uuid = cs.uuid) AS p_count,
                       (SELECT COUNT(*) FROM architecture_general_change gc
                        WHERE gc.architecture_summary_uuid = cs.uuid) AS g_count
                FROM architecture_summary cs
                \(scope)
                """, arguments: scopeArgs) {
                arch[row["prompt_uuid"]] = ArchitectureReportStub(
                    summaryUuid: row["uuid"],
                    version: row["version"],
                    status: row["status"],
                    persistenceChangeCount: row["p_count"],
                    generalChangeCount: row["g_count"]
                )
            }
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let uuid: String = row["uuid"]
            return PromptStub(
                uuid: uuid,
                sessionUuid: row["session_uuid"],
                seq: row["seq"],
                code: row["code"],
                name: row["name"],
                status: row["status"],
                version: row["version"],
                ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
                isLegacy: try isLegacyPrompt(db, createdAt: row["created_at"]),
                reports: withReports
                    ? PromptReportsStub(clarification: clar[uuid], architecture: arch[uuid])
                    : nil,
                createdAt: row["created_at"],
                updatedAt: row["updated_at"]
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
