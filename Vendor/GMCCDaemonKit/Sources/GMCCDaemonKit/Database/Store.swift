import Foundation
import GRDB

/// Typed domain failures. Handlers never hand-build error payloads — this is
/// the ONE mapping point from Store outcomes to wire error codes.
public enum StoreError: Error, Sendable {
    case notFound(entity: String, key: String)
    case versionConflict(entity: String, uuid: String, expected: Int64, actual: Int64)
    case invalidTransition(from: PromptStatus, to: PromptStatus)
    case contentLocked(status: PromptStatus)
    /// A guarded update with no fields set — rejected instead of burning the
    /// version other editors hold and emitting an empty audit event.
    case emptyUpdate(entity: String)
    /// A row holds a value the schema CHECKs should have made impossible.
    case corruptState(entity: String, detail: String)
    /// A request whose payload decoded fine but is semantically unusable
    /// (e.g. a whitespace-only search query).
    case badRequest(detail: String)
    /// Generic status-machine violation for the non-prompt entities
    /// (clarification_summary, architecture_summary). Maps onto the SAME wire
    /// code as the prompt-typed case — no new ErrorCode needed.
    case invalidEntityTransition(entity: String, from: String, to: String, reason: String?)

    public var errorPayload: ErrorPayload {
        switch self {
        case .notFound(let entity, let key):
            return ErrorPayload(code: .notFound, message: "\(entity) not found: \(key)")
        case .versionConflict(let entity, let uuid, let expected, let actual):
            return ErrorPayload(
                code: .versionConflict,
                message: "\(entity) \(uuid): expected version \(expected), actual \(actual)")
        case .invalidTransition(let from, let to):
            return ErrorPayload(
                code: .invalidTransition,
                message: "illegal prompt transition \(from.rawValue) → \(to.rawValue)")
        case .contentLocked(let status):
            return ErrorPayload(
                code: .contentLocked,
                message: "prompt content is editable only in draft (status: \(status.rawValue))")
        case .emptyUpdate(let entity):
            return ErrorPayload(
                code: .badRequest,
                message: "\(entity) update carried no fields — nothing to change")
        case .corruptState(let entity, let detail):
            return ErrorPayload(
                code: .internalError,
                message: "\(entity) holds an impossible value: \(detail)")
        case .badRequest(let detail):
            return ErrorPayload(code: .badRequest, message: detail)
        case .invalidEntityTransition(let entity, let from, let to, let reason):
            let suffix = reason.map { " (\($0))" } ?? ""
            return ErrorPayload(
                code: .invalidTransition,
                message: "illegal \(entity) transition \(from) → \(to)\(suffix)")
        }
    }
}

/// A committed daemon_event row, as delivered to the event sink. `id` is the
/// durable cursor shared by live broadcast and since_id replay.
public struct PersistedEvent: Sendable {
    public let id: Int64
    public let kind: String
    public let subjectUuid: String?
    public let payload: String?
    public let createdAt: String

    public var notification: EventNotification {
        EventNotification(id: id, kind: kind, subjectUuid: subjectUuid, payload: payload, createdAt: createdAt)
    }
}

/// SQLite access layer. The daemon is the ONLY caller — gm and GMVibes reach
/// the db exclusively through the socket. DatabaseQueue serializes all access,
/// making the single-writer invariant structural rather than conventional.
///
/// Domain methods live in per-family extensions (Store+Context, Store+Session,
/// Store+Prompt, Store+Artifact, Store+FileChange, Store+Event, Store+Backup);
/// this file holds the core: primitives, event sink, and maintenance.
public final class Store: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    public let dbPath: String

    /// Post-commit event fan-out. appendEvent registers each event via GRDB's
    /// afterNextTransaction(onCommit:), so the sink fires only for committed
    /// transactions (a rolled-back write can never leak a phantom event) and
    /// never while the db lock is held. The server registers this once and
    /// broadcasts every kind to subscribers.
    public var eventSink: ((PersistedEvent) -> Void)?

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // GRDB enables foreign_keys by default; WAL is opt-in.
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            // The kbite_resource_file FTS5 sync triggers must also fire when
            // rows disappear via FK CASCADE (SQLite's default is OFF).
            try db.execute(sql: "PRAGMA recursive_triggers=ON")
        }
        self.dbPath = path
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    public func migrate() throws {
        try Migrations.migrator.migrate(dbQueue)
    }

    // MARK: - Base-field helpers

    /// Sole timestamp source: seconds-precision ISO-8601 Z. EVENT_LIST time
    /// filters compare lexicographically, which is correct only while every
    /// writer emits exactly this format.
    // ISO8601DateFormatter is documented thread-safe; the annotation only
    // silences Swift 6's conservative Sendable check.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    public static func isoNow() -> String {
        isoFormatter.string(from: Date())
    }

    static func newUuid() -> String {
        UUID().uuidString.lowercased()
    }

    /// The lifecycle-v2 epoch: applied_at of m0002's schema_migrations row.
    /// A prompt whose created_at predates it has no db-native
    /// clarification/architecture history and never will (the contract
    /// forbids fabricating backing rows), so forward gates pass vacuously and
    /// create-on-enter is suppressed for it. Lexicographic comparison is
    /// chronological — every timestamp comes from isoNow(). Cached per Store
    /// (the value never changes after the migration runs); reads happen only
    /// inside dbQueue turns, which serializes access.
    private var lifecycleEpochCache: String??

    func isLegacyPrompt(_ db: Database, createdAt: String) throws -> Bool {
        if lifecycleEpochCache == nil {
            lifecycleEpochCache = .some(try String.fetchOne(
                db, sql: "SELECT applied_at FROM schema_migrations WHERE version = 2"))
        }
        guard let epoch = lifecycleEpochCache ?? nil else { return false }
        return createdAt < epoch
    }

    /// Advance a session's recency WITHOUT bumping its version — deliberately
    /// not updateBase. Prompt/file-change writes advancing updated_at must
    /// never invalidate a session version an editor is holding (spurious
    /// VERSION_CONFLICTs in the GMVibes session editor). The one place
    /// updated_at and version are not in lockstep.
    func touchSession(_ db: Database, uuid: String) throws {
        try db.execute(
            sql: "UPDATE session SET updated_at = ? WHERE uuid = ?",
            arguments: [Store.isoNow(), uuid])
    }

    /// The comparison feature's join key contract: architecture change rows
    /// and file_change rows meet on this string, so both write paths run
    /// through this one normalizer. Purely lexical — NEVER touches the
    /// filesystem (live instance roots include paths that no longer exist,
    /// and architecture rows name files that don't exist yet).
    ///
    /// Relative paths are anchored by definition and pass through cleaned; an
    /// absolute path inside the instance root is stripped to repo-relative;
    /// an absolute path outside it is rejected (honest failure over a
    /// silently zero-match join).
    static func normalizeRepoRelativePath(_ raw: String, repoRoot: String) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw StoreError.badRequest(detail: "file path is empty")
        }
        guard !path.contains("\0"), !path.contains("\n") else {
            throw StoreError.badRequest(detail: "file path contains control characters")
        }
        if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        }
        if path.hasPrefix("/") {
            var root = repoRoot
            while root.hasSuffix("/") { root = String(root.dropLast()) }
            guard root.count > 1, path == root || path.hasPrefix(root + "/") else {
                throw StoreError.badRequest(
                    detail: "path is not inside the instance root (\(repoRoot)): \(raw)")
            }
            path = String(path.dropFirst(root.count))
            if path.hasPrefix("/") { path = String(path.dropFirst()) }
        }
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        let segments = path.split(separator: "/")
        guard !segments.contains("..") else {
            throw StoreError.badRequest(detail: "path escapes the repo root: \(raw)")
        }
        guard !path.isEmpty, path != "/" else {
            throw StoreError.badRequest(detail: "path resolves to the repo root: \(raw)")
        }
        return path
    }

    /// daemon_event.payload is documented as JSON — always build it with a
    /// real serializer so embedded quotes/backslashes in values (file paths!)
    /// can't produce malformed rows.
    static func jsonPayload(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Insert a row with the five BaseEntity columns plus `extra` columns.
    /// Returns the row's uuid (freshly generated unless `uuid` is supplied —
    /// callers pass a ckfs uuid to keep db ↔ ckfs joins trivial).
    @discardableResult
    func insertBase(
        _ db: Database,
        table: String,
        uuid: String? = nil,
        now: String? = nil,
        extra: [String: (any DatabaseValueConvertible)?]
    ) throws -> String {
        let rowUuid = uuid ?? Store.newUuid()
        let now = now ?? Store.isoNow()
        let columns = ["uuid", "version", "created_at", "updated_at"] + extra.keys.sorted()
        let values: [(any DatabaseValueConvertible)?] =
            [rowUuid, 0, now, now] + extra.keys.sorted().map { extra[$0] ?? nil }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        try db.execute(sql: sql, arguments: StatementArguments(values))
        return rowUuid
    }

    /// Guarded update — THE optimistic-concurrency primitive. Bumps version
    /// and updated_at; matches only when the caller's expected version is
    /// current. Zero rows changed is discriminated (same transaction) into
    /// NOT_FOUND vs VERSION_CONFLICT.
    func updateBase(
        _ db: Database,
        table: String,
        uuid: String,
        expectedVersion: Int64,
        set: [String: (any DatabaseValueConvertible)?]
    ) throws {
        let keys = set.keys.sorted()
        let assignments = (keys.map { "\($0) = ?" } + ["version = version + 1", "updated_at = ?"])
            .joined(separator: ", ")
        let sql = "UPDATE \(table) SET \(assignments) WHERE uuid = ? AND version = ?"
        let values: [(any DatabaseValueConvertible)?] =
            keys.map { set[$0] ?? nil } + [Store.isoNow(), uuid, expectedVersion]
        try db.execute(sql: sql, arguments: StatementArguments(values))
        guard db.changesCount == 0 else { return }
        guard let actual = try Int64.fetchOne(
            db, sql: "SELECT version FROM \(table) WHERE uuid = ?", arguments: [uuid]
        ) else {
            throw StoreError.notFound(entity: table, key: uuid)
        }
        throw StoreError.versionConflict(entity: table, uuid: uuid, expected: expectedVersion, actual: actual)
    }

    /// Append a daemon_event row and stage it for the post-commit sink.
    /// Append-only: version stays 0 and updated_at == created_at, so
    /// insertBase's defaults are exactly right.
    @discardableResult
    func appendEvent(
        _ db: Database,
        kind: DaemonEventKind,
        subjectUuid: String? = nil,
        payload: String? = nil
    ) throws -> String {
        // One timestamp for both the row and the sink copy, so the live
        // broadcast and a later replay of the same event id never differ.
        let createdAt = Store.isoNow()
        let uuid = try insertBase(db, table: "daemon_event", now: createdAt, extra: [
            "kind": kind.rawValue,
            "subject_uuid": subjectUuid,
            "payload": payload,
        ])
        let event = PersistedEvent(
            id: db.lastInsertedRowID,
            kind: kind.rawValue,
            subjectUuid: subjectUuid,
            payload: payload,
            createdAt: createdAt
        )
        db.afterNextTransaction(
            onCommit: { [weak self] _ in self?.eventSink?(event) },
            onRollback: { _ in }
        )
        return uuid
    }

    // MARK: - Lifecycle events

    public func recordDaemonStart() throws {
        _ = try dbQueue.write { db in
            try self.appendEvent(db, kind: .daemonStart, payload: Store.jsonPayload(["pid": Int(getpid())]))
        }
    }

    public func recordDaemonStop() throws {
        _ = try dbQueue.write { db in
            try self.appendEvent(db, kind: .daemonStop, payload: Store.jsonPayload(["pid": Int(getpid())]))
        }
    }

    // MARK: - Health reads

    public func schemaVersion() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations") ?? 0
        }
    }

    public func tableCounts() throws -> [TableCount] {
        try dbQueue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                ORDER BY name
                """)
            return try tables.map { table in
                TableCount(name: table,
                           count: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            }
        }
    }

    // MARK: - Maintenance (SHUTDOWN)

    /// Truncate the WAL back into the main db file — part of the SHUTDOWN
    /// contract ("checkpoint WAL").
    public func checkpointTruncate() throws {
        try dbQueue.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    public func closeDatabase() throws {
        try dbQueue.close()
    }
}
