import Foundation
import GRDB

// PATHS_GET / CONFIG_SET — the daemon's config subsystem (item 6). Backed by
// the daemon_config table (seeded with $HOME defaults by m0002) rather than
// env reads: the daemon's environment is a posix_spawn snapshot of whichever
// gm invocation autostarted it, so $GMCC_* would be stale or absent. The key
// space is enum-bound (ConfigKey) — an unknown key is BAD_REQUEST. Retires
// GMVibes' ~/.zshrc scraping fallback.

extension Store {
    public func pathsGet() throws -> PathsGetResponse {
        try dbQueue.read { db in
            let config = try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT config_key, config_value FROM daemon_config"
                ).map { ($0["config_key"] as String, $0["config_value"] as String) })
            func value(_ key: ConfigKey, fallback: String) -> String {
                config[key.rawValue] ?? fallback
            }
            let home = NSHomeDirectory()
            return PathsGetResponse(
                gmccRoot: Paths.root.path,
                dbPath: Paths.db.path,
                socketPath: Paths.socket.path,
                backupsRoot: Paths.backups.path,
                ckfsRoot: value(.ckfsRoot, fallback: "\(home)/gmcc_ckfs"),
                kbiteRoot: value(.kbiteRoot, fallback: "\(home)/gmcc_ckfs/kbites"),
                kbiteOpenRoot: value(.kbiteOpenRoot, fallback: "\(home)/gmcc_ckfs/kbites/open"),
                kbiteDigestedRoot: value(.kbiteDigestedRoot, fallback: "\(home)/gmcc_ckfs/kbites/digested")
            )
        }
    }

    public func configSet(_ req: ConfigSetRequest) throws -> ConfigSetResponse {
        let value = req.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw StoreError.badRequest(detail: "config value is empty")
        }
        return try dbQueue.write { db in
            // Upsert without version threading: config keys are singletons
            // owned by the daemon; last write wins (still audited via the
            // event trail).
            if try Row.fetchOne(
                db, sql: "SELECT 1 FROM daemon_config WHERE config_key = ?",
                arguments: [req.key.rawValue]
            ) != nil {
                try db.execute(
                    sql: """
                        UPDATE daemon_config
                        SET config_value = ?, version = version + 1, updated_at = ?
                        WHERE config_key = ?
                        """,
                    arguments: [value, Store.isoNow(), req.key.rawValue])
            } else {
                try self.insertBase(db, table: "daemon_config", extra: [
                    "config_key": req.key.rawValue,
                    "config_value": value,
                ])
            }
            try self.appendEvent(
                db, kind: .configSet,
                payload: Store.jsonPayload(["key": req.key.rawValue, "value": value]))
            return ConfigSetResponse(key: req.key, value: value)
        }
    }

    /// The watcher's root, read outside a request cycle. nil until config
    /// exists (a daemon booted before m0002 seeded it simply has no watcher).
    public func configValue(_ key: ConfigKey) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT config_value FROM daemon_config WHERE config_key = ?",
                arguments: [key.rawValue])
        }
    }

    /// MemoryWatcher's reverse lookup: prompt by its ckfs folder path.
    public func promptUuid(byStoragePath path: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT uuid FROM prompt WHERE ckfs_relative_storage_path = ?",
                arguments: [path])
        }
    }
}
