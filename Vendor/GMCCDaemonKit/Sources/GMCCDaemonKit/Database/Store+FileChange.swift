import Foundation
import GRDB

// FILE_CHANGE_ADD / FILE_CHANGE_LIST — the original add_file_change
// capability plus the query side that replaces grepping changed_files: lists.

extension Store {
    /// Ensure the project → instance → session chain exists, then record the
    /// file change: session_file upsert, file_change row, one row per range,
    /// and the FILE_CHANGE daemon_event — all in a single transaction so a
    /// change and its event commit atomically.
    public func addFileChange(_ req: FileChangeAdd) throws -> FileChangeAddResponse {
        try dbQueue.write { db in
            // A dangling prompt reference must be a typed NOT_FOUND, not the
            // opaque FK DB_ERROR the insert below would produce.
            if let promptUuid = req.promptUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [promptUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "prompt", key: promptUuid)
                }
            }
            let (projectUuid, _) = try self.ensureProject(db, req.project)
            let (instanceUuid, _) = try self.ensureInstance(db, req.instance, projectUuid: projectUuid)
            let (sessionUuid, _) = try self.ensureSession(db, req.session, instanceUuid: instanceUuid)
            // The comparison join key: normalized at the boundary so
            // architecture change rows and file changes always meet on the
            // same repo-relative string (absolute-outside-instance rejected).
            let relativePath = try Store.normalizeRepoRelativePath(
                req.relativePath, repoRoot: req.instance.absoluteFileSystemPath)
            let sessionFileUuid = try self.ensureSessionFile(
                db,
                sessionUuid: sessionUuid,
                relativePath: relativePath,
                changeKind: req.changeKind
            )

            let fileChangeUuid = try self.insertBase(db, table: "file_change", extra: [
                "session_file_uuid": sessionFileUuid,
                "session_uuid": sessionUuid,
                "prompt_uuid": req.promptUuid,
                "change_kind": req.changeKind.rawValue,
            ])

            var rangeUuids: [String] = []
            for range in req.ranges {
                let rangeUuid = try self.insertBase(db, table: "file_change_range", extra: [
                    "file_change_uuid": fileChangeUuid,
                    "line_start": range.lineStart,
                    "line_end": range.lineEnd,
                    "changed_content": range.changedContent,
                ])
                rangeUuids.append(rangeUuid)
            }

            // Item 4: session_uuid in the payload lets GMVibes route the
            // event to one session instead of invalidating all of them.
            try self.appendEvent(
                db,
                kind: .fileChange,
                subjectUuid: fileChangeUuid,
                payload: Store.jsonPayload([
                    "relative_path": relativePath,
                    "change_kind": req.changeKind.rawValue,
                    "ranges": req.ranges.count,
                    "session_uuid": sessionUuid,
                ])
            )
            // Item 3: file-change writes advance session recency.
            try self.touchSession(db, uuid: sessionUuid)

            return FileChangeAddResponse(
                sessionFileUuid: sessionFileUuid,
                fileChangeUuid: fileChangeUuid,
                rangeUuids: rangeUuids
            )
        }
    }

    /// nil sessionUuid means no session filter (whole-db query); a
    /// supplied-but-unknown uuid is a typed NOT_FOUND, never a silent empty
    /// list (the same optional-filter contract as Store+Listing).
    public func listFileChanges(_ req: FileChangeListRequest) throws -> FileChangeListResponse {
        try dbQueue.read { db in
            var conditions: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let sessionUuid = req.sessionUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM session WHERE uuid = ?", arguments: [sessionUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "session", key: sessionUuid)
                }
                conditions.append("fc.session_uuid = ?")
                arguments.append(sessionUuid)
            }
            if let promptUuid = req.promptUuid {
                conditions.append("fc.prompt_uuid = ?")
                arguments.append(promptUuid)
            }
            if let relativePath = req.relativePath {
                conditions.append("sf.relative_path = ?")
                arguments.append(relativePath)
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let limit = min(max(req.limit ?? 200, 1), 10_000)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT fc.uuid, fc.session_uuid, fc.prompt_uuid, fc.change_kind, fc.created_at,
                           sf.relative_path
                    FROM file_change fc
                    JOIN session_file sf ON sf.uuid = fc.session_file_uuid
                    \(whereClause)
                    ORDER BY fc.id DESC
                    LIMIT \(limit)
                    """,
                arguments: StatementArguments(arguments))
            // One IN(...) prefetch of all ranges grouped in memory — 2
            // statements total, not one per returned row (251 at limit 250).
            let uuids = rows.map { $0["uuid"] as String }
            var rangesByChange: [String: [ChangeRangeRow]] = [:]
            if !uuids.isEmpty {
                let placeholders = Array(repeating: "?", count: uuids.count).joined(separator: ", ")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT file_change_uuid, line_start, line_end FROM file_change_range
                        WHERE file_change_uuid IN (\(placeholders)) ORDER BY id
                        """,
                    arguments: StatementArguments(uuids)
                ) {
                    let changeUuid: String = row["file_change_uuid"]
                    rangesByChange[changeUuid, default: []].append(
                        ChangeRangeRow(lineStart: row["line_start"], lineEnd: row["line_end"]))
                }
            }
            let changes = rows.map { row -> FileChangeRow in
                let uuid: String = row["uuid"]
                return FileChangeRow(
                    uuid: uuid,
                    sessionUuid: row["session_uuid"],
                    promptUuid: row["prompt_uuid"],
                    relativePath: row["relative_path"],
                    changeKind: row["change_kind"],
                    createdAt: row["created_at"],
                    ranges: rangesByChange[uuid] ?? []
                )
            }
            return FileChangeListResponse(changes: changes)
        }
    }

    // MARK: - session_file upsert

    func ensureSessionFile(
        _ db: Database,
        sessionUuid: String,
        relativePath: String,
        changeKind: ChangeKind
    ) throws -> String {
        // Deleted files stay as rows marked inactive; anything else re-activates.
        let active = changeKind == .delete ? 0 : 1
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT uuid FROM session_file WHERE session_uuid = ? AND relative_path = ?",
            arguments: [sessionUuid, relativePath]
        ) {
            try db.execute(
                sql: "UPDATE session_file SET active = ?, version = version + 1, updated_at = ? WHERE uuid = ?",
                arguments: [active, Store.isoNow(), existing]
            )
            return existing
        }
        return try insertBase(db, table: "session_file", extra: [
            "session_uuid": sessionUuid,
            "relative_path": relativePath,
            "active": active,
        ])
    }
}
