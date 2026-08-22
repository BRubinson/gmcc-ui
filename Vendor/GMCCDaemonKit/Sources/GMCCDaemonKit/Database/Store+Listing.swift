import Foundation
import GRDB

// PROJECT_LIST / INSTANCE_LIST / SESSION_LIST — read-only enumeration, the
// Landing browse surface. Parent uuids are optional filters: nil lists the
// whole level; a supplied-but-unknown parent is a typed NOT_FOUND, never a
// silent empty list. No daemon_event rows (reads only).

extension Store {
    public func listProjects() throws -> ProjectListResponse {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT uuid, version, git_repo_name, code, name,
                       ckfs_relative_storage_path, created_at, updated_at
                FROM project ORDER BY code
                """)
            return ProjectListResponse(projects: rows.map { row in
                ProjectRow(
                    uuid: row["uuid"],
                    version: row["version"],
                    gitRepoName: row["git_repo_name"],
                    code: row["code"],
                    name: row["name"],
                    ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            })
        }
    }

    public func listInstances(_ req: InstanceListRequest) throws -> InstanceListResponse {
        try dbQueue.read { db in
            var sql = """
                SELECT uuid, version, project_uuid, code, name,
                       absolute_file_system_path, ckfs_relative_storage_path,
                       created_at, updated_at
                FROM instance
                """
            var arguments: StatementArguments = []
            if let projectUuid = req.projectUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM project WHERE uuid = ?", arguments: [projectUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "project", key: projectUuid)
                }
                sql += " WHERE project_uuid = ?"
                arguments = [projectUuid]
            }
            sql += " ORDER BY code, name"
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return InstanceListResponse(instances: rows.map { row in
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
            })
        }
    }

    public func listSessions(_ req: SessionListRequest) throws -> SessionListResponse {
        try dbQueue.read { db in
            // Item 1: last_activity_at = latest of the session's own
            // updated_at, its prompts' updated_at, and its file changes'
            // created_at — one query, correlated scalar MAXes (a childless
            // session still sorts by its own recency). ISO-8601 seconds-Z
            // strings compare lexicographically. Retires GMVibes' client-side
            // fold over an unfiltered FILE_CHANGE_LIST.
            var sql = """
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
                """
            var arguments: StatementArguments = []
            if let instanceUuid = req.instanceUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM instance WHERE uuid = ?", arguments: [instanceUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "instance", key: instanceUuid)
                }
                sql += " WHERE s.instance_uuid = ?"
                arguments = [instanceUuid]
            }
            sql += " ORDER BY s.code"
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return SessionListResponse(sessions: rows.map { self.sessionStub(from: $0) })
        }
    }

    /// Shared SessionStub materializer for listSessions and
    /// INSTANCE_CURRENT_SESSION (both select the same column list).
    func sessionStub(from row: Row) -> SessionStub {
        SessionStub(
            uuid: row["uuid"],
            version: row["version"],
            instanceUuid: row["instance_uuid"],
            code: row["code"],
            name: row["name"],
            ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            lastActivityAt: row["last_activity_at"]
        )
    }
}
