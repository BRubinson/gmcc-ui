import Foundation
import GRDB

// REVIEW_* — the db-native review report machine (replaces review.md).
// reviewing → complete, plus the complete → reviewing revision edge. Open is
// EXPLICIT-only: prompt status transitions never create or gate on this
// summary (skip-to-done stays legal). Review verbs NEVER touch prompt.status.
//
// Same finding_rating semantics as Store+Exploration. Two deliberate
// divergences from the clarify template, both by design:
// - overview AND verdict are carried only by COMPLETE (primary-agent-only by
//   write-path shape; verdict `legacy_unstated` exists for the verbatim
//   migration of pre-m0004 review files that never state one).
// - reviewResolve is UNGATED on summary status — the fix loop mutates finding
//   status AFTER the summary completes, and a reopen mid-loop must not strand
//   in-flight resolves (the inversion of the clarify child-lock).

extension Store {

    // MARK: - Shared create-or-return

    /// Idempotent; called ONLY by REVIEW_OPEN — never by setPromptStatus.
    @discardableResult
    func ensureReviewSummary(_ db: Database, promptUuid: String) throws -> (uuid: String, created: Bool) {
        guard try Row.fetchOne(
            db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [promptUuid]
        ) != nil else {
            throw StoreError.notFound(entity: "prompt", key: promptUuid)
        }
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM review_summary WHERE prompt_uuid = ?",
            arguments: [promptUuid]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "review_summary", extra: [
            "prompt_uuid": promptUuid,
            "status": ReviewSummaryStatus.reviewing.rawValue,
            "verdict": nil,
            "overview": "",
        ])
        try appendEvent(
            db, kind: .reviewChange, subjectUuid: uuid,
            payload: Store.jsonPayload(["action": "open", "prompt_uuid": promptUuid]))
        try touchSessionForPrompt(db, promptUuid: promptUuid)
        return (uuid, true)
    }

    // MARK: - Verbs

    public func reviewOpen(_ req: ReviewOpenRequest) throws -> ReviewSummaryResponse {
        try dbQueue.write { db in
            let (uuid, created) = try self.ensureReviewSummary(db, promptUuid: req.promptUuid)
            guard let summary = try self.fetchReviewSummary(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "review_summary", key: uuid)
            }
            return ReviewSummaryResponse(summary: summary, created: created)
        }
    }

    public func reviewFindingAdd(_ req: ReviewFindingAddRequest) throws -> ReviewFindingRowResponse {
        try dbQueue.write { db in
            let summary = try self.requireReviewSummary(
                db, uuid: req.summaryUuid, at: .reviewing, verb: "finding-add")
            let (title, body, agentName) = try Store.validatedFindingText(
                title: req.title, body: req.body, agentName: req.agentName)
            try Store.validateRating(req.rating)
            var path: String?
            if let rawPath = req.filePath {
                path = try Store.normalizeRepoRelativePath(
                    rawPath, repoRoot: try self.instanceRoot(db, promptUuid: summary.promptUuid))
            }
            // Mirrored in code ahead of the SQL CHECKs for readable errors.
            if let lineStart = req.lineStart, lineStart < 1 {
                throw StoreError.badRequest(detail: "line_start must be >= 1")
            }
            if let lineEnd = req.lineEnd {
                guard let lineStart = req.lineStart else {
                    throw StoreError.badRequest(detail: "line_end requires line_start")
                }
                guard lineEnd >= lineStart else {
                    throw StoreError.badRequest(detail: "line_end must be >= line_start")
                }
            }
            let uuid = try self.insertBase(db, table: "review_finding", extra: [
                "review_summary_uuid": req.summaryUuid,
                "kind": req.kind.rawValue,
                "title": title,
                "body": body,
                "file_path": path,
                "line_start": req.lineStart,
                "line_end": req.lineEnd,
                "agent_name": agentName,
                "finding_rating": req.rating,
                "status": ReviewFindingStatus.open.rawValue,
            ])
            try self.appendEvent(
                db, kind: .reviewChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "finding_add", "kind": req.kind.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let row = try self.fetchReviewFindings(
                db, where: "uuid = ?", arguments: [uuid]
            ).first else {
                throw StoreError.notFound(entity: "review_finding", key: uuid)
            }
            return ReviewFindingRowResponse(finding: row)
        }
    }

    /// Batch rank — same contract and rationale as exploreRank.
    public func reviewRank(_ req: ReviewRankRequest) throws -> ReviewRankResponse {
        try dbQueue.write { db in
            let summary = try self.requireReviewSummary(
                db, uuid: req.summaryUuid, at: .reviewing, verb: "rank")
            try self.applyRankBatch(
                db, table: "review_finding", parentColumn: "review_summary_uuid",
                summaryUuid: req.summaryUuid, ratings: req.ratings)
            let unranked = try self.unrankedCount(
                db, table: "review_finding", parentColumn: "review_summary_uuid",
                summaryUuid: req.summaryUuid)
            try self.appendEvent(
                db, kind: .reviewChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "rank", "count": req.ratings.count,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchReviewSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "review_summary", key: req.summaryUuid)
            }
            return ReviewRankResponse(
                summary: updated, updatedCount: req.ratings.count, unrankedCount: unranked)
        }
    }

    /// Record one finding's resolution. Pure child-row update (expectedVersion
    /// targets the FINDING) and deliberately UNGATED on summary status — see
    /// the file header. Edges: open → fixed | accepted | wont_fix, plus
    /// lateral corrections among the resolved values; never back to open.
    public func reviewResolve(_ req: ReviewResolveRequest) throws -> ReviewFindingRowResponse {
        try dbQueue.write { db in
            guard let row = try self.fetchReviewFindings(
                db, where: "uuid = ?", arguments: [req.findingUuid]
            ).first else {
                throw StoreError.notFound(entity: "review_finding", key: req.findingUuid)
            }
            guard let from = ReviewFindingStatus(rawValue: row.status) else {
                throw StoreError.corruptState(entity: "review_finding", detail: "status '\(row.status)'")
            }
            // Same-status retry is an idempotent no-op (fix loops re-run):
            // no version bump, no event, just the current row back.
            if from == req.status {
                return ReviewFindingRowResponse(finding: row)
            }
            guard from.allowedNext.contains(req.status) else {
                throw StoreError.invalidEntityTransition(
                    entity: "review_finding", from: from.rawValue, to: req.status.rawValue,
                    reason: from == .open
                        ? "resolve targets fixed, accepted, or wont_fix"
                        : "a resolved finding can only move laterally (never back to open)")
            }
            try self.updateBase(
                db, table: "review_finding", uuid: req.findingUuid,
                expectedVersion: req.expectedVersion, set: ["status": req.status.rawValue])
            try self.appendEvent(
                db, kind: .reviewChange, subjectUuid: row.reviewSummaryUuid,
                payload: Store.jsonPayload([
                    "action": "resolve", "finding_uuid": req.findingUuid,
                    "to": req.status.rawValue,
                ]))
            if let summary = try self.fetchReviewSummary(db, uuid: row.reviewSummaryUuid) {
                try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            }
            guard let updated = try self.fetchReviewFindings(
                db, where: "uuid = ?", arguments: [req.findingUuid]
            ).first else {
                throw StoreError.notFound(entity: "review_finding", key: req.findingUuid)
            }
            return ReviewFindingRowResponse(finding: updated)
        }
    }

    /// reviewing → complete. Refuses while any finding is unranked; requires a
    /// verdict (validated in Swift ahead of the SQL CHECK for a clean
    /// message). overview + verdict are carried only here.
    public func reviewComplete(_ req: ReviewCompleteRequest) throws -> ReviewSummaryResponse {
        try dbQueue.write { db in
            let summary = try self.requireReviewSummary(
                db, uuid: req.summaryUuid, at: .reviewing, verb: "complete")
            let unranked = try self.unrankedCount(
                db, table: "review_finding", parentColumn: "review_summary_uuid",
                summaryUuid: req.summaryUuid)
            guard unranked == 0 else {
                throw StoreError.invalidEntityTransition(
                    entity: "review", from: summary.status,
                    to: ReviewSummaryStatus.complete.rawValue,
                    reason: "\(unranked) finding(s) unranked — run gm review rank first")
            }
            let overview = try Store.validatedOverview(req.overview, entity: "review")
            try self.updateBase(
                db, table: "review_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion,
                set: [
                    "status": ReviewSummaryStatus.complete.rawValue,
                    "overview": overview,
                    "verdict": req.verdict.rawValue,
                ])
            try self.appendEvent(
                db, kind: .reviewChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "complete", "verdict": req.verdict.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchReviewSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "review_summary", key: req.summaryUuid)
            }
            return ReviewSummaryResponse(summary: updated)
        }
    }

    /// complete → reviewing: the revision edge (same preservation contract as
    /// exploreReopen; the persisted verdict survives until re-complete).
    public func reviewReopen(_ req: ReviewReopenRequest) throws -> ReviewSummaryResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchReviewSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "review_summary", key: req.summaryUuid)
            }
            guard summary.reviewStatus == .complete else {
                throw StoreError.invalidEntityTransition(
                    entity: "review", from: summary.status,
                    to: ReviewSummaryStatus.reviewing.rawValue,
                    reason: "reopen runs from complete — this summary is \(summary.status)")
            }
            try self.updateBase(
                db, table: "review_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion,
                set: ["status": ReviewSummaryStatus.reviewing.rawValue])
            try self.appendEvent(
                db, kind: .reviewChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload(["action": "reopen", "prompt_uuid": summary.promptUuid]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchReviewSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "review_summary", key: req.summaryUuid)
            }
            return ReviewSummaryResponse(summary: updated)
        }
    }

    public func reviewGet(_ req: ReviewGetRequest) throws -> ReviewGetResponse {
        try dbQueue.read { db in
            guard let promptCreatedAt = try String.fetchOne(
                db, sql: "SELECT created_at FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let summary = try self.fetchReviewSummary(db, byPrompt: req.promptUuid) else {
                throw StoreError.summaryAbsent(
                    entity: "review", promptUuid: req.promptUuid,
                    promptIsLegacy: try self.isLegacyPrompt(db, createdAt: promptCreatedAt))
            }
            let window = try Store.ratingWindow(full: req.full, min: req.ratingMin, max: req.ratingMax)
            let all = try self.fetchReviewFindings(
                db, where: "review_summary_uuid = ?", arguments: [summary.uuid])
            var full: [ReviewFindingRow] = []
            var stubs: [ReviewFindingStub] = []
            for row in all {
                if Store.ratingInWindow(row.findingRating, window: window) {
                    full.append(row)
                } else {
                    stubs.append(ReviewFindingStub(
                        uuid: row.uuid, kind: row.kind, title: row.title,
                        findingRating: row.findingRating, agentName: row.agentName,
                        status: row.status))
                }
            }
            return ReviewGetResponse(summary: summary, findings: full, findingStubs: stubs)
        }
    }

    // MARK: - Transition + fetch helpers

    private func requireReviewSummary(
        _ db: Database, uuid: String, at required: ReviewSummaryStatus, verb: String
    ) throws -> ReviewSummaryRow {
        guard let summary = try fetchReviewSummary(db, uuid: uuid) else {
            throw StoreError.notFound(entity: "review_summary", key: uuid)
        }
        guard summary.reviewStatus == required else {
            throw StoreError.invalidEntityTransition(
                entity: "review", from: summary.status, to: verb,
                reason: "\(verb) is legal only while \(required.rawValue)")
        }
        return summary
    }

    func fetchReviewSummary(_ db: Database, uuid: String) throws -> ReviewSummaryRow? {
        try fetchReviewSummary(db, where: "uuid = ?", key: uuid)
    }

    func fetchReviewSummary(_ db: Database, byPrompt promptUuid: String) throws -> ReviewSummaryRow? {
        try fetchReviewSummary(db, where: "prompt_uuid = ?", key: promptUuid)
    }

    private func fetchReviewSummary(
        _ db: Database, where condition: String, key: String
    ) throws -> ReviewSummaryRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, prompt_uuid, status, verdict, overview,
                       created_at, updated_at
                FROM review_summary WHERE \(condition)
                """,
            arguments: [key]
        ) else { return nil }
        return ReviewSummaryRow(
            uuid: row["uuid"],
            version: row["version"],
            promptUuid: row["prompt_uuid"],
            status: row["status"],
            verdict: row["verdict"],
            overview: row["overview"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    /// Same explicit ordering contract as fetchExplorationFindings: unranked
    /// first, then rating ascending, then id.
    private func fetchReviewFindings(
        _ db: Database, where condition: String, arguments: StatementArguments
    ) throws -> [ReviewFindingRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, version, review_summary_uuid, kind, title, body,
                       file_path, line_start, line_end, agent_name, finding_rating, status
                FROM review_finding WHERE \(condition)
                ORDER BY finding_rating IS NOT NULL, finding_rating, id
                """,
            arguments: arguments
        ).map { row in
            ReviewFindingRow(
                uuid: row["uuid"],
                version: row["version"],
                reviewSummaryUuid: row["review_summary_uuid"],
                kind: row["kind"],
                title: row["title"],
                body: row["body"],
                filePath: row["file_path"],
                lineStart: row["line_start"],
                lineEnd: row["line_end"],
                agentName: row["agent_name"],
                findingRating: row["finding_rating"],
                status: row["status"]
            )
        }
    }
}
