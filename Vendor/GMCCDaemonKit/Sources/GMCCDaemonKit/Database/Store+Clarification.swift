import Foundation
import GRDB

// CLARIFY_* — the db-native clarification machine (replaces qualified.md).
// building → answering → complete, plus the complete → answering revision
// edge. Clarify verbs NEVER touch prompt.status — gm prompt set-status is the
// single front door for prompt transitions; the shared ensure helper below is
// what both doors call, so UNIQUE(prompt_uuid) can never double-create.

extension Store {

    // MARK: - Shared create-or-return

    /// Idempotent: returns the existing summary or creates one at `building`.
    /// Called by CLARIFY_OPEN and by setPromptStatus's draft → clarifying
    /// create-on-enter (suppressed there for legacy prompts; calling OPEN on a
    /// legacy prompt is the explicit adoption path).
    @discardableResult
    func ensureClarificationSummary(_ db: Database, promptUuid: String) throws -> (uuid: String, created: Bool) {
        guard try Row.fetchOne(
            db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [promptUuid]
        ) != nil else {
            throw StoreError.notFound(entity: "prompt", key: promptUuid)
        }
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM clarification_summary WHERE prompt_uuid = ?",
            arguments: [promptUuid]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "clarification_summary", extra: [
            "prompt_uuid": promptUuid,
            "status": ClarificationStatus.building.rawValue,
            "backstory_note": "",
            "refined_goal": "",
            "refined_detail": "",
        ])
        try appendEvent(
            db, kind: .clarificationChange, subjectUuid: uuid,
            payload: Store.jsonPayload(["action": "open", "prompt_uuid": promptUuid]))
        return (uuid, true)
    }

    // MARK: - Verbs

    public func clarifyOpen(_ req: ClarifyOpenRequest) throws -> ClarifySummaryResponse {
        try dbQueue.write { db in
            let (uuid, created) = try self.ensureClarificationSummary(db, promptUuid: req.promptUuid)
            guard let summary = try self.fetchClarificationSummary(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: uuid)
            }
            return ClarifySummaryResponse(summary: summary, created: created)
        }
    }

    public func clarifyAsk(_ req: ClarifyAskRequest) throws -> ClarificationRowResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchClarificationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: req.summaryUuid)
            }
            guard summary.clarificationStatus == .building else {
                throw StoreError.invalidEntityTransition(
                    entity: "clarification", from: summary.status, to: "ask",
                    reason: "questions can be inserted only while building")
            }
            let question = req.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                throw StoreError.badRequest(detail: "question is empty")
            }
            // Pre-answered insert (the confidently-resolved yeet_type path):
            // an answer requires a source; CHECK guarantees answered ⇒ answer.
            let answer = req.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: String
            var source: String?
            if let answer, !answer.isEmpty {
                status = ClarificationRowStatus.answered.rawValue
                source = (req.answerSource ?? .botInferred).rawValue
            } else {
                status = ClarificationRowStatus.open.rawValue
                source = nil
            }
            let seq = (try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq), 0) FROM clarification WHERE clarification_summary_uuid = ?",
                arguments: [req.summaryUuid]) ?? 0) + 1
            let uuid = try self.insertBase(db, table: "clarification", extra: [
                "clarification_summary_uuid": req.summaryUuid,
                "seq": seq,
                "category": req.category.rawValue,
                "question": question,
                "answer": (answer?.isEmpty ?? true) ? nil : answer,
                "answer_source": source,
                "status": status,
            ])
            try self.appendEvent(
                db, kind: .clarificationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "ask", "seq": seq, "category": req.category.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            guard let row = try self.fetchClarificationRow(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "clarification", key: uuid)
            }
            return ClarificationRowResponse(clarification: row)
        }
    }

    public func clarifySeal(_ req: ClarifySealRequest) throws -> ClarifySummaryResponse {
        try clarifyTransition(
            summaryUuid: req.summaryUuid, expectedVersion: req.expectedVersion,
            to: .answering, action: "seal", requireFrom: .building)
    }

    public func clarifyReopen(_ req: ClarifyReopenRequest) throws -> ClarifySummaryResponse {
        try clarifyTransition(
            summaryUuid: req.summaryUuid, expectedVersion: req.expectedVersion,
            to: .answering, action: "reopen", requireFrom: .complete)
    }

    /// Pure child-row update: requires the summary at `answering`, never
    /// touches its version. Revives a skipped row; skip=true marks skipped.
    public func clarifyAnswer(_ req: ClarifyAnswerRequest) throws -> ClarificationRowResponse {
        try dbQueue.write { db in
            guard let row = try self.fetchClarificationRow(db, uuid: req.clarificationUuid) else {
                throw StoreError.notFound(entity: "clarification", key: req.clarificationUuid)
            }
            guard let summary = try self.fetchClarificationSummary(db, uuid: row.clarificationSummaryUuid),
                  summary.clarificationStatus == .answering else {
                throw StoreError.invalidEntityTransition(
                    entity: "clarification", from: "summary", to: "answer",
                    reason: "answers are writable only while the summary is answering (seal first, reopen after complete)")
            }
            var set: [String: (any DatabaseValueConvertible)?] = [:]
            if req.skip {
                set["status"] = ClarificationRowStatus.skipped.rawValue
            } else {
                let answer = req.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !answer.isEmpty else {
                    throw StoreError.badRequest(detail: "answer is empty (pass --skip to skip the question)")
                }
                set["answer"] = answer
                set["answer_source"] = (req.answerSource ?? .user).rawValue
                set["status"] = ClarificationRowStatus.answered.rawValue
            }
            try self.updateBase(
                db, table: "clarification", uuid: req.clarificationUuid,
                expectedVersion: req.expectedVersion, set: set)
            try self.appendEvent(
                db, kind: .clarificationChange, subjectUuid: row.clarificationSummaryUuid,
                payload: Store.jsonPayload([
                    "action": req.skip ? "skip" : "answer", "clarification_uuid": req.clarificationUuid,
                    "prompt_uuid": summary.promptUuid,
                ]))
            guard let updated = try self.fetchClarificationRow(db, uuid: req.clarificationUuid) else {
                throw StoreError.notFound(entity: "clarification", key: req.clarificationUuid)
            }
            return ClarificationRowResponse(clarification: updated)
        }
    }

    /// answering → complete. Every non-skipped question must be answered and
    /// both refined fields non-empty. Copies refined_goal into prompt.goal —
    /// the ONE daemon-synthesized write exempt from CONTENT_LOCKED (human
    /// content edits stay draft-only); it still goes through updateBase with
    /// the prompt's current in-transaction version so the version bumps and
    /// stale holders keep conflicting.
    public func clarifyFinalize(_ req: ClarifyFinalizeRequest) throws -> ClarifyFinalizeResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchClarificationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: req.summaryUuid)
            }
            guard summary.clarificationStatus == .answering else {
                throw StoreError.invalidEntityTransition(
                    entity: "clarification", from: summary.status,
                    to: ClarificationStatus.complete.rawValue,
                    reason: "finalize runs from answering")
            }
            let openCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clarification
                WHERE clarification_summary_uuid = ? AND status = 'open'
                """, arguments: [req.summaryUuid]) ?? 0
            guard openCount == 0 else {
                throw StoreError.invalidEntityTransition(
                    entity: "clarification", from: summary.status,
                    to: ClarificationStatus.complete.rawValue,
                    reason: "\(openCount) question(s) still open — answer or skip them")
            }
            let refinedGoal = req.refinedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            let refinedDetail = req.refinedDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refinedGoal.isEmpty, !refinedDetail.isEmpty else {
                throw StoreError.badRequest(detail: "refined_goal and refined_detail must both be non-empty")
            }
            var set: [String: (any DatabaseValueConvertible)?] = [
                "status": ClarificationStatus.complete.rawValue,
                "refined_goal": refinedGoal,
                "refined_detail": refinedDetail,
            ]
            if let note = req.backstoryNote { set["backstory_note"] = note }
            try self.updateBase(
                db, table: "clarification_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion, set: set)

            guard let promptVersion = try Int64.fetchOne(
                db, sql: "SELECT version FROM prompt WHERE uuid = ?", arguments: [summary.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: summary.promptUuid)
            }
            try self.updateBase(
                db, table: "prompt", uuid: summary.promptUuid,
                expectedVersion: promptVersion, set: ["goal": refinedGoal])
            try self.appendEvent(
                db, kind: .updatePrompt, subjectUuid: summary.promptUuid,
                payload: Store.jsonPayload(["fields": ["goal"], "source": "clarify_finalize"]))
            try self.appendEvent(
                db, kind: .clarificationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload(["action": "finalize", "prompt_uuid": summary.promptUuid]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)

            guard let updatedSummary = try self.fetchClarificationSummary(db, uuid: req.summaryUuid),
                  let prompt = try self.fetchPromptRow(db, uuid: summary.promptUuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: req.summaryUuid)
            }
            return ClarifyFinalizeResponse(summary: updatedSummary, prompt: prompt)
        }
    }

    public func clarifyGet(_ req: ClarifyGetRequest) throws -> ClarifyGetResponse {
        try dbQueue.read { db in
            guard let promptCreatedAt = try String.fetchOne(
                db, sql: "SELECT created_at FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let summary = try self.fetchClarificationSummary(db, byPrompt: req.promptUuid) else {
                // A6: the prompt EXISTS (guard above) — this absence is a
                // discriminated SUMMARY_ABSENT, not NOT_FOUND. promptIsLegacy
                // tells the caller its branch: legacy ⇒ read the ckfs artifact
                // (never fabricate rows); current ⇒ open a summary.
                throw StoreError.summaryAbsent(
                    entity: "clarification", promptUuid: req.promptUuid,
                    promptIsLegacy: try self.isLegacyPrompt(db, createdAt: promptCreatedAt))
            }
            let rows = try self.fetchClarificationRows(db, summaryUuid: summary.uuid)
            return ClarifyGetResponse(summary: summary, clarifications: rows)
        }
    }

    // MARK: - Shared transition + fetch helpers

    private func clarifyTransition(
        summaryUuid: String,
        expectedVersion: Int64,
        to: ClarificationStatus,
        action: String,
        requireFrom: ClarificationStatus
    ) throws -> ClarifySummaryResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchClarificationSummary(db, uuid: summaryUuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: summaryUuid)
            }
            guard let from = summary.clarificationStatus else {
                throw StoreError.corruptState(entity: "clarification_summary", detail: "status '\(summary.status)'")
            }
            guard from == requireFrom, from.allowedNext.contains(to) else {
                throw StoreError.invalidEntityTransition(
                    entity: "clarification", from: from.rawValue, to: to.rawValue,
                    reason: "\(action) runs from \(requireFrom.rawValue) — this summary is \(from.rawValue)")
            }
            try self.updateBase(
                db, table: "clarification_summary", uuid: summaryUuid,
                expectedVersion: expectedVersion, set: ["status": to.rawValue])
            try self.appendEvent(
                db, kind: .clarificationChange, subjectUuid: summaryUuid,
                payload: Store.jsonPayload([
                    "action": action, "from": from.rawValue, "to": to.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            guard let updated = try self.fetchClarificationSummary(db, uuid: summaryUuid) else {
                throw StoreError.notFound(entity: "clarification_summary", key: summaryUuid)
            }
            return ClarifySummaryResponse(summary: updated)
        }
    }

    /// Item 3 helper shared by the clarify/arch mutation paths: prompt-scoped
    /// writes advance session recency without bumping the session version.
    func touchSessionForPrompt(_ db: Database, promptUuid: String) throws {
        if let sessionUuid = try String.fetchOne(
            db, sql: "SELECT session_uuid FROM prompt WHERE uuid = ?", arguments: [promptUuid]
        ) {
            try touchSession(db, uuid: sessionUuid)
        }
    }

    func fetchClarificationSummary(_ db: Database, uuid: String) throws -> ClarificationSummaryRow? {
        try fetchClarificationSummary(db, where: "uuid = ?", key: uuid)
    }

    func fetchClarificationSummary(_ db: Database, byPrompt promptUuid: String) throws -> ClarificationSummaryRow? {
        try fetchClarificationSummary(db, where: "prompt_uuid = ?", key: promptUuid)
    }

    private func fetchClarificationSummary(
        _ db: Database, where condition: String, key: String
    ) throws -> ClarificationSummaryRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, prompt_uuid, status, backstory_note,
                       refined_goal, refined_detail, created_at, updated_at
                FROM clarification_summary WHERE \(condition)
                """,
            arguments: [key]
        ) else { return nil }
        return ClarificationSummaryRow(
            uuid: row["uuid"],
            version: row["version"],
            promptUuid: row["prompt_uuid"],
            status: row["status"],
            backstoryNote: row["backstory_note"],
            refinedGoal: row["refined_goal"],
            refinedDetail: row["refined_detail"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func fetchClarificationRow(_ db: Database, uuid: String) throws -> ClarificationRow? {
        try fetchClarificationRows(db, where: "uuid = ?", key: uuid).first
    }

    func fetchClarificationRows(_ db: Database, summaryUuid: String) throws -> [ClarificationRow] {
        try fetchClarificationRows(db, where: "clarification_summary_uuid = ?", key: summaryUuid)
    }

    private func fetchClarificationRows(
        _ db: Database, where condition: String, key: String
    ) throws -> [ClarificationRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, version, clarification_summary_uuid, seq, category,
                       question, answer, answer_source, status
                FROM clarification WHERE \(condition) ORDER BY seq
                """,
            arguments: [key]
        ).map { row in
            ClarificationRow(
                uuid: row["uuid"],
                version: row["version"],
                clarificationSummaryUuid: row["clarification_summary_uuid"],
                seq: row["seq"],
                category: row["category"],
                question: row["question"],
                answer: row["answer"],
                answerSource: row["answer_source"],
                status: row["status"]
            )
        }
    }
}
