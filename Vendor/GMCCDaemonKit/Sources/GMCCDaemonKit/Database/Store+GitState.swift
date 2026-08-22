import Foundation
import GRDB

// SESSION_RESOLVE / INSTANCE_CURRENT_SESSION — git-derived checked-out state
// (item 2). Runs ON the serial queue deliberately: a HEAD read is a sub-100-
// byte local file read guarded by O_NONBLOCK + a 4KB cap (GitHead), and a
// missing instance path fails instantly to .unavailable — no lane needed.
// Resolution is forward-only: slug HEAD's branch (/ → __) and compare to
// session.code; the mapping is lossy, so codes are never un-slugged.

extension Store {
    public func sessionResolve(_ req: SessionResolveRequest) throws -> SessionResolveResponse {
        try dbQueue.read { db in
            guard let session = try self.fetchSessionRow(db, uuid: req.sessionUuid) else {
                throw StoreError.notFound(entity: "session", key: req.sessionUuid)
            }
            let instanceRoot = try String.fetchOne(db, sql: """
                SELECT i.absolute_file_system_path
                FROM session s JOIN instance i ON i.uuid = s.instance_uuid
                WHERE s.uuid = ?
                """, arguments: [req.sessionUuid]) ?? ""
            let (headState, currentCode) = Self.headSummary(repoRoot: instanceRoot)
            return SessionResolveResponse(
                session: session,
                checkedOut: currentCode != nil && currentCode == session.code,
                headState: headState,
                currentSessionCode: currentCode
            )
        }
    }

    public func instanceCurrentSession(
        _ req: InstanceCurrentSessionRequest
    ) throws -> InstanceCurrentSessionResponse {
        try dbQueue.read { db in
            guard let instanceRoot = try String.fetchOne(
                db, sql: "SELECT absolute_file_system_path FROM instance WHERE uuid = ?",
                arguments: [req.instanceUuid]
            ) else {
                throw StoreError.notFound(entity: "instance", key: req.instanceUuid)
            }
            let (headState, currentCode) = Self.headSummary(repoRoot: instanceRoot)
            var stub: SessionStub?
            if let code = currentCode {
                // Same column list + last_activity_at shape as SESSION_LIST.
                if let row = try Row.fetchOne(db, sql: """
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
                    WHERE s.instance_uuid = ? AND s.code = ?
                    """, arguments: [req.instanceUuid, code]) {
                    stub = self.sessionStub(from: row)
                }
            }
            return InstanceCurrentSessionResponse(
                session: stub, headState: headState, currentSessionCode: currentCode)
        }
    }

    private static func headSummary(repoRoot: String) -> (state: String, code: String?) {
        guard !repoRoot.isEmpty else { return ("unavailable", nil) }
        switch GitHead.resolve(repoRoot: repoRoot) {
        case .branch(let branch):
            return ("branch", GitHead.sessionCode(forBranch: branch))
        case .detached:
            return ("detached", nil)
        case .unavailable:
            return ("unavailable", nil)
        }
    }
}
