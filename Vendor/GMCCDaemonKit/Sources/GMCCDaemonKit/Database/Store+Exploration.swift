import Foundation
import GRDB

// EXPLORE_* — the db-native exploration report machine (replaces explore.md).
// exploring → complete, plus the complete → exploring revision edge: explore
// is the most re-run report (resume, team fallback), so re-runs update the
// same summary — db-native last-run-wins. Open is EXPLICIT-only: exploration
// runs while the prompt is still `draft`, so unlike clarify/arch there is no
// setPromptStatus create-on-enter slot and none is wired. Explore verbs NEVER
// touch prompt.status.
//
// finding_rating semantics (0 = absolute critical … 999 = always-false-
// positive tombstone; read threshold 100): NULL marks an unranked finding —
// the universal work-in-progress marker. COMPLETE refuses while any NULL
// remains; GETs always return NULL-rated rows in the full partition (they
// are the resume work-queue); the with-reports stub surfaces the count.
// overview is carried ONLY by COMPLETE — there is no earlier write path, so
// the narrative is structurally written after the ranked findings exist
// (primary-agent-only by shape, the clarifyFinalize precedent).

extension Store {

    // MARK: - Shared create-or-return

    /// Idempotent: returns the existing summary or creates one at `exploring`.
    /// Called ONLY by EXPLORE_OPEN — never by setPromptStatus (explicit-open
    /// only; prompt status has no exploration coupling).
    @discardableResult
    func ensureExplorationSummary(_ db: Database, promptUuid: String) throws -> (uuid: String, created: Bool) {
        guard try Row.fetchOne(
            db, sql: "SELECT 1 FROM prompt WHERE uuid = ?", arguments: [promptUuid]
        ) != nil else {
            throw StoreError.notFound(entity: "prompt", key: promptUuid)
        }
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM exploration_summary WHERE prompt_uuid = ?",
            arguments: [promptUuid]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "exploration_summary", extra: [
            "prompt_uuid": promptUuid,
            "status": ExplorationStatus.exploring.rawValue,
            "overview": "",
        ])
        try appendEvent(
            db, kind: .explorationChange, subjectUuid: uuid,
            payload: Store.jsonPayload(["action": "open", "prompt_uuid": promptUuid]))
        try touchSessionForPrompt(db, promptUuid: promptUuid)
        return (uuid, true)
    }

    // MARK: - Verbs

    public func exploreOpen(_ req: ExploreOpenRequest) throws -> ExploreSummaryResponse {
        try dbQueue.write { db in
            let (uuid, created) = try self.ensureExplorationSummary(db, promptUuid: req.promptUuid)
            guard let summary = try self.fetchExplorationSummary(db, uuid: uuid) else {
                throw StoreError.notFound(entity: "exploration_summary", key: uuid)
            }
            return ExploreSummaryResponse(summary: summary, created: created)
        }
    }

    /// Key files are a shared deduped set: a duplicate path is an idempotent
    /// upsert-ignore returning the existing row (the prompt_artifact
    /// precedent), never an error.
    public func exploreKeyFileAdd(_ req: ExploreKeyFileAddRequest) throws -> ExploreKeyFileAddResponse {
        try dbQueue.write { db in
            let summary = try self.requireExplorationSummary(
                db, uuid: req.summaryUuid, at: .exploring, verb: "key-file-add")
            let path = try Store.normalizeRepoRelativePath(
                req.filePath, repoRoot: try self.instanceRoot(db, promptUuid: summary.promptUuid))
            if let existing = try self.fetchExplorationKeyFiles(
                db, where: "exploration_summary_uuid = ? AND file_path = ?",
                arguments: [req.summaryUuid, path]
            ).first {
                return ExploreKeyFileAddResponse(keyFile: existing, created: false)
            }
            let uuid = try self.insertBase(db, table: "exploration_key_file", extra: [
                "exploration_summary_uuid": req.summaryUuid,
                "file_path": path,
            ])
            try self.appendEvent(
                db, kind: .explorationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "key_file_add", "file_path": path,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let row = try self.fetchExplorationKeyFiles(
                db, where: "uuid = ?", arguments: [uuid]
            ).first else {
                throw StoreError.notFound(entity: "exploration_key_file", key: uuid)
            }
            return ExploreKeyFileAddResponse(keyFile: row, created: true)
        }
    }

    public func exploreFindingAdd(_ req: ExploreFindingAddRequest) throws -> ExploreFindingRowResponse {
        try dbQueue.write { db in
            let summary = try self.requireExplorationSummary(
                db, uuid: req.summaryUuid, at: .exploring, verb: "finding-add")
            let (title, body, agentName) = try Store.validatedFindingText(
                title: req.title, body: req.body, agentName: req.agentName)
            try Store.validateRating(req.rating)
            let uuid = try self.insertBase(db, table: "exploration_finding", extra: [
                "exploration_summary_uuid": req.summaryUuid,
                "kind": req.kind.rawValue,
                "title": title,
                "body": body,
                "agent_name": agentName,
                "finding_rating": req.rating,
            ])
            try self.appendEvent(
                db, kind: .explorationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "finding_add", "kind": req.kind.rawValue,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let row = try self.fetchExplorationFindings(
                db, where: "uuid = ?", arguments: [uuid]
            ).first else {
                throw StoreError.notFound(entity: "exploration_finding", key: uuid)
            }
            return ExploreFindingRowResponse(finding: row)
        }
    }

    /// Batch rank — atomic all-or-nothing, deliberately version-less: the team
    /// re-ranker blind-overwrites ratings it never read (the specified
    /// semantic), and the single-writer DatabaseQueue serializes competing
    /// batches; row versions still bump via updateBase so stale holders of a
    /// FINDING version conflict normally elsewhere. Refused once complete —
    /// ranking a sealed set would shift the sub-100 contract; reopen first.
    public func exploreRank(_ req: ExploreRankRequest) throws -> ExploreRankResponse {
        try dbQueue.write { db in
            let summary = try self.requireExplorationSummary(
                db, uuid: req.summaryUuid, at: .exploring, verb: "rank")
            try self.applyRankBatch(
                db, table: "exploration_finding", parentColumn: "exploration_summary_uuid",
                summaryUuid: req.summaryUuid, ratings: req.ratings)
            let unranked = try self.unrankedCount(
                db, table: "exploration_finding", parentColumn: "exploration_summary_uuid",
                summaryUuid: req.summaryUuid)
            try self.appendEvent(
                db, kind: .explorationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload([
                    "action": "rank", "count": req.ratings.count,
                    "prompt_uuid": summary.promptUuid,
                ]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchExplorationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "exploration_summary", key: req.summaryUuid)
            }
            return ExploreRankResponse(
                summary: updated, updatedCount: req.ratings.count, unrankedCount: unranked)
        }
    }

    /// exploring → complete. Refuses while any finding is unranked; `overview`
    /// is carried only here (its ONLY write path).
    public func exploreComplete(_ req: ExploreCompleteRequest) throws -> ExploreSummaryResponse {
        try dbQueue.write { db in
            let summary = try self.requireExplorationSummary(
                db, uuid: req.summaryUuid, at: .exploring, verb: "complete")
            let unranked = try self.unrankedCount(
                db, table: "exploration_finding", parentColumn: "exploration_summary_uuid",
                summaryUuid: req.summaryUuid)
            guard unranked == 0 else {
                throw StoreError.invalidEntityTransition(
                    entity: "exploration", from: summary.status,
                    to: ExplorationStatus.complete.rawValue,
                    reason: "\(unranked) finding(s) unranked — run gm explore rank first")
            }
            let overview = try Store.validatedOverview(req.overview, entity: "exploration")
            try self.updateBase(
                db, table: "exploration_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion,
                set: ["status": ExplorationStatus.complete.rawValue, "overview": overview])
            try self.appendEvent(
                db, kind: .explorationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload(["action": "complete", "prompt_uuid": summary.promptUuid]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchExplorationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "exploration_summary", key: req.summaryUuid)
            }
            return ExploreSummaryResponse(summary: updated)
        }
    }

    /// complete → exploring: the revision edge. Preserves everything —
    /// findings, ratings, key files, overview (nulling would make a mistaken
    /// reopen unrecoverable in an append-only db); the next COMPLETE must
    /// re-carry the overview, so staleness cannot survive a re-seal.
    public func exploreReopen(_ req: ExploreReopenRequest) throws -> ExploreSummaryResponse {
        try dbQueue.write { db in
            guard let summary = try self.fetchExplorationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "exploration_summary", key: req.summaryUuid)
            }
            guard summary.explorationStatus == .complete else {
                throw StoreError.invalidEntityTransition(
                    entity: "exploration", from: summary.status,
                    to: ExplorationStatus.exploring.rawValue,
                    reason: "reopen runs from complete — this summary is \(summary.status)")
            }
            try self.updateBase(
                db, table: "exploration_summary", uuid: req.summaryUuid,
                expectedVersion: req.expectedVersion,
                set: ["status": ExplorationStatus.exploring.rawValue])
            try self.appendEvent(
                db, kind: .explorationChange, subjectUuid: req.summaryUuid,
                payload: Store.jsonPayload(["action": "reopen", "prompt_uuid": summary.promptUuid]))
            try self.touchSessionForPrompt(db, promptUuid: summary.promptUuid)
            guard let updated = try self.fetchExplorationSummary(db, uuid: req.summaryUuid) else {
                throw StoreError.notFound(entity: "exploration_summary", key: req.summaryUuid)
            }
            return ExploreSummaryResponse(summary: updated)
        }
    }

    public func exploreGet(_ req: ExploreGetRequest) throws -> ExploreGetResponse {
        try dbQueue.read { db in
            guard let promptCreatedAt = try String.fetchOne(
                db, sql: "SELECT created_at FROM prompt WHERE uuid = ?", arguments: [req.promptUuid]
            ) else {
                throw StoreError.notFound(entity: "prompt", key: req.promptUuid)
            }
            guard let summary = try self.fetchExplorationSummary(db, byPrompt: req.promptUuid) else {
                throw StoreError.summaryAbsent(
                    entity: "exploration", promptUuid: req.promptUuid,
                    promptIsLegacy: try self.isLegacyPrompt(db, createdAt: promptCreatedAt))
            }
            let keyFiles = try self.fetchExplorationKeyFiles(
                db, where: "exploration_summary_uuid = ?", arguments: [summary.uuid])
            let window = try Store.ratingWindow(full: req.full, min: req.ratingMin, max: req.ratingMax)
            let all = try self.fetchExplorationFindings(
                db, where: "exploration_summary_uuid = ?", arguments: [summary.uuid])
            var full: [ExplorationFindingRow] = []
            var stubs: [ExplorationFindingStub] = []
            for row in all {
                if Store.ratingInWindow(row.findingRating, window: window) {
                    full.append(row)
                } else {
                    stubs.append(ExplorationFindingStub(
                        uuid: row.uuid, kind: row.kind, title: row.title,
                        findingRating: row.findingRating, agentName: row.agentName))
                }
            }
            return ExploreGetResponse(
                summary: summary, keyFiles: keyFiles, findings: full, findingStubs: stubs)
        }
    }

    // MARK: - Shared rank/validation helpers (used by Store+Review too)

    /// The GET rating window. full ⇒ unbounded; otherwise [min ?? 0,
    /// max ?? threshold-1]. NULL (unranked) rows are ALWAYS in-window — they
    /// exist only pre-complete and are the ranking agent's work queue; no flag
    /// combination may hide them.
    struct RatingWindow {
        let low: Int
        let high: Int
    }

    /// Validated server-side — the CLI checks too, but vendored wire clients
    /// (GMVibes) reach this without it, and a silently inverted window would
    /// hide findings. `full` excludes bounds; a lone ratingMin widens the
    /// window upward to 999 (never inverts against the default max).
    static func ratingWindow(full: Bool, min: Int?, max: Int?) throws -> RatingWindow? {
        if full {
            guard min == nil, max == nil else {
                throw StoreError.badRequest(detail: "full excludes rating_min/rating_max")
            }
            return nil
        }
        for bound in [min, max] {
            if let bound, !(0...999).contains(bound) {
                throw StoreError.badRequest(detail: "rating bounds must be 0-999 (got \(bound))")
            }
        }
        let low = min ?? 0
        let high = max ?? (min != nil ? 999 : Store.findingReadThreshold - 1)
        guard low <= high else {
            throw StoreError.badRequest(detail: "rating_min (\(low)) exceeds rating_max (\(high))")
        }
        return RatingWindow(low: low, high: high)
    }

    static func ratingInWindow(_ rating: Int?, window: RatingWindow?) -> Bool {
        guard let window else { return true }
        guard let rating else { return true }
        return rating >= window.low && rating <= window.high
    }

    static func validateRating(_ rating: Int?) throws {
        if let rating, !(0...999).contains(rating) {
            throw StoreError.badRequest(detail: "finding_rating must be 0–999 (got \(rating))")
        }
    }

    static func validatedFindingText(
        title: String, body: String, agentName: String
    ) throws -> (title: String, body: String, agentName: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.badRequest(detail: "finding title is empty") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.badRequest(detail: "finding body is empty")
        }
        guard !agentName.isEmpty else { throw StoreError.badRequest(detail: "agent_name is empty") }
        guard body.utf8.count <= Store.maxNarrativeBytes else {
            throw StoreError.badRequest(
                detail: "finding body exceeds \(Store.maxNarrativeBytes / (1024 * 1024)) MB")
        }
        return (title, body, agentName)
    }

    static func validatedOverview(_ raw: String, entity: String) throws -> String {
        let overview = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else {
            throw StoreError.badRequest(detail: "\(entity) overview is empty")
        }
        guard overview.utf8.count <= Store.maxNarrativeBytes else {
            throw StoreError.badRequest(
                detail: "\(entity) overview exceeds \(Store.maxNarrativeBytes / (1024 * 1024)) MB")
        }
        return overview
    }

    /// Validate then apply one rank batch inside the caller's transaction.
    /// The WHOLE batch validates before any write: non-empty, no duplicate
    /// uuids, every rating 0–999, every finding belonging to this summary
    /// (cross-summary smuggling check) — one bad pair rejects everything.
    /// Rows update via updateBase at their in-transaction current versions
    /// (the clarifyFinalize prompt-version idiom).
    func applyRankBatch(
        _ db: Database,
        table: String,
        parentColumn: String,
        summaryUuid: String,
        ratings: [FindingRating]
    ) throws {
        guard !ratings.isEmpty else {
            throw StoreError.badRequest(detail: "rank batch is empty")
        }
        var seen = Set<String>()
        for pair in ratings {
            guard seen.insert(pair.findingUuid).inserted else {
                throw StoreError.badRequest(detail: "duplicate finding in rank batch: \(pair.findingUuid)")
            }
            guard (0...999).contains(pair.rating) else {
                throw StoreError.badRequest(
                    detail: "finding_rating must be 0–999 (got \(pair.rating) for \(pair.findingUuid))")
            }
            guard try Row.fetchOne(
                db, sql: "SELECT 1 FROM \(table) WHERE uuid = ? AND \(parentColumn) = ?",
                arguments: [pair.findingUuid, summaryUuid]
            ) != nil else {
                throw StoreError.badRequest(
                    detail: "finding \(pair.findingUuid) does not belong to summary \(summaryUuid)")
            }
        }
        for pair in ratings {
            guard let version = try Int64.fetchOne(
                db, sql: "SELECT version FROM \(table) WHERE uuid = ?", arguments: [pair.findingUuid]
            ) else {
                throw StoreError.notFound(entity: table, key: pair.findingUuid)
            }
            try updateBase(
                db, table: table, uuid: pair.findingUuid,
                expectedVersion: version, set: ["finding_rating": pair.rating])
        }
    }

    func unrankedCount(
        _ db: Database, table: String, parentColumn: String, summaryUuid: String
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(table) WHERE \(parentColumn) = ? AND finding_rating IS NULL",
            arguments: [summaryUuid]) ?? 0
    }

    // MARK: - Transition + fetch helpers

    private func requireExplorationSummary(
        _ db: Database, uuid: String, at required: ExplorationStatus, verb: String
    ) throws -> ExplorationSummaryRow {
        guard let summary = try fetchExplorationSummary(db, uuid: uuid) else {
            throw StoreError.notFound(entity: "exploration_summary", key: uuid)
        }
        guard summary.explorationStatus == required else {
            throw StoreError.invalidEntityTransition(
                entity: "exploration", from: summary.status, to: verb,
                reason: "\(verb) is legal only while \(required.rawValue)")
        }
        return summary
    }

    func fetchExplorationSummary(_ db: Database, uuid: String) throws -> ExplorationSummaryRow? {
        try fetchExplorationSummary(db, where: "uuid = ?", key: uuid)
    }

    func fetchExplorationSummary(_ db: Database, byPrompt promptUuid: String) throws -> ExplorationSummaryRow? {
        try fetchExplorationSummary(db, where: "prompt_uuid = ?", key: promptUuid)
    }

    private func fetchExplorationSummary(
        _ db: Database, where condition: String, key: String
    ) throws -> ExplorationSummaryRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT uuid, version, prompt_uuid, status, overview, created_at, updated_at
                FROM exploration_summary WHERE \(condition)
                """,
            arguments: [key]
        ) else { return nil }
        return ExplorationSummaryRow(
            uuid: row["uuid"],
            version: row["version"],
            promptUuid: row["prompt_uuid"],
            status: row["status"],
            overview: row["overview"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func fetchExplorationKeyFiles(
        _ db: Database, where condition: String, arguments: StatementArguments
    ) throws -> [ExplorationKeyFileRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, version, exploration_summary_uuid, file_path
                FROM exploration_key_file WHERE \(condition) ORDER BY file_path
                """,
            arguments: arguments
        ).map { row in
            ExplorationKeyFileRow(
                uuid: row["uuid"],
                version: row["version"],
                explorationSummaryUuid: row["exploration_summary_uuid"],
                filePath: row["file_path"]
            )
        }
    }

    /// Explicit ordering: unranked (NULL) rows sort FIRST — the resume
    /// work-queue can't be missed — then by rating ascending, then id.
    private func fetchExplorationFindings(
        _ db: Database, where condition: String, arguments: StatementArguments
    ) throws -> [ExplorationFindingRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT uuid, version, exploration_summary_uuid, kind, title, body,
                       agent_name, finding_rating
                FROM exploration_finding WHERE \(condition)
                ORDER BY finding_rating IS NOT NULL, finding_rating, id
                """,
            arguments: arguments
        ).map { row in
            ExplorationFindingRow(
                uuid: row["uuid"],
                version: row["version"],
                explorationSummaryUuid: row["exploration_summary_uuid"],
                kind: row["kind"],
                title: row["title"],
                body: row["body"],
                agentName: row["agent_name"],
                findingRating: row["finding_rating"]
            )
        }
    }
}
