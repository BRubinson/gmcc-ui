import Foundation
import GRDB

// ARTIFACT_ADD / ARTIFACT_LIST — file pointers for bot-phase memory/ files.
// Content stays in the files; the db stores only pointers.

extension Store {
    public func addArtifact(_ req: ArtifactAddRequest) throws -> ArtifactRow {
        try dbQueue.write { db in
            guard try Row.fetchOne(
                db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) != nil else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            // UNIQUE(prompt_uuid, file_path): re-registering the same file
            // updates its note instead of failing.
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT uuid FROM prompt_artifact WHERE prompt_uuid = ? AND file_path = ?",
                arguments: [req.promptUuid, req.filePath]
            ) {
                try db.execute(
                    sql: """
                        UPDATE prompt_artifact
                        SET note = ?, version = version + 1, updated_at = ?
                        WHERE uuid = ?
                        """,
                    arguments: [req.note, Store.isoNow(), existing])
                try self.appendEvent(
                    db, kind: .addArtifact, subjectUuid: existing,
                    payload: Store.jsonPayload(["file_path": req.filePath]))
                guard let row = try self.fetchArtifactRow(db, uuid: existing) else {
                    throw StoreError.notFound(entity: "prompt_artifact", key: existing)
                }
                return row
            }
            let uuid = try self.insertBase(db, table: "prompt_artifact", extra: [
                "prompt_uuid": req.promptUuid,
                "file_path": req.filePath,
                "note": req.note,
            ])
            try self.appendEvent(
                db, kind: .addArtifact, subjectUuid: uuid,
                payload: Store.jsonPayload(["file_path": req.filePath]))
            guard let row = try self.fetchArtifactRow(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "prompt_artifact", key: uuid)
            }
            return row
        }
    }

    public func listArtifacts(_ req: ArtifactListRequest) throws -> ArtifactListResponse {
        try dbQueue.read { db in
            ArtifactListResponse(artifacts: try self.fetchArtifactRows(db, promptUuid: req.promptUuid))
        }
    }

    // MARK: - Shared fetch helpers

    func fetchArtifactRow(_ db: Database, uuid: String) throws -> ArtifactRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, prompt_uuid, file_path, note, created_at
                FROM prompt_artifact WHERE uuid = ?
                """,
            arguments: [uuid]
        ) else { return nil }
        return ArtifactRow(
            uuid: row["uuid"],
            promptUuid: row["prompt_uuid"],
            filePath: row["file_path"],
            note: row["note"],
            createdAt: row["created_at"]
        )
    }

    func fetchArtifactRows(_ db: Database, promptUuid: String) throws -> [ArtifactRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, prompt_uuid, file_path, note, created_at
                FROM prompt_artifact WHERE prompt_uuid = ? ORDER BY created_at, id
                """,
            arguments: [promptUuid]
        ).map { row in
            ArtifactRow(
                uuid: row["uuid"],
                promptUuid: row["prompt_uuid"],
                filePath: row["file_path"],
                note: row["note"],
                createdAt: row["created_at"]
            )
        }
    }
}
