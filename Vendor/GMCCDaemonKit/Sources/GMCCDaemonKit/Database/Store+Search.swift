import Foundation
import GRDB

// SEARCH — FTS5 full-text search over prompt/clarification/architecture/
// exploration/review text (the B3 counterpart of KBITE_SEARCH). Eleven
// external-content mirrors (six from m0003, five from m0004), one SELECT arm
// per requested kind UNIONed, bm25 column-weighted ranking, ranked stubs with
// prompt lineage — never full content (the excerpt is a bounded FTS5
// snippet).
//
// Scores: SQLite's bm25() returns a NEGATIVE number and the ORDER BY is
// ascending, so more-negative = better — a kind-bias multiplier < 1 moves a
// score toward zero, i.e. DEMOTES that kind. Scores stay comparable only
// WITHIN a kind; the response exposes kind and score so the caller sees the
// mix rather than being sold a unified relevance number.

extension Store {
    public func search(_ req: SearchRequest) throws -> SearchResponse {
        // Deliberate divergence from the kbite precedent: a whitespace-only
        // query is BAD_REQUEST rather than an empty hit list — a silent empty
        // result for a nonsense query is the antipattern the listing
        // contract rejects.
        guard let pattern = FTS5Pattern(matchingAllTokensIn: req.query) else {
            throw StoreError.badRequest(detail: "search query has no searchable tokens")
        }
        return try dbQueue.read { db in
            if let sessionUuid = req.sessionUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM session WHERE uuid = ?", arguments: [sessionUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "session", key: sessionUuid)
                }
            }
            let limit = min(max(req.limit ?? 50, 1), 500)
            let kinds = (req.kinds?.isEmpty ?? true) ? SearchKind.allCases : req.kinds!
            var arms: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            let scope = req.sessionUuid == nil ? "" : " AND p.session_uuid = ?"
            for kind in kinds {
                arms.append(Self.searchArm(for: kind, scope: scope))
                arguments.append(pattern)
                if let sessionUuid = req.sessionUuid { arguments.append(sessionUuid) }
            }
            let sql = arms.joined(separator: "\nUNION ALL\n")
                + "\nORDER BY score LIMIT \(limit)"
            return SearchResponse(hits: try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(arguments)
            ).map { row in
                SearchHit(
                    kind: row["kind"],
                    subjectUuid: row["subject_uuid"],
                    promptUuid: row["prompt_uuid"],
                    promptSeq: row["prompt_seq"],
                    promptName: row["prompt_name"],
                    promptStatus: row["prompt_status"],
                    sessionUuid: row["session_uuid"],
                    sessionCode: row["session_code"],
                    title: row["title"],
                    excerpt: row["excerpt"],
                    score: row["score"]
                )
            })
        }
    }

    /// One UNION arm per kind. Every arm produces the identical column list;
    /// lineage joins run child → summary → prompt → session. Weights (higher
    /// = stronger contribution) and the per-kind bias are fixed here —
    /// keeping a 2 MB change_code hit from outranking a direct goal match.
    private static func searchArm(for kind: SearchKind, scope: String) -> String {
        let common = """
            p.uuid AS prompt_uuid, p.seq AS prompt_seq, p.name AS prompt_name,
            p.status AS prompt_status, s.uuid AS session_uuid, s.code AS session_code
            """
        switch kind {
        case .prompt:
            return """
                SELECT 'prompt' AS kind, p.uuid AS subject_uuid, \(common),
                       p.name AS title,
                       snippet(prompt_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(prompt_fts, 10.0, 6.0, 3.0, 1.0) * 1.0 AS score
                FROM prompt_fts fts
                JOIN prompt p ON p.id = fts.rowid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE prompt_fts MATCH ?\(scope)
                """
        case .clarificationSummary:
            return """
                SELECT 'clarification_summary' AS kind, cs.uuid AS subject_uuid, \(common),
                       'clarification summary' AS title,
                       snippet(clarification_summary_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(clarification_summary_fts, 8.0, 4.0, 1.0) * 1.0 AS score
                FROM clarification_summary_fts fts
                JOIN clarification_summary cs ON cs.id = fts.rowid
                JOIN prompt p ON p.uuid = cs.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE clarification_summary_fts MATCH ?\(scope)
                """
        case .clarification:
            return """
                SELECT 'clarification' AS kind, c.uuid AS subject_uuid, \(common),
                       c.question AS title,
                       snippet(clarification_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(clarification_fts, 6.0, 4.0) * 0.85 AS score
                FROM clarification_fts fts
                JOIN clarification c ON c.id = fts.rowid
                JOIN clarification_summary cs ON cs.uuid = c.clarification_summary_uuid
                JOIN prompt p ON p.uuid = cs.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE clarification_fts MATCH ?\(scope)
                """
        case .architectureSummary:
            return """
                SELECT 'architecture_summary' AS kind, a.uuid AS subject_uuid, \(common),
                       'architecture summary' AS title,
                       snippet(architecture_summary_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(architecture_summary_fts, 5.0) * 0.85 AS score
                FROM architecture_summary_fts fts
                JOIN architecture_summary a ON a.id = fts.rowid
                JOIN prompt p ON p.uuid = a.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE architecture_summary_fts MATCH ?\(scope)
                """
        case .architectureGeneralChange:
            return """
                SELECT 'architecture_general_change' AS kind, gc.uuid AS subject_uuid, \(common),
                       gc.file_path AS title,
                       snippet(architecture_general_change_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(architecture_general_change_fts, 8.0, 5.0, 1.0) * 0.7 AS score
                FROM architecture_general_change_fts fts
                JOIN architecture_general_change gc ON gc.id = fts.rowid
                JOIN architecture_summary a ON a.uuid = gc.architecture_summary_uuid
                JOIN prompt p ON p.uuid = a.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE architecture_general_change_fts MATCH ?\(scope)
                """
        case .architecturePersistenceChange:
            return """
                SELECT 'architecture_persistence_change' AS kind, pc.uuid AS subject_uuid, \(common),
                       pc.file_path AS title,
                       snippet(architecture_persistence_change_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(architecture_persistence_change_fts, 8.0, 8.0, 5.0) * 0.7 AS score
                FROM architecture_persistence_change_fts fts
                JOIN architecture_persistence_change pc ON pc.id = fts.rowid
                JOIN architecture_summary a ON a.uuid = pc.architecture_summary_uuid
                JOIN prompt p ON p.uuid = a.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE architecture_persistence_change_fts MATCH ?\(scope)
                """
        case .explorationSummary:
            return """
                SELECT 'exploration_summary' AS kind, es.uuid AS subject_uuid, \(common),
                       'exploration overview' AS title,
                       snippet(exploration_summary_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(exploration_summary_fts, 5.0) * 0.85 AS score
                FROM exploration_summary_fts fts
                JOIN exploration_summary es ON es.id = fts.rowid
                JOIN prompt p ON p.uuid = es.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE exploration_summary_fts MATCH ?\(scope)
                """
        case .explorationKeyFile:
            return """
                SELECT 'exploration_key_file' AS kind, kf.uuid AS subject_uuid, \(common),
                       kf.file_path AS title,
                       snippet(exploration_key_file_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(exploration_key_file_fts, 5.0) * 0.7 AS score
                FROM exploration_key_file_fts fts
                JOIN exploration_key_file kf ON kf.id = fts.rowid
                JOIN exploration_summary es ON es.uuid = kf.exploration_summary_uuid
                JOIN prompt p ON p.uuid = es.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE exploration_key_file_fts MATCH ?\(scope)
                """
        case .explorationFinding:
            return """
                SELECT 'exploration_finding' AS kind, ef.uuid AS subject_uuid, \(common),
                       ef.title AS title,
                       snippet(exploration_finding_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(exploration_finding_fts, 6.0, 4.0) * 0.7 AS score
                FROM exploration_finding_fts fts
                JOIN exploration_finding ef ON ef.id = fts.rowid
                JOIN exploration_summary es ON es.uuid = ef.exploration_summary_uuid
                JOIN prompt p ON p.uuid = es.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE exploration_finding_fts MATCH ?\(scope)
                """
        case .reviewSummary:
            return """
                SELECT 'review_summary' AS kind, rs.uuid AS subject_uuid, \(common),
                       'review overview' AS title,
                       snippet(review_summary_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(review_summary_fts, 5.0) * 0.85 AS score
                FROM review_summary_fts fts
                JOIN review_summary rs ON rs.id = fts.rowid
                JOIN prompt p ON p.uuid = rs.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE review_summary_fts MATCH ?\(scope)
                """
        case .reviewFinding:
            return """
                SELECT 'review_finding' AS kind, rf.uuid AS subject_uuid, \(common),
                       rf.title AS title,
                       snippet(review_finding_fts, -1, '', '', '…', 24) AS excerpt,
                       bm25(review_finding_fts, 6.0, 4.0, 1.0) * 0.7 AS score
                FROM review_finding_fts fts
                JOIN review_finding rf ON rf.id = fts.rowid
                JOIN review_summary rs ON rs.uuid = rf.review_summary_uuid
                JOIN prompt p ON p.uuid = rs.prompt_uuid
                JOIN session s ON s.uuid = p.session_uuid
                WHERE review_finding_fts MATCH ?\(scope)
                """
        }
    }
}
