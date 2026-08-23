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
            // Item 7: derive the ckfs folder daemon-side when the caller
            // doesn't supply one — the session row (same transaction) already
            // carries its own path, and the folder convention is
            // {seq}_{name}. Legacy rows stay empty (no backfill: a wrong path
            // is worse than an absent one).
            var ckfsPath = req.ckfsRelativeStoragePath ?? ""
            if ckfsPath.isEmpty {
                let sessionPath = try String.fetchOne(
                    db,
                    sql: "SELECT ckfs_relative_storage_path FROM session WHERE uuid = ?",
                    arguments: [req.sessionUuid]) ?? ""
                if !sessionPath.isEmpty {
                    // A4: the name is slugged (forward-only, lossy) so the
                    // stored path — which the MemoryWatcher matches by exact
                    // case-sensitive equality — never contains spaces/slashes.
                    // Clients MUST use this returned path verbatim, never
                    // re-derive {seq}_{name} themselves.
                    ckfsPath = "\(sessionPath)/prompts/\(seq)_\(Store.slugStorageSegment(req.name))"
                }
            }
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
                "ckfs_relative_storage_path": ckfsPath,
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
            // Item 4: payload carries session_uuid so GMVibes can route the
            // event to one session instead of invalidating all of them.
            try self.appendEvent(
                db, kind: .createPrompt, subjectUuid: uuid,
                payload: Store.jsonPayload(
                    ["seq": seq, "name": req.name, "session_uuid": req.sessionUuid]))
            // Item 3: prompt writes advance session recency (version untouched).
            try self.touchSession(db, uuid: req.sessionUuid)
            guard let row = try self.fetchPromptRow(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "prompt", key: uuid)
            }
            return row
        }
    }

    /// nil sessionUuid lists every prompt in the db; a supplied-but-unknown
    /// uuid is a typed NOT_FOUND, never a silent empty list (the same
    /// optional-filter contract as Store+Listing).
    public func listPrompts(_ req: PromptListRequest) throws -> PromptListResponse {
        try dbQueue.read { db in
            if let sessionUuid = req.sessionUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM session WHERE uuid = ?", arguments: [sessionUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "session", key: sessionUuid)
                }
            }
            return PromptListResponse(prompts: try self.fetchPromptStubs(
                db, sessionUuid: req.sessionUuid, withReports: req.withReports ?? false))
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
            try self.touchSession(db, uuid: row.sessionUuid)
            return row
        }
    }

    /// Lifecycle v2: forward-only, adjacent-only per PromptStatus.allowedNext
    /// (one skip edge, implementing → done). This is the SINGLE front door for
    /// prompt transitions — clarify/arch verbs never touch prompt.status.
    /// Gate coupling and create-on-enter side effects run inside this same
    /// write transaction:
    ///   draft → clarifying:        creates the clarification_summary
    ///   clarifying → architecting: requires it complete; creates the
    ///                              architecture_summary
    ///   architecting → implementing: requires the architecture approved
    /// Legacy (pre-m0002) prompts bypass absent-backing-row gates AND skip
    /// create-on-enter — creating a summary for one would wedge it a state
    /// later. They walk all six states on their ckfs artifacts; gm clarify
    /// open is the explicit adoption path.
    public func setPromptStatus(_ req: PromptSetStatusRequest) throws -> PromptRow {
        try dbQueue.write { db in
            guard let head = try Row.fetchOne(
                db, sql: "SELECT status, created_at, session_uuid FROM prompt WHERE uuid = ?",
                arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            let statusRaw: String = head["status"]
            guard let from = PromptStatus(rawValue: statusRaw) else {
                throw StoreError.corruptState(entity: "prompt", detail: "status '\(statusRaw)'")
            }
            guard from.allowedNext.contains(req.status) else {
                throw StoreError.invalidTransition(
                    from: from, to: req.status,
                    reason: from.allowedNext.isEmpty
                        ? "\(from.rawValue) is terminal"
                        : "legal next from \(from.rawValue): "
                            + from.allowedNext.map(\.rawValue).sorted().joined(separator: ", "))
            }
            let legacy = try self.isLegacyPrompt(db, createdAt: head["created_at"])
            switch (from, req.status) {
            case (.draft, .clarifying):
                if !legacy {
                    _ = try self.ensureClarificationSummary(db, promptUuid: req.promptUuid)
                }
            case (.clarifying, .architecting):
                try self.requireSummaryStatus(
                    db, table: "clarification_summary", entity: "clarification",
                    promptUuid: req.promptUuid,
                    expected: ClarificationStatus.complete.rawValue,
                    bypassWhenAbsent: legacy)
                if !legacy {
                    _ = try self.ensureArchitectureSummary(db, promptUuid: req.promptUuid)
                }
            case (.architecting, .implementing):
                try self.requireSummaryStatus(
                    db, table: "architecture_summary", entity: "architecture",
                    promptUuid: req.promptUuid,
                    expected: ArchitectureStatus.approved.rawValue,
                    bypassWhenAbsent: legacy)
            default:
                break // implementing → {reviewing, done}, reviewing → done: ungated
            }
            try self.updateBase(
                db, table: "prompt", uuid: req.promptUuid,
                expectedVersion: req.expectedVersion,
                set: ["status": req.status.rawValue])
            try self.appendEvent(
                db, kind: .promptStatusChange, subjectUuid: req.promptUuid,
                payload: Store.jsonPayload(["from": from.rawValue, "to": req.status.rawValue]))
            try self.touchSession(db, uuid: head["session_uuid"])
            guard let row = try self.fetchPromptRow(db, uuid: req.promptUuid) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            return row
        }
    }

    /// Gate check shared by the lifecycle transitions: the backing summary
    /// must exist at the expected status. Absence is tolerated only for
    /// legacy prompts (missing-backing-rows tolerance covers forward
    /// transitions for pre-m0002 data — never for prompts created since).
    private func requireSummaryStatus(
        _ db: Database,
        table: String,
        entity: String,
        promptUuid: String,
        expected: String,
        bypassWhenAbsent: Bool
    ) throws {
        guard let actual = try String.fetchOne(
            db, sql: "SELECT status FROM \(table) WHERE prompt_uuid = ?", arguments: [promptUuid]
        ) else {
            if bypassWhenAbsent { return }
            throw StoreError.invalidEntityTransition(
                entity: "prompt", from: "gate", to: expected,
                reason: "no \(entity) summary exists for prompt \(promptUuid)")
        }
        guard actual == expected else {
            throw StoreError.invalidEntityTransition(
                entity: "prompt", from: actual, to: expected,
                reason: "\(entity) summary must be \(expected) first")
        }
    }

    // MARK: - Shared fetch helper

    func fetchPromptRow(_ db: Database, uuid: String) throws -> PromptRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, session_uuid, seq, code, name, backstory, goal, detail,
                       command, status, ckfs_relative_storage_path, created_at, updated_at
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
            ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
            isLegacy: try isLegacyPrompt(db, createdAt: row["created_at"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
