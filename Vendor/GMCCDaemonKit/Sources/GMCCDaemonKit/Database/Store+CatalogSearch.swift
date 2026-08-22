import Foundation
import GRDB

// CATALOG_SEARCH — tokenized OR name/code search across instances + sessions,
// the GMVibes per-project search bar. Read-only; no daemon_event rows. Matching
// mirrors GMVibes' SearchQuery.matchesAny: split on whitespace, a row matches
// if ANY token is a case-insensitive literal substring of its name OR code
// (LIKE wildcards in tokens are escaped). An instance match pulls in ALL its
// sessions (ancestor-match ⇒ whole subtree); every returned session's parent
// instance rides along so the client can group without a second call.

extension Store {
    public func searchCatalog(_ req: CatalogSearchRequest) throws -> CatalogSearchResponse {
        let tokens = req.query
            .split(whereSeparator: \.isWhitespace)
            .map { Self.escapeLikeToken(String($0)) }
        guard !tokens.isEmpty else {
            throw StoreError.badRequest(detail: "search query is empty")
        }
        let limit = min(max(req.limit ?? 200, 1), 1_000)

        // OR across tokens × (name, code) for one table alias; every token is a
        // bound `%token%` parameter — never interpolated into the SQL.
        func matchPredicate(alias: String, into arguments: inout [any DatabaseValueConvertible]) -> String {
            let clauses = tokens.map { token -> String in
                arguments.append("%\(token)%")
                arguments.append("%\(token)%")
                return "\(alias).name LIKE ? ESCAPE '\\' OR \(alias).code LIKE ? ESCAPE '\\'"
            }
            return "(" + clauses.joined(separator: " OR ") + ")"
        }

        return try dbQueue.read { db in
            if let projectUuid = req.projectUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM project WHERE uuid = ?", arguments: [projectUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "project", key: projectUuid)
                }
            }

            // Sessions: direct matches plus the whole subtree of directly-matched
            // instances, in one query (project scope rides the join — session has
            // no project_uuid column).
            var sessionSql = """
                SELECT s.uuid, s.version, s.instance_uuid, s.code, s.name,
                       s.ckfs_relative_storage_path, s.created_at, s.updated_at,
                       MAX(
                           s.updated_at,
                           COALESCE((SELECT MAX(p.updated_at) FROM prompt p
                                     WHERE p.session_uuid = s.uuid), ''),
                           COALESCE((SELECT MAX(fc.created_at) FROM file_change fc
                                     WHERE fc.session_uuid = s.uuid), '')
                       ) AS last_activity_at
                FROM session s
                JOIN instance i ON i.uuid = s.instance_uuid
                """
            var sessionArguments: [any DatabaseValueConvertible] = []
            var sessionConditions: [String] = []
            if let projectUuid = req.projectUuid {
                sessionConditions.append("i.project_uuid = ?")
                sessionArguments.append(projectUuid)
            }
            let sessionMatch = matchPredicate(alias: "s", into: &sessionArguments)
            let instanceSubtreeMatch = matchPredicate(alias: "i", into: &sessionArguments)
            sessionConditions.append("(\(sessionMatch) OR \(instanceSubtreeMatch))")
            sessionSql += " WHERE " + sessionConditions.joined(separator: " AND ")
            sessionSql += " LIMIT \(limit)"
            let sessions = try Row.fetchAll(
                db, sql: sessionSql, arguments: StatementArguments(sessionArguments)
            ).map { self.sessionStub(from: $0) }

            // Instances: the parent closure of every returned session, plus
            // instances that matched directly (kept even when they contribute no
            // sessions — e.g. an empty instance whose name matched).
            var instanceSql = """
                SELECT i.uuid, i.version, i.project_uuid, i.code, i.name,
                       i.absolute_file_system_path, i.ckfs_relative_storage_path,
                       i.created_at, i.updated_at
                FROM instance i
                """
            var instanceArguments: [any DatabaseValueConvertible] = []
            var instanceConditions: [String] = []
            if let projectUuid = req.projectUuid {
                instanceConditions.append("i.project_uuid = ?")
                instanceArguments.append(projectUuid)
            }
            let parentUuids = Array(Set(sessions.map(\.instanceUuid)))
            let instanceMatch = matchPredicate(alias: "i", into: &instanceArguments)
            if parentUuids.isEmpty {
                instanceConditions.append(instanceMatch)
            } else {
                // Match clause first: its arguments were appended before the
                // parent uuids, and bind order must follow placeholder order.
                let placeholders = Array(repeating: "?", count: parentUuids.count).joined(separator: ", ")
                instanceConditions.append("(\(instanceMatch) OR i.uuid IN (\(placeholders)))")
                instanceArguments.append(contentsOf: parentUuids)
            }
            instanceSql += " WHERE " + instanceConditions.joined(separator: " AND ")
            let instances = try Row.fetchAll(
                db, sql: instanceSql, arguments: StatementArguments(instanceArguments)
            ).map { row in
                InstanceRow(
                    uuid: row["uuid"],
                    version: row["version"],
                    projectUuid: row["project_uuid"],
                    code: row["code"],
                    name: row["name"],
                    absoluteFileSystemPath: row["absolute_file_system_path"],
                    ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            }

            return CatalogSearchResponse(instances: instances, sessions: sessions)
        }
    }

    /// Escape LIKE wildcards so tokens match as literal substrings (the escape
    /// char itself first, so escaped wildcards don't get double-escaped).
    private static func escapeLikeToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
