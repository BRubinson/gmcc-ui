import Foundation
import GRDB

// ARCH_* — the db-native architecture machine (replaces architecture.md).
// drafting → proposed → approved, plus the proposed → drafting revision edge.
// The summary body is concept-level only; specific file changes are the
// normalized persistence/general change rows the implementation agent
// executes against — persistence rows always first (they are the backbone
// every other change builds on). ARCH_GET derives implementation state from
// the path join against file_change at read time: never stored, never stale.

extension Store {

    /// Inline change_code cap, mirroring the kbite inline-content idiom.
    static let maxChangeCodeBytes = 2 * 1024 * 1024

    // MARK: - Shared create-or-return

    /// Idempotent; called by ARCH_OPEN and by setPromptStatus's
    /// clarifying → architecting create-on-enter (suppressed for legacy).
    @discardableResult
    func ensureArchitectureSummary(_ db: Database, promptUuid: String) throws -> (uuid: String, created: Bool) {
        guard try Row.fetchOne(
            db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [promptUuid]
        ) != nil else {
            throw StoreError.notFound(entity: "prompt", key: promptUuid)
        }
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM architecture_summary WHERE prompt_uuid = ?",
            arguments: [promptUuid]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "architecture_summary", extra: [
            "prompt_uuid": promptUuid,
            "body": "",
            "status": ArchitectureStatus.drafting.rawValue,
        ])
        try appendEvent(
            db, kind: .architectureChange, subjectUuid: uuid,
            payload: Store.jsonPayload(["action": "open", "prompt_uuid": promptUuid]))
        return (uuid, true)
    }

    // MARK: - Verbs

    public func archOpen(_ req: ArchOpenRequest) throws -> ArchSummaryResponse {
        try dbQueue.write { db in
            let (uuid, created) = try self.ensureArchitectureSummary(db, promptUuid: req.promptUuid)
            guard let summary = try self.fetchArchitectureSummary(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "architecture_summary", key: uuid)
            }
            return ArchSummaryResponse(summary: summary, created: created)
        }
    }

    public func archSummarize(_ req: ArchSummarizeRequest) throws -> ArchSummaryResponse {
        try dbQueue.write { db in
            let summary = try self.requireArchSummary(db, uuid: req.summaryUuid, at: .drafting, verb: "summarize")
            try self.updateBase(
                db, table: "architecture_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion, set: ["body": req.body])
            try self.appendEvent(
                db, kind: .architectureChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload(["action": "summarize", "prompt_uuid": summary.promptUuid]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchArchitectureSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "architecture_summary", key: req.summaryUuid)
            }
            return ArchSummaryResponse(summary: updated)
        }
    }

    public func archPersistAdd(_ req: ArchPersistAddRequest) throws -> ArchPersistAddResponse {
        try dbQueue.write { db in
            let summary = try self.requireArchSummary(db, uuid: req.summaryUuid, at: .drafting, verb: "persist-add")
            let path = try Store.normalizeRepoRelativePath(
                req.filePath, repoRoot: try self.instanceRoot(db, promptUuid: summary.promptUuid))
            let seq = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) FROM architecture_persistence_change WHERE architecture_summary_uuid = ?",
                arguments: [req.summaryUuid]) ?? 0) + 1
            let uuid = try self.insertBase(db, table: "architecture_persistence_change", extra: [
                "architecture_summary_uuid": req.summaryUuid,
                "seq": seq,
                "class_name": req.className,
                "file_path": path,
                "reason_brief": req.reasonBrief,
            ])
            try self.appendEvent(
                db, kind: .architectureChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "persist_add", "seq": seq, "file_path": path,
                    "prompt_uuid": summary.promptUuid,
                ]))
            let touched = try self.touchedPaths(db, promptUuid: summary.promptUuid)
            guard let change = try self.fetchPersistenceChanges(
                db, summaryUuid: req.summaryUuid, touched: touched
            ).first(where: { $0.uuid == uuid }) else {
                throw StoreError.notFound(entity: "architecture_persistence_change", key: uuid)
            }
            return ArchPersistAddResponse(change: change)
        }
    }

    public func archFieldAdd(_ req: ArchFieldAddRequest) throws -> ArchFieldAddResponse {
        try dbQueue.write { db in
            guard let parent = try Row.fetchOne(
                db,
                sql: "SELECT architecture_summary_uuid FROM architecture_persistence_change WHERE uuid = ?",
                arguments: [req.persistenceChangeUuid]
            ) else {
                throw StoreError.notFound(entity: "architecture_persistence_change", key: req.persistenceChangeUuid)
            }
            let summaryUuid: String = parent["architecture_summary_uuid"]
            let summary = try self.requireArchSummary(db, uuid: summaryUuid, at: .drafting, verb: "field-add")
            if req.isForeignKey, (req.fkTarget ?? "").isEmpty {
                throw StoreError.badRequest(detail: "--fk-target is required with --foreign-key")
            }
            let seq = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) FROM architecture_persistence_field_change WHERE persistence_change_uuid = ?",
                arguments: [req.persistenceChangeUuid]) ?? 0) + 1
            let uuid = try self.insertBase(db, table: "architecture_persistence_field_change", extra: [
                "persistence_change_uuid": req.persistenceChangeUuid,
                "seq": seq,
                "field_name": req.fieldName,
                "change_reason": req.changeReason,
                "change_purpose": req.changePurpose,
                "data_type": req.dataType,
                "nullable": req.nullable ? 1 : 0,
                "is_foreign_key": req.isForeignKey ? 1 : 0,
                "fk_target": req.isForeignKey ? req.fkTarget : nil,
                "is_indexed": req.isIndexed ? 1 : 0,
            ])
            try self.appendEvent(
                db, kind: .architectureChange, subjectUuid: summaryUuid,
                payload: Store.jsonPayload([
                    "action": "field_add", "persistence_change_uuid": req.persistenceChangeUuid,
                    "field_name": req.fieldName,
                    "prompt_uuid": summary.promptUuid,
                ]))
            guard let field = try self.fetchFieldChanges(db, changeUuid: req.persistenceChangeUuid)
                .first(where: { $0.uuid == uuid }) else {
                throw StoreError.notFound(entity: "architecture_persistence_field_change", key: uuid)
            }
            return ArchFieldAddResponse(field: field)
        }
    }

    public func archGeneralAdd(_ req: ArchGeneralAddRequest) throws -> ArchGeneralAddResponse {
        try dbQueue.write { db in
            let summary = try self.requireArchSummary(db, uuid: req.summaryUuid, at: .drafting, verb: "general-add")
            guard req.changeCode.utf8.count <= Store.maxChangeCodeBytes else {
                throw StoreError.badRequest(
                    detail: "change_code exceeds \(Store.maxChangeCodeBytes / (1024 * 1024)) MB")
            }
            let path = try Store.normalizeRepoRelativePath(
                req.filePath, repoRoot: try self.instanceRoot(db, promptUuid: summary.promptUuid))
            let seq = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) FROM architecture_general_change WHERE architecture_summary_uuid = ?",
                arguments: [req.summaryUuid]) ?? 0) + 1
            let uuid = try self.insertBase(db, table: "architecture_general_change", extra: [
                "architecture_summary_uuid": req.summaryUuid,
                "seq": seq,
                "file_path": path,
                "class_name": req.className,
                "reason_brief": req.reasonBrief,
                "change_depth": req.changeDepth.rawValue,
                "change_code": req.changeCode,
            ])
            try self.appendEvent(
                db, kind: .architectureChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "general_add", "seq": seq, "file_path": path,
                    "prompt_uuid": summary.promptUuid,
                ]))
            let touched = try self.touchedPaths(db, promptUuid: summary.promptUuid)
            guard let change = try self.fetchGeneralChanges(
                db, summaryUuid: req.summaryUuid, touched: touched
            ).first(where: { $0.uuid == uuid }) else {
                throw StoreError.notFound(entity: "architecture_general_change", key: uuid)
            }
            return ArchGeneralAddResponse(change: change)
        }
    }

    public func archPropose(_ req: ArchProposeRequest) throws -> ArchSummaryResponse {
        try archTransition(
            summaryUuid: req.summaryUuid, expectedVersion: req.expectedVersion,
            to: .proposed, action: "propose", requireFrom: .drafting)
    }

    public func archApprove(_ req: ArchApproveRequest) throws -> ArchSummaryResponse {
        try archTransition(
            summaryUuid: req.summaryUuid, expectedVersion: req.expectedVersion,
            to: .approved, action: "approve", requireFrom: .proposed)
    }

    public func archRevise(_ req: ArchReviseRequest) throws -> ArchSummaryResponse {
        try archTransition(
            summaryUuid: req.summaryUuid, expectedVersion: req.expectedVersion,
            to: .drafting, action: "revise", requireFrom: .proposed)
    }

    public func archGet(_ req: ArchGetRequest) throws -> ArchGetResponse {
        try dbQueue.read { db in
            guard let promptCreatedAt = try String.fetchOne(
                db, sql: "SELECT created_at FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let summary = try self.fetchArchitectureSummary(db, byPrompt: req.promptUuid) else {
                // A6: prompt exists — discriminated SUMMARY_ABSENT (legacy ⇒
                // read the ckfs artifact; current ⇒ gm arch open).
                throw StoreError.summaryAbsent(
                    entity: "architecture", promptUuid: req.promptUuid,
                    promptIsLegacy: try self.isLegacyPrompt(db, createdAt: promptCreatedAt))
            }
            let touched = try self.touchedPaths(db, promptUuid: req.promptUuid)
            let persistence = try self.fetchPersistenceChanges(db, summaryUuid: summary.uuid, touched: touched)
            let general = try self.fetchGeneralChanges(db, summaryUuid: summary.uuid, touched: touched)

            // Scope drift: this prompt's touched paths absent from the plan.
            let plannedPaths = Set(persistence.map(\.filePath) + general.map(\.filePath))
            let unplanned = touched.values
                .filter { !plannedPaths.contains($0.path) }
                .sorted { $0.path < $1.path }

            // Persistence-first audit: every persistence path's first touch
            // must precede every general path's first touch. Vacuously nil
            // when either side is empty or untouched.
            let persistenceFirsts = persistence.compactMap(\.implementation.firstChangedAt)
            let generalFirsts = general.compactMap(\.implementation.firstChangedAt)
            let orderingRespected: Bool?
            if let latestPersistence = persistenceFirsts.max(), let earliestGeneral = generalFirsts.min() {
                orderingRespected = latestPersistence <= earliestGeneral
            } else {
                orderingRespected = nil
            }
            return ArchGetResponse(
                summary: summary,
                persistenceChanges: persistence,
                generalChanges: general,
                unplannedChanges: unplanned,
                orderingRespected: orderingRespected
            )
        }
    }

    // MARK: - Comparison support

    /// One aggregate query (mirrors changeSummary — never per-row): every
    /// distinct path this prompt's file changes touched, with count and
    /// first/last timestamps. Keyed by path for the decoration lookup.
    private func touchedPaths(
        _ db: Database, promptUuid: String
    ) throws -> [String: UnplannedChangeRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT sf.relative_path AS path,
                   COUNT(DISTINCT fc.uuid) AS change_count,
                   MIN(fc.created_at) AS first_changed_at,
                   MAX(fc.created_at) AS last_changed_at
            FROM file_change fc
            JOIN session_file sf ON sf.uuid = fc.session_file_uuid
            WHERE fc.prompt_uuid = ?
            GROUP BY sf.relative_path
            """, arguments: [promptUuid])
        var byPath: [String: UnplannedChangeRow] = [:]
        for row in rows {
            let entry = UnplannedChangeRow(
                path: row["path"],
                changeCount: row["change_count"],
                firstChangedAt: row["first_changed_at"],
                lastChangedAt: row["last_changed_at"])
            byPath[entry.path] = entry
        }
        return byPath
    }

    private func implementationState(
        for path: String, touched: [String: UnplannedChangeRow]
    ) -> ChangeImplementationState {
        guard let entry = touched[path] else {
            return ChangeImplementationState(fileChangeCount: 0, firstChangedAt: nil, lastChangedAt: nil)
        }
        return ChangeImplementationState(
            fileChangeCount: entry.changeCount,
            firstChangedAt: entry.firstChangedAt,
            lastChangedAt: entry.lastChangedAt)
    }

    /// The arch change-add paths normalize against the instance root reached
    /// via prompt → session → instance (the add payloads carry no context
    /// blocks). Empty when the chain is broken — the normalizer then only
    /// applies its lexical rules.
    private func instanceRoot(_ db: Database, promptUuid: String) throws -> String {
        try String.fetchOne(db, sql: """
            SELECT i.absolute_file_system_path
            FROM prompt p
            JOIN session s ON s.uuid = p.session_uuid
            JOIN instance i ON i.uuid = s.instance_uuid
            WHERE p.uuid = ?
            """, arguments: [promptUuid]) ?? ""
    }

    // MARK: - Transition + fetch helpers

    private func requireArchSummary(
        _ db: Database, uuid: String, at required: ArchitectureStatus, verb: String
    ) throws -> ArchitectureSummaryRow {
        guard let summary = try fetchArchitectureSummary(db, uuid: uuid) else {
            throw StoreError.notFound(entity: "architecture_summary", key: uuid)
        }
        guard summary.architectureStatus == required else {
            throw StoreError.invalidEntityTransition(
                entity: "architecture", from: summary.status, to: verb,
                reason: "\(verb) is legal only while \(required.rawValue)")
        }
        return summary
    }

    private func archTransition(
        summaryUuid: String,
        expectedVersion: Int64,
        to: ArchitectureStatus,
        action: String,
        requireFrom: ArchitectureStatus
    ) throws -> ArchSummaryResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchArchitectureSummary(db, uuid: summaryUuid) else {
                throw StoreError.notFound(entity: "architecture_summary", key: summaryUuid)
            }
            guard let from = summary.architectureStatus else {
                throw StoreError.corruptState(entity: "architecture_summary", detail: "status '\(summary.status)'")
            }
            guard from == requireFrom, from.allowedNext.contains(to) else {
                throw StoreError.invalidEntityTransition(
                    entity: "architecture", from: from.rawValue, to: to.rawValue,
                    reason: "\(action) runs from \(requireFrom.rawValue) — this summary is \(from.rawValue)")
            }
            try self.updateBase(
                db, table: "architecture_summary", uuid: summaryUuid,
                expectedVersion: expectedVersion, set: ["status": to.rawValue])
            try self.appendEvent(
                db, kind: .architectureChange, subjectUuid: summaryUuid,
                payload: Store.jsonPayload([
                    "action": action, "from": from.rawValue, "to": to.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchArchitectureSummary(db, uuid: summaryUuid) else {
                throw StoreError.notFound(entity: "architecture_summary", key: summaryUuid)
            }
            return ArchSummaryResponse(summary: updated)
        }
    }

    func fetchArchitectureSummary(_ db: Database, uuid: String) throws -> ArchitectureSummaryRow? {
        try fetchArchitectureSummary(db, where: "uuid = ?", key: uuid)
    }

    func fetchArchitectureSummary(_ db: Database, byPrompt promptUuid: String) throws -> ArchitectureSummaryRow? {
        try fetchArchitectureSummary(db, where: "prompt_uuid = ?", key: promptUuid)
    }

    private func fetchArchitectureSummary(
        _ db: Database, where condition: String, key: String
    ) throws -> ArchitectureSummaryRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, prompt_uuid, body, status, created_at, updated_at
                FROM architecture_summary WHERE \(condition)
                """,
            arguments: [key]
        ) else { return nil }
        return ArchitectureSummaryRow(
            uuid: row["uuid"],
            version: row["version"],
            promptUuid: row["prompt_uuid"],
            body: row["body"],
            status: row["status"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func fetchPersistenceChanges(
        _ db: Database, summaryUuid: String, touched: [String: UnplannedChangeRow]
    ) throws -> [ArchPersistenceChangeRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, seq, class_name, file_path, reason_brief
                FROM architecture_persistence_change
                WHERE architecture_summary_uuid = ? ORDER BY seq
                """,
            arguments: [summaryUuid]
        ).map { row in
            let uuid: String = row["uuid"]
            let path: String = row["file_path"]
            return ArchPersistenceChangeRow(
                uuid: uuid,
                seq: row["seq"],
                className: row["class_name"],
                filePath: path,
                reasonBrief: row["reason_brief"],
                fields: try fetchFieldChanges(db, changeUuid: uuid),
                implementation: implementationState(for: path, touched: touched)
            )
        }
    }

    private func fetchFieldChanges(
        _ db: Database, changeUuid: String
    ) throws -> [ArchPersistenceFieldChangeRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, seq, field_name, change_reason, change_purpose, data_type,
                       nullable, is_foreign_key, fk_target, is_indexed
                FROM architecture_persistence_field_change
                WHERE persistence_change_uuid = ? ORDER BY seq
                """,
            arguments: [changeUuid]
        ).map { row in
            ArchPersistenceFieldChangeRow(
                uuid: row["uuid"],
                seq: row["seq"],
                fieldName: row["field_name"],
                changeReason: row["change_reason"],
                changePurpose: row["change_purpose"],
                dataType: row["data_type"],
                nullable: (row["nullable"] as Int64) != 0,
                isForeignKey: (row["is_foreign_key"] as Int64) != 0,
                fkTarget: row["fk_target"],
                isIndexed: (row["is_indexed"] as Int64) != 0
            )
        }
    }

    private func fetchGeneralChanges(
        _ db: Database, summaryUuid: String, touched: [String: UnplannedChangeRow]
    ) throws -> [ArchGeneralChangeRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, seq, file_path, class_name, reason_brief, change_depth, change_code
                FROM architecture_general_change
                WHERE architecture_summary_uuid = ? ORDER BY seq
                """,
            arguments: [summaryUuid]
        ).map { row in
            let path: String = row["file_path"]
            return ArchGeneralChangeRow(
                uuid: row["uuid"],
                seq: row["seq"],
                filePath: path,
                className: row["class_name"],
                reasonBrief: row["reason_brief"],
                changeDepth: row["change_depth"],
                changeCode: row["change_code"],
                implementation: implementationState(for: path, touched: touched)
            )
        }
    }
}
