import Foundation
import GRDB

// PROMPT_CREATE / PROMPT_LIST / PROMPT_GET / PROMPT_UPDATE_CONTENT /
// PROMPT_SET_STATUS — the prompt lifecycle, with the STAY TRUE convention
// (Draft-only content edits) and the forward-only transition table enforced
// here rather than by convention.

extension Store {
    public func createPrompt(_ req: PromptCreateRequest) throws -> PromptRow {
        try dbQueue.write { db in
            guard try Row.fetchOne(
                db, sql: "SELECT 1 FROM session WHERE uuid = ?", arguments: [req.sessionUuid]
            ) != nil else {
                throw StoreError.notFound(entity: "session", key: req.sessionUuid)
            }
            // Atomic under the single writer: MAX+1 inside the write
            // transaction; UNIQUE(session_uuid, seq) is the backstop.
            let seq = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) FROM prompt WHERE session_uuid = ?",
                arguments: [req.sessionUuid]) ?? 0) + 1
            let code = req.code ?? "p\(seq)"
            let uuid = try self.insertBase(db, table: "prompt", uuid: req.uuid, extra: [
                "session_uuid": req.sessionUuid,
                "seq": seq,
                "code": code,
                "name": req.name,
                "backstory": req.backstory,
                "goal": req.goal,
                "detail": req.detail,
                "command": req.command ?? "",
                "status": PromptStatus.draft.rawValue,
                "ckfs_relative_storage_path": req.ckfsRelativeStoragePath ?? "",
            ])
            // Seed prompt kbites from the session registry (create-time-only
            // inheritance, same rule as the context chain).
            let sessionKbites = try String.fetchAll(
                db,
                sql: "SELECT kbite_uuid FROM session_active_kbite WHERE session_uuid = ?",
                arguments: [req.sessionUuid])
            for kbiteUuid in sessionKbites {
                try self.insertBase(db, table: "prompt_active_kbite", extra: [
                    "prompt_uuid": uuid,
                    "kbite_uuid": kbiteUuid,
                ])
            }
            try self.appendEvent(
                db, kind: .createPrompt, subjectUuid: uuid,
                payload: Store.jsonPayload(["seq": seq, "name": req.name]))
            guard let row = try self.fetchPromptRow(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "prompt", key: uuid)
            }
            return row
        }
    }

    public func listPrompts(_ req: PromptListRequest) throws -> PromptListResponse {
        try dbQueue.read { db in
            PromptListResponse(prompts: try self.fetchPromptStubs(db, sessionUuid: req.sessionUuid))
        }
    }

    public func getPrompt(_ req: PromptGetRequest) throws -> PromptGetResponse {
        try dbQueue.read { db in
            guard let prompt = try self.fetchPromptRow(db, uuid: req.promptUuid) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            let artifacts = try self.fetchArtifactRows(db, promptUuid: req.promptUuid)
            let kbiteCodes = try String.fetchAll(db, sql: """
                SELECT k.code FROM kbite k
                JOIN prompt_active_kbite j ON j.kbite_uuid = k.uuid
                WHERE j.prompt_uuid = ?
                ORDER BY k.code
                """, arguments: [req.promptUuid])
            let changeSummary = try self.changeSummary(
                db, where: "prompt_uuid = ?", arguments: [req.promptUuid])
            return PromptGetResponse(
                prompt: prompt,
                artifacts: artifacts,
                kbiteCodes: kbiteCodes,
                changeSummary: changeSummary
            )
        }
    }

    /// STAY TRUE enforced in code: the backstory/goal/detail triple is
    /// editable only while status == draft.
    public func updatePromptContent(_ req: PromptUpdateContentRequest) throws -> PromptRow {
        try dbQueue.write { db in
            guard let statusRaw = try String.fetchOne(
                db, sql: "SELECT status FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let status = PromptStatus(rawValue: statusRaw) else {
                throw StoreError.corruptState(entity: "prompt", detail: "status '\(statusRaw)'")
            }
            guard status == .draft else {
                throw StoreError.contentLocked(status: status)
            }
            var set: [String: (any DatabaseValueConvertible)?] = [:]
            if let backstory = req.backstory { set["backstory"] = backstory }
            if let goal = req.goal { set["goal"] = goal }
            if let detail = req.detail { set["detail"] = detail }
            guard !set.isEmpty else {
                throw StoreError.emptyUpdate(entity: "prompt")
            }
            try self.updateBase(
                db, table: "prompt", uuid: req.promptUuid,
                expectedVersion: req.expectedVersion, set: set)
            try self.appendEvent(
                db, kind: .updatePrompt, subjectUuid: req.promptUuid,
                payload: Store.jsonPayload(["fields": set.keys.sorted()]))
            guard let row = try self.fetchPromptRow(db, uuid: req.promptUuid) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            return row
        }
    }

    /// Forward-only, adjacent-only lifecycle: the transition is legal iff
    /// `to == from.successor`. Illegal jumps (draft → clarified), backward
    /// moves, and no-ops are all refused.
    public func setPromptStatus(_ req: PromptSetStatusRequest) throws -> PromptRow {
        try dbQueue.write { db in
            guard let statusRaw = try String.fetchOne(
                db, sql: "SELECT status FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let from = PromptStatus(rawValue: statusRaw) else {
                throw StoreError.corruptState(entity: "prompt", detail: "status '\(statusRaw)'")
            }
            guard req.status == from.successor else {
                throw StoreError.invalidTransition(from: from, to: req.status)
            }
            try self.updateBase(
                db, table: "prompt", uuid: req.promptUuid,
                expectedVersion: req.expectedVersion,
                set: ["status": req.status.rawValue])
            try self.appendEvent(
                db, kind: .promptStatusChange, subjectUuid: req.promptUuid,
                payload: Store.jsonPayload(["from": from.rawValue, "to": req.status.rawValue]))
            guard let row = try self.fetchPromptRow(db, uuid: req.promptUuid) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            return row
        }
    }

    // MARK: - Shared fetch helper

    func fetchPromptRow(_ db: Database, uuid: String) throws -> PromptRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, session_uuid, seq, code, name, backstory, goal, detail,
                       command, status, created_at, updated_at
                FROM prompt WHERE uuid = ?
                """,
            arguments: [uuid]
        ) else { return nil }
        return PromptRow(
            uuid: row["uuid"],
            version: row["version"],
            sessionUuid: row["session_uuid"],
            seq: row["seq"],
            code: row["code"],
            name: row["name"],
            backstory: row["backstory"],
            goal: row["goal"],
            detail: row["detail"],
            command: row["command"],
            status: row["status"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
