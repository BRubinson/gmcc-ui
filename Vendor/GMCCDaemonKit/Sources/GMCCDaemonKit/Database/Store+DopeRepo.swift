import Foundation
import GRDB

/// The three whole-tree repo verbs, each a four-phase orchestration:
///
///   1. `dbQueue.read`  — resolve scope, instance root, tree, revision;
///   2. pure            — projection + validation, no db, no fs;
///   3. filesystem      — sandbox read or atomic write, NO db lock held
///                        (Server's serial dispatch queue means no other
///                        client's commit can interleave with phase 3);
///   4. `dbQueue.write` — ingest's tree replace, or the audit event alone.
///
/// Filesystem work never enters a db transaction — the Store+Backup /
/// digestKbite rule, load-bearing here because these verbs write into a
/// user's repo.
extension Store {

    // MARK: - read-repo

    public func dopeReadRepo(_ req: DopeReadRepoRequest) throws -> DopeReadRepoResponse {
        // Phase 1 — resolve the root (and the db revision when a scope is
        // named).
        let root: String
        var dbRevision: Int64?
        switch (req.scopeUuid, req.dirPath) {
        case (let scopeUuid?, nil):
            (root, dbRevision) = try dbQueue.read { db in
                guard let scope = try self.fetchDopeScope(db, uuid: scopeUuid) else {
                    throw StoreError.notFound(entity: "dope_scope", key: scopeUuid)
                }
                return (try self.instanceRoot(db, sessionUuid: scope.sessionUuid),
                        scope.revision)
            }
        case (nil, let dirPath?):
            root = dirPath
        default:
            throw StoreError.badRequest(
                detail: "read-repo needs exactly one of --scope-uuid or --dir-path")
        }

        // Phase 3 — read (no phase-2 work on the way in; validation follows
        // the parse).
        let sandbox: DopeRepoSandbox
        let repo: DopeRepoSandbox.RepoBundle
        do {
            sandbox = try DopeRepoSandbox.resolve(instanceRoot: root)
            repo = try sandbox.readBundle()
        } catch let error as DopeRepoSandbox.SandboxError {
            throw StoreError.badRequest(detail: error.description)
        }

        // Phase 2 (outbound) — validate; a broken tree is still returned to
        // the caller as data plus warnings? No: read-repo's contract is
        // parse + validate, so validation failures are loud.
        do {
            try DopeValidator.validate(repo.bundle)
        } catch let error as DopeValidator.BundleError {
            throw StoreError.badRequest(detail: error.description)
        }

        let onDisk = repo.bundle.main.version
        return DopeReadRepoResponse(
            bundle: repo.bundle,
            onDiskRevision: onDisk,
            dbRevision: dbRevision,
            drift: dbRevision.map { $0 != onDisk },
            warnings: repo.warnings)
    }

    // MARK: - write-repo

    public func dopeWriteRepo(_ req: DopeWriteRepoRequest) throws -> DopeWriteRepoResponse {
        // Phase 1 — scope + root + full tree.
        let (scope, root, tree) = try dbQueue.read { db -> (DopeScopeRow, String, DopeScopeTree) in
            guard let scope = try self.fetchDopeScope(db, uuid: req.scopeUuid) else {
                throw StoreError.notFound(entity: "dope_scope", key: req.scopeUuid)
            }
            let root = try self.instanceRoot(db, sessionUuid: scope.sessionUuid)
            let tree = try self.fetchDopeTree(db, scope: scope)
            return (scope, root, tree)
        }

        // Phase 2 — project.
        let bundle = DopeProjection.documents(from: tree)

        // Phase 3 — gate + atomic write, no lock held.
        let sandbox: DopeRepoSandbox
        let result: DopeRepoSandbox.WriteResult
        do {
            sandbox = try DopeRepoSandbox.resolve(instanceRoot: root)
            if let onDisk = sandbox.peekRevision(), onDisk > scope.revision, req.force != true {
                throw StoreError.revisionConflict(
                    scopeUuid: scope.uuid, expected: onDisk, actual: scope.revision)
            }
            result = try sandbox.writeAtomically(bundle)
        } catch let error as DopeRepoSandbox.SandboxError {
            throw StoreError.badRequest(detail: error.description)
        }

        // Phase 4 — audit event only; write-repo is a projection and does
        // NOT bump revision (that is what makes a repeat run idempotent).
        try dbQueue.write { db in
            var payload: [String: Any] = [
                "action": "write_repo",
                "scope_uuid": scope.uuid,
                "session_uuid": scope.sessionUuid,
                "revision": Int(scope.revision),
                "files_written": result.written,
            ]
            if req.force == true { payload["forced"] = true }
            if !result.pruned.isEmpty { payload["files_pruned"] = result.pruned }
            try self.appendEvent(db, kind: .dopeChange, subjectUuid: scope.uuid,
                                 payload: Store.jsonPayload(payload))
            try self.touchSession(db, uuid: scope.sessionUuid)
        }
        return DopeWriteRepoResponse(
            dopeRoot: sandbox.dopeRoot.path,
            filesWritten: result.written,
            filesPruned: result.pruned,
            revision: scope.revision)
    }

    // MARK: - ingest

    public func dopeIngest(_ req: DopeIngestRequest) throws -> DopeIngestResponse {
        // Phase 1 — scope + root.
        let (scopeBefore, ownRoot) = try dbQueue.read { db -> (DopeScopeRow, String) in
            guard let scope = try self.fetchDopeScope(db, uuid: req.scopeUuid) else {
                throw StoreError.notFound(entity: "dope_scope", key: req.scopeUuid)
            }
            return (scope, try self.instanceRoot(db, sessionUuid: scope.sessionUuid))
        }

        // Phase 3 — read the files (before the write transaction opens).
        let bundle: DopeDocumentBundle
        do {
            let sandbox = try DopeRepoSandbox.resolve(instanceRoot: req.dirPath ?? ownRoot)
            bundle = try sandbox.readBundle().bundle
        } catch let error as DopeRepoSandbox.SandboxError {
            throw StoreError.badRequest(detail: error.description)
        }

        // Phase 2 — validate the whole tree before touching a row.
        do {
            try DopeValidator.validate(bundle)
        } catch let error as DopeValidator.BundleError {
            throw StoreError.badRequest(detail: error.description)
        }

        // Phase 4 — one transaction: gate revision == file.version - 1
        // exactly (single guarded UPDATE, changesCount-discriminated per the
        // updateBase idiom), ordered wipe, dependency-ordered re-insert.
        // Every child uuid changes — the locked no-smart-diff consequence.
        //
        // The file is the whole truth, so main.doped.json's scope
        // name/description are APPLIED to the row (a hand-edit must never be
        // silently reverted by the next write-repo). The row's optimistic
        // lock `version` bumps ONLY when those fields actually change — SET
        // right-hand sides read the OLD row in SQLite — so a pure tree
        // ingest leaves it alone, per bumpScopeRevision's split-counter
        // invariant. The scope CODE is identity, never ingested.
        guard bundle.main.scope.code == scopeBefore.code else {
            throw StoreError.badRequest(detail:
                "main.doped.json names scope code '\(bundle.main.scope.code)' but the target scope is '\(scopeBefore.code)' — the code is identity and cannot be changed by ingest")
        }
        return try dbQueue.write { db in
            let incoming = bundle.main.version
            try db.execute(sql: """
                UPDATE dope_scope
                   SET revision = ?,
                       name = ?,
                       description = ?,
                       version = version + (CASE WHEN name IS NOT ? OR description IS NOT ?
                                                 THEN 1 ELSE 0 END),
                       updated_at = ?
                 WHERE uuid = ? AND revision = ?
                """, arguments: [
                    incoming,
                    bundle.main.scope.name, bundle.main.scope.description,
                    bundle.main.scope.name, bundle.main.scope.description,
                    Store.isoNow(), req.scopeUuid, incoming - 1,
                ])
            if db.changesCount == 0 {
                guard let actual = try Int64.fetchOne(
                    db, sql: "SELECT revision FROM dope_scope WHERE uuid = ?",
                    arguments: [req.scopeUuid]
                ) else {
                    throw StoreError.notFound(entity: "dope_scope", key: req.scopeUuid)
                }
                throw StoreError.revisionConflict(
                    scopeUuid: req.scopeUuid, expected: incoming - 1, actual: actual)
            }

            try self.wipeDopeTree(db, scopeUuid: req.scopeUuid)
            let counts = try self.insertDopeTree(
                db, scopeUuid: req.scopeUuid, domainFiles: bundle.domainFiles)

            guard let scope = try self.fetchDopeScope(db, uuid: req.scopeUuid) else {
                throw StoreError.corruptState(entity: "dope_scope", detail: "vanished during ingest")
            }
            try self.recordDopeIngestEvent(db, scope: scope, before: scopeBefore.revision,
                                           counts: counts)
            return DopeIngestResponse(scope: scope, counts: counts)
        }
    }

    private func recordDopeIngestEvent(
        _ db: Database, scope: DopeScopeRow, before: Int64, counts: DopeTreeCounts
    ) throws {
        try appendEvent(db, kind: .dopeChange, subjectUuid: scope.uuid,
                        payload: Store.jsonPayload([
                            "action": "ingest",
                            "scope_uuid": scope.uuid,
                            "session_uuid": scope.sessionUuid,
                            "revision": Int(scope.revision),
                            "previous_revision": Int(before),
                            "domains": counts.domains,
                            "entities": counts.entities,
                            "properties": counts.properties,
                            "enums": counts.enums,
                            "options": counts.options,
                        ]))
        try touchSession(db, uuid: scope.sessionUuid)
    }
}
