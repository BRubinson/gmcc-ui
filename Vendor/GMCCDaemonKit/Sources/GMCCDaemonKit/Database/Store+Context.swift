import Foundation
import GRDB

// CONTEXT_ENSURE / CONTEXT_GET — the promoted ensure chain (mirrors
// detect_repo.sh lazy creation) plus create-time-only kbite seeding
// (mirrors inherit_kbite). The full kbite message family is prompt 4;
// this is only the seeding path CONTEXT_ENSURE requires.

extension Store {
    /// Upsert project → instance → session from repo identity, seeding kbite
    /// inheritance down the chain at CREATE time only. Idempotent; one
    /// transaction; returns all three uuids plus created flags.
    public func ensureContext(_ req: ContextEnsureRequest) throws -> ContextEnsureResponse {
        try dbQueue.write { db in
            let (projectUuid, createdProject) = try self.ensureProject(db, req.project)
            let (instanceUuid, createdInstance) = try self.ensureInstance(
                db, req.instance, projectUuid: projectUuid)
            let (sessionUuid, createdSession) = try self.ensureSession(
                db, req.session, instanceUuid: instanceUuid)
            return ContextEnsureResponse(
                projectUuid: projectUuid,
                instanceUuid: instanceUuid,
                sessionUuid: sessionUuid,
                createdProject: createdProject,
                createdInstance: createdInstance,
                createdSession: createdSession
            )
        }
    }

    /// Read-only resolution — never creates rows.
    public func getContext(_ req: ContextGetRequest) throws -> ContextGetResponse {
        try dbQueue.read { db in
            let projectUuid = try String.fetchOne(
                db, sql: "SELECT uuid FROM project WHERE code = ?", arguments: [req.projectCode])
            var instanceUuid: String?
            if let projectUuid {
                instanceUuid = try String.fetchOne(
                    db,
                    sql: "SELECT uuid FROM instance WHERE project_uuid = ? AND name = ?",
                    arguments: [projectUuid, req.instanceName])
            }
            var sessionUuid: String?
            if let instanceUuid {
                sessionUuid = try String.fetchOne(
                    db,
                    sql: "SELECT uuid FROM session WHERE instance_uuid = ? AND code = ?",
                    arguments: [instanceUuid, req.sessionCode])
            }
            var kbiteCodes: [String] = []
            if let sessionUuid {
                kbiteCodes = try String.fetchAll(db, sql: """
                    SELECT k.code FROM kbite k
                    JOIN session_active_kbite j ON j.kbite_uuid = k.uuid
                    WHERE j.session_uuid = ?
                    ORDER BY k.code
                    """, arguments: [sessionUuid])
            }
            return ContextGetResponse(
                projectUuid: projectUuid,
                instanceUuid: instanceUuid,
                sessionUuid: sessionUuid,
                kbiteCodes: kbiteCodes
            )
        }
    }

    // MARK: - Ensure chain (shared with addFileChange)

    func ensureProject(_ db: Database, _ ctx: ProjectContext) throws -> (uuid: String, created: Bool) {
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM project WHERE code = ?", arguments: [ctx.code]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "project", uuid: ctx.uuid, extra: [
            "git_repo_name": ctx.gitRepoName,
            "code": ctx.code,
            "name": ctx.name,
            "ckfs_relative_storage_path": ctx.ckfsRelativeStoragePath,
        ])
        try seedKbites(db, level: "project", ownerUuid: uuid, codes: ctx.kbiteCodes, parent: nil)
        try appendEvent(db, kind: .createProject, subjectUuid: uuid)
        return (uuid, true)
    }

    func ensureInstance(
        _ db: Database, _ ctx: InstanceContext, projectUuid: String
    ) throws -> (uuid: String, created: Bool) {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT uuid FROM instance WHERE project_uuid = ? AND name = ?",
            arguments: [projectUuid, ctx.name]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "instance", uuid: ctx.uuid, extra: [
            "project_uuid": projectUuid,
            "code": ctx.code,
            "name": ctx.name,
            "absolute_file_system_path": ctx.absoluteFileSystemPath,
            "ckfs_relative_storage_path": ctx.ckfsRelativeStoragePath,
        ])
        try seedKbites(
            db, level: "instance", ownerUuid: uuid, codes: ctx.kbiteCodes,
            parent: (level: "project", uuid: projectUuid))
        try appendEvent(db, kind: .createInstance, subjectUuid: uuid)
        return (uuid, true)
    }

    func ensureSession(
        _ db: Database, _ ctx: SessionContext, instanceUuid: String
    ) throws -> (uuid: String, created: Bool) {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT uuid FROM session WHERE instance_uuid = ? AND code = ?",
            arguments: [instanceUuid, ctx.code]
        ) {
            return (existing, false)
        }
        let uuid = try insertBase(db, table: "session", uuid: ctx.uuid, extra: [
            "instance_uuid": instanceUuid,
            "code": ctx.code,
            "name": ctx.name,
            "backstory": ctx.backstory,
            "goal": ctx.goal,
            "status": SessionStatus.active.rawValue,
            "ckfs_relative_storage_path": ctx.ckfsRelativeStoragePath,
        ])
        try seedKbites(
            db, level: "session", ownerUuid: uuid, codes: ctx.kbiteCodes,
            parent: (level: "instance", uuid: instanceUuid))
        try appendEvent(db, kind: .createSession, subjectUuid: uuid)
        return (uuid, true)
    }

    // MARK: - Kbite seeding (create-time-only, mirrors inherit_kbite)

    /// Upsert a kbite row by code, returning its uuid.
    func ensureKbite(_ db: Database, code: String) throws -> String {
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM kbite WHERE code = ?", arguments: [code]
        ) {
            return existing
        }
        return try insertBase(db, table: "kbite", extra: ["code": code])
    }

    /// Fill a newly created row's active-kbite junction: explicit codes from
    /// the context payload, plus a copy of the parent level's junction rows
    /// (create-time-only inheritance — existing rows are never re-seeded,
    /// exactly like detect_repo.sh's inherit_kbite).
    private func seedKbites(
        _ db: Database,
        level: String,
        ownerUuid: String,
        codes: [String]?,
        parent: (level: String, uuid: String)?
    ) throws {
        var kbiteUuids: Set<String> = []
        for code in codes ?? [] {
            kbiteUuids.insert(try ensureKbite(db, code: code))
        }
        if let parent {
            let inherited = try String.fetchAll(
                db,
                sql: "SELECT kbite_uuid FROM \(parent.level)_active_kbite WHERE \(parent.level)_uuid = ?",
                arguments: [parent.uuid])
            kbiteUuids.formUnion(inherited)
        }
        for kbiteUuid in kbiteUuids.sorted() {
            try insertBase(db, table: "\(level)_active_kbite", extra: [
                "\(level)_uuid": ownerUuid,
                "kbite_uuid": kbiteUuid,
            ])
        }
    }
}
