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
            var sql = """
                SELECT uuid, version, instance_uuid, code, name, status,
                       ckfs_relative_storage_path, created_at, updated_at
                FROM session
                """
            var arguments: StatementArguments = []
            if let instanceUuid = req.instanceUuid {
                guard try Row.fetchOne(
                    db, sql: "SELECT 1 FROM instance WHERE uuid = ?", arguments: [instanceUuid]
                ) != nil else {
                    throw StoreError.notFound(entity: "instance", key: instanceUuid)
                }
                sql += " WHERE instance_uuid = ?"
                arguments = [instanceUuid]
            }
            sql += " ORDER BY code"
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return SessionListResponse(sessions: rows.map { row in
                SessionStub(
                    uuid: row["uuid"],
                    version: row["version"],
                    instanceUuid: row["instance_uuid"],
                    code: row["code"],
                    name: row["name"],
                    status: row["status"],
                    ckfsRelativeStoragePath: row["ckfs_relative_storage_path"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            })
        }
    }
}
