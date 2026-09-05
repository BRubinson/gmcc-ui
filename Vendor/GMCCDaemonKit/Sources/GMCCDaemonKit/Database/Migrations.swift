import Foundation
import GRDB

/// Versioned schema migrations.
///
/// GRDB's DatabaseMigrator keeps its own private `grdb_migrations` replay
/// guard; the spec-visible ledger is the separate `schema_migrations` table
/// (the only table not wrapped in the BaseEntity columns), which each
/// migration appends its own row to.
public enum Migrations {
    /// Bump alongside new registerMigration calls.
    /// The re-baseline era ended at m0002: the db is append-only now. m0001's
    /// body is FROZEN — the migrator keys on the migration id and silently
    /// skips a changed body on an existing db, so any schema change lands as a
    /// new registerMigration and existing databases upgrade in place. Never
    /// instruct anyone to wipe ~/gmcc/gmcc.db* again.
    public static let currentSchemaVersion = 6

    /// The five BaseEntity columns wrapped into every domain table.
    /// `id` is the internal rowid; `uuid` is the external join key — all FKs
    /// reference uuid, never id.
    private static let baseColumns = """
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        version INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
        """

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("m0001_baseSchema") { db in
            try db.execute(sql: """
                CREATE TABLE schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                );

                CREATE TABLE project (
                    \(baseColumns),
                    git_repo_name TEXT NOT NULL,
                    code TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    ckfs_relative_storage_path TEXT NOT NULL
                );

                CREATE TABLE instance (
                    \(baseColumns),
                    project_uuid TEXT NOT NULL REFERENCES project(uuid),
                    code TEXT NOT NULL,
                    name TEXT NOT NULL,
                    absolute_file_system_path TEXT NOT NULL,
                    ckfs_relative_storage_path TEXT NOT NULL,
                    UNIQUE(project_uuid, name)
                );

                CREATE TABLE session (
                    \(baseColumns),
                    instance_uuid TEXT NOT NULL REFERENCES instance(uuid),
                    code TEXT NOT NULL,
                    name TEXT NOT NULL,
                    backstory TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'closed')),
                    ckfs_relative_storage_path TEXT NOT NULL,
                    UNIQUE(instance_uuid, code)
                );

                CREATE TABLE prompt (
                    \(baseColumns),
                    session_uuid TEXT NOT NULL REFERENCES session(uuid),
                    seq INTEGER NOT NULL,
                    code TEXT NOT NULL,
                    name TEXT NOT NULL,
                    backstory TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    command TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'clarifying', 'clarified')),
                    ckfs_relative_storage_path TEXT NOT NULL,
                    UNIQUE(session_uuid, code),
                    UNIQUE(session_uuid, seq)
                );

                CREATE TABLE prompt_artifact (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    file_path TEXT NOT NULL,
                    kind TEXT NOT NULL
                        CHECK (kind IN ('explore', 'architecture', 'review', 'qualified', 'other')),
                    note TEXT,
                    UNIQUE(prompt_uuid, file_path)
                );

                CREATE TABLE kbite (
                    \(baseColumns),
                    code TEXT NOT NULL UNIQUE
                );

                CREATE TABLE prompt_active_kbite (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    UNIQUE(prompt_uuid, kbite_uuid)
                );

                CREATE TABLE session_active_kbite (
                    \(baseColumns),
                    session_uuid TEXT NOT NULL REFERENCES session(uuid) ON DELETE CASCADE,
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    UNIQUE(session_uuid, kbite_uuid)
                );

                CREATE TABLE instance_active_kbite (
                    \(baseColumns),
                    instance_uuid TEXT NOT NULL REFERENCES instance(uuid) ON DELETE CASCADE,
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    UNIQUE(instance_uuid, kbite_uuid)
                );

                CREATE TABLE project_active_kbite (
                    \(baseColumns),
                    project_uuid TEXT NOT NULL REFERENCES project(uuid) ON DELETE CASCADE,
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    UNIQUE(project_uuid, kbite_uuid)
                );

                CREATE TABLE session_file (
                    \(baseColumns),
                    session_uuid TEXT NOT NULL REFERENCES session(uuid),
                    relative_path TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1,
                    UNIQUE(session_uuid, relative_path)
                );

                CREATE TABLE file_change (
                    \(baseColumns),
                    session_file_uuid TEXT NOT NULL REFERENCES session_file(uuid),
                    session_uuid TEXT NOT NULL REFERENCES session(uuid),
                    prompt_uuid TEXT REFERENCES prompt(uuid),
                    change_kind TEXT NOT NULL DEFAULT 'edit'
                        CHECK (change_kind IN ('edit', 'create', 'delete', 'rename'))
                );

                CREATE TABLE file_change_range (
                    \(baseColumns),
                    file_change_uuid TEXT NOT NULL REFERENCES file_change(uuid) ON DELETE CASCADE,
                    line_start INTEGER NOT NULL,
                    line_end INTEGER NOT NULL,
                    changed_content TEXT
                );

                CREATE TABLE daemon_event (
                    \(baseColumns),
                    kind TEXT NOT NULL,
                    subject_uuid TEXT,
                    payload TEXT
                );

                CREATE INDEX idx_instance_project_uuid ON instance(project_uuid);
                CREATE INDEX idx_session_instance_uuid ON session(instance_uuid);
                CREATE INDEX idx_prompt_session_uuid ON prompt(session_uuid);
                CREATE INDEX idx_prompt_artifact_prompt_uuid ON prompt_artifact(prompt_uuid);
                CREATE INDEX idx_prompt_active_kbite_prompt_uuid ON prompt_active_kbite(prompt_uuid);
                CREATE INDEX idx_prompt_active_kbite_kbite_uuid ON prompt_active_kbite(kbite_uuid);
                CREATE INDEX idx_session_active_kbite_session_uuid ON session_active_kbite(session_uuid);
                CREATE INDEX idx_session_active_kbite_kbite_uuid ON session_active_kbite(kbite_uuid);
                CREATE INDEX idx_instance_active_kbite_instance_uuid ON instance_active_kbite(instance_uuid);
                CREATE INDEX idx_instance_active_kbite_kbite_uuid ON instance_active_kbite(kbite_uuid);
                CREATE INDEX idx_project_active_kbite_project_uuid ON project_active_kbite(project_uuid);
                CREATE INDEX idx_project_active_kbite_kbite_uuid ON project_active_kbite(kbite_uuid);
                CREATE INDEX idx_session_file_session_uuid ON session_file(session_uuid);
                CREATE INDEX idx_file_change_session_file_uuid ON file_change(session_file_uuid);
                CREATE INDEX idx_file_change_session_uuid ON file_change(session_uuid);
                CREATE INDEX idx_file_change_prompt_uuid ON file_change(prompt_uuid);
                CREATE INDEX idx_file_change_range_file_change_uuid ON file_change_range(file_change_uuid);
                CREATE INDEX idx_daemon_event_subject_uuid ON daemon_event(subject_uuid);
                CREATE INDEX idx_daemon_event_kind ON daemon_event(kind);
                CREATE INDEX idx_daemon_event_created_at ON daemon_event(created_at);
                """)

            // Kbite content family (v16 prompt 4), folded into the single
            // re-baselined m0001: the digested-content side — resources,
            // files, keyword vocabulary, and the FTS5 mirror backing
            // KBITE_SEARCH.
            try db.execute(sql: """
                CREATE TABLE keyword (
                    \(baseColumns),
                    keyword TEXT NOT NULL UNIQUE
                );

                CREATE TABLE kbite_keyword_junction (
                    \(baseColumns),
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    keyword_uuid TEXT NOT NULL REFERENCES keyword(uuid) ON DELETE CASCADE,
                    UNIQUE(kbite_uuid, keyword_uuid)
                );

                CREATE TABLE kbite_resource (
                    \(baseColumns),
                    kbite_uuid TEXT NOT NULL REFERENCES kbite(uuid) ON DELETE CASCADE,
                    resource_name TEXT NOT NULL,
                    resource_summary TEXT NOT NULL,
                    resource_type TEXT NOT NULL
                        CHECK (resource_type IN ('documentation', 'example_project', 'api_reference', 'blogs', 'all_others')),
                    resource_trust INTEGER NOT NULL DEFAULT 0
                        CHECK (resource_trust BETWEEN 0 AND 100)
                );

                CREATE TABLE kbite_resource_file (
                    \(baseColumns),
                    kbite_resource_uuid TEXT NOT NULL REFERENCES kbite_resource(uuid) ON DELETE CASCADE,
                    resource_file_name TEXT NOT NULL,
                    resource_file_summary TEXT NOT NULL DEFAULT '',
                    resource_file_content TEXT
                );

                CREATE TABLE resource_file_keyword_junction (
                    \(baseColumns),
                    file_uuid TEXT NOT NULL REFERENCES kbite_resource_file(uuid) ON DELETE CASCADE,
                    keyword_uuid TEXT NOT NULL REFERENCES keyword(uuid) ON DELETE CASCADE,
                    UNIQUE(file_uuid, keyword_uuid)
                );

                CREATE INDEX idx_kbite_keyword_junction_kbite_uuid ON kbite_keyword_junction(kbite_uuid);
                CREATE INDEX idx_kbite_keyword_junction_keyword_uuid ON kbite_keyword_junction(keyword_uuid);
                CREATE INDEX idx_kbite_resource_kbite_uuid ON kbite_resource(kbite_uuid);
                CREATE INDEX idx_kbite_resource_file_kbite_resource_uuid ON kbite_resource_file(kbite_resource_uuid);
                CREATE INDEX idx_resource_file_keyword_junction_file_uuid ON resource_file_keyword_junction(file_uuid);
                CREATE INDEX idx_resource_file_keyword_junction_keyword_uuid ON resource_file_keyword_junction(keyword_uuid);

                CREATE VIRTUAL TABLE kbite_resource_file_fts USING fts5(
                    resource_file_name,
                    resource_file_summary,
                    resource_file_content,
                    content='kbite_resource_file',
                    content_rowid='id'
                );

                CREATE TRIGGER kbite_resource_file_ai AFTER INSERT ON kbite_resource_file BEGIN
                    INSERT INTO kbite_resource_file_fts(rowid, resource_file_name, resource_file_summary, resource_file_content)
                    VALUES (new.id, new.resource_file_name, new.resource_file_summary, new.resource_file_content);
                END;

                CREATE TRIGGER kbite_resource_file_ad AFTER DELETE ON kbite_resource_file BEGIN
                    INSERT INTO kbite_resource_file_fts(kbite_resource_file_fts, rowid, resource_file_name, resource_file_summary, resource_file_content)
                    VALUES ('delete', old.id, old.resource_file_name, old.resource_file_summary, old.resource_file_content);
                END;

                CREATE TRIGGER kbite_resource_file_au AFTER UPDATE ON kbite_resource_file BEGIN
                    INSERT INTO kbite_resource_file_fts(kbite_resource_file_fts, rowid, resource_file_name, resource_file_summary, resource_file_content)
                    VALUES ('delete', old.id, old.resource_file_name, old.resource_file_summary, old.resource_file_content);
                    INSERT INTO kbite_resource_file_fts(rowid, resource_file_name, resource_file_summary, resource_file_content)
                    VALUES (new.id, new.resource_file_name, new.resource_file_summary, new.resource_file_content);
                END;
                """)

            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [1, Store.isoNow()]
            )
        }

        // m0002 — db-native clarification + architecture entities, prompt
        // lifecycle v2 (six states), daemon_config. The first no-wipe
        // migration: existing data is preserved and the prompt table is
        // rebuilt in place.
        //
        // Registered with NO foreignKeyChecks: argument — GRDB's default
        // .deferred IS the official SQLite 12-step (PRAGMA foreign_keys=OFF
        // outside the transaction → body → whole-db foreign_key_check →
        // commit). NO PRAGMA may appear in this body: pragmas are silently
        // ignored inside a transaction, and with FK enforcement live the
        // prompt rebuild either aborts (via file_change's NO ACTION
        // reference) or silently CASCADE-deletes every prompt_artifact row
        // and commits — both verified empirically.
        migrator.registerMigration("m0002_clarificationArchitectureLifecycleV2") { db in
            // Step 1 — the prompt rebuild, FIRST, while the table has only its
            // three m0001-era referrers. Ordering is create-new → copy →
            // drop-old → rename-new: the only ALTER renames a table with zero
            // referrers, which is correct under every GRDB FK mode (renaming
            // the OLD table out of the way instead rewrites child FK clauses
            // to REFERENCES "prompt_old" whenever foreign_keys is ON). The
            // copy carries `id` explicitly so every uuid keeps its rowid and
            // sqlite_sequence stays monotonic. Old terminal `clarified` maps
            // to the new terminal `done`; draft/clarifying copy through.
            try db.execute(sql: """
                CREATE TABLE prompt_new (
                    \(baseColumns),
                    session_uuid TEXT NOT NULL REFERENCES session(uuid),
                    seq INTEGER NOT NULL,
                    code TEXT NOT NULL,
                    name TEXT NOT NULL,
                    backstory TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    command TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'clarifying', 'architecting',
                                          'implementing', 'reviewing', 'done')),
                    ckfs_relative_storage_path TEXT NOT NULL,
                    UNIQUE(session_uuid, code),
                    UNIQUE(session_uuid, seq)
                );

                INSERT INTO prompt_new (id, uuid, version, created_at, updated_at,
                                        session_uuid, seq, code, name, backstory,
                                        goal, detail, command, status,
                                        ckfs_relative_storage_path)
                SELECT id, uuid, version, created_at, updated_at,
                       session_uuid, seq, code, name, backstory,
                       goal, detail, command,
                       CASE status WHEN 'clarified' THEN 'done' ELSE status END,
                       ckfs_relative_storage_path
                FROM prompt;

                DROP TABLE prompt;
                ALTER TABLE prompt_new RENAME TO prompt;
                CREATE INDEX idx_prompt_session_uuid ON prompt(session_uuid);
                """)

            // Step 2 — the new entity tables, created AFTER the rebuild so
            // their CASCADE references point at the new prompt table and never
            // exist during the DROP above.
            try db.execute(sql: """
                CREATE TABLE clarification_summary (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    status TEXT NOT NULL DEFAULT 'building'
                        CHECK (status IN ('building', 'answering', 'complete')),
                    backstory_note TEXT NOT NULL DEFAULT '',
                    refined_goal TEXT NOT NULL DEFAULT '',
                    refined_detail TEXT NOT NULL DEFAULT '',
                    UNIQUE(prompt_uuid)
                );

                CREATE TABLE clarification (
                    \(baseColumns),
                    clarification_summary_uuid TEXT NOT NULL
                        REFERENCES clarification_summary(uuid) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    category TEXT NOT NULL
                        CHECK (category IN ('goal', 'detail', 'yeet_type')),
                    question TEXT NOT NULL,
                    answer TEXT,
                    answer_source TEXT
                        CHECK (answer_source IN ('user', 'bot_inferred')),
                    status TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'answered', 'skipped')),
                    CHECK (status != 'answered' OR answer IS NOT NULL),
                    UNIQUE(clarification_summary_uuid, seq)
                );

                CREATE TABLE architecture_summary (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    body TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'drafting'
                        CHECK (status IN ('drafting', 'proposed', 'approved')),
                    UNIQUE(prompt_uuid)
                );

                CREATE TABLE architecture_persistence_change (
                    \(baseColumns),
                    architecture_summary_uuid TEXT NOT NULL
                        REFERENCES architecture_summary(uuid) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    class_name TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    reason_brief TEXT NOT NULL,
                    UNIQUE(architecture_summary_uuid, seq)
                );

                CREATE TABLE architecture_persistence_field_change (
                    \(baseColumns),
                    persistence_change_uuid TEXT NOT NULL
                        REFERENCES architecture_persistence_change(uuid) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    field_name TEXT NOT NULL,
                    change_reason TEXT NOT NULL,
                    change_purpose TEXT NOT NULL,
                    data_type TEXT NOT NULL,
                    nullable INTEGER NOT NULL CHECK (nullable IN (0, 1)),
                    is_foreign_key INTEGER NOT NULL DEFAULT 0 CHECK (is_foreign_key IN (0, 1)),
                    fk_target TEXT,
                    is_indexed INTEGER NOT NULL DEFAULT 0 CHECK (is_indexed IN (0, 1)),
                    CHECK (is_foreign_key = 0 OR fk_target IS NOT NULL),
                    UNIQUE(persistence_change_uuid, seq)
                );

                CREATE TABLE architecture_general_change (
                    \(baseColumns),
                    architecture_summary_uuid TEXT NOT NULL
                        REFERENCES architecture_summary(uuid) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    file_path TEXT NOT NULL,
                    class_name TEXT,
                    reason_brief TEXT NOT NULL,
                    change_depth TEXT NOT NULL
                        CHECK (change_depth IN ('pseudo', 'draft', 'actual')),
                    change_code TEXT NOT NULL,
                    UNIQUE(architecture_summary_uuid, seq)
                );

                CREATE TABLE daemon_config (
                    \(baseColumns),
                    config_key TEXT NOT NULL UNIQUE,
                    config_value TEXT NOT NULL
                );

                CREATE INDEX idx_clarification_summary_prompt_uuid
                    ON clarification_summary(prompt_uuid);
                CREATE INDEX idx_clarification_summary_uuid_fk
                    ON clarification(clarification_summary_uuid);
                CREATE INDEX idx_architecture_summary_prompt_uuid
                    ON architecture_summary(prompt_uuid);
                CREATE INDEX idx_arch_persistence_change_summary_fk
                    ON architecture_persistence_change(architecture_summary_uuid);
                CREATE INDEX idx_arch_persistence_field_change_fk
                    ON architecture_persistence_field_change(persistence_change_uuid);
                CREATE INDEX idx_arch_general_change_summary_fk
                    ON architecture_general_change(architecture_summary_uuid);
                """)

            // Step 3 — seed daemon_config with the layout defaults ($HOME
            // conventions, matching detect_repo.sh). CONFIG_SET is the write
            // door for a differing layout; the daemon never reads $GMCC_* env
            // vars (its environment is a posix_spawn snapshot of whichever gm
            // invocation autostarted it).
            let home = NSHomeDirectory()
            let now = Store.isoNow()
            for (key, value) in [
                ("ckfs_root", "\(home)/gmcc_ckfs"),
                ("kbite_root", "\(home)/gmcc_ckfs/kbites"),
                ("kbite_open_root", "\(home)/gmcc_ckfs/kbites/open"),
                ("kbite_digested_root", "\(home)/gmcc_ckfs/kbites/digested"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO daemon_config
                            (uuid, version, created_at, updated_at, config_key, config_value)
                        VALUES (?, 0, ?, ?, ?, ?)
                        """,
                    arguments: [UUID().uuidString.lowercased(), now, now, key, value]
                )
            }

            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [2, Store.isoNow()]
            )
        }

        // m0003 — full-text search over prompt/clarification/architecture
        // text (the SEARCH message). Append-only: adds six external-content
        // FTS5 mirrors + sync triggers, touches no domain row. Six separate
        // tables is forced, not chosen — external-content FTS5 binds one
        // virtual table to exactly one source via content_rowid; the search
        // query UNIONs across them. The `_ad` triggers ride the globally
        // enabled recursive_triggers pragma (Store) so they fire on FK
        // cascade deletes too. Each table ends with a one-time
        // `INSERT INTO <fts>(<fts>) VALUES('rebuild')` — triggers only fire
        // on future writes, so without the rebuild all pre-existing history
        // would be unsearchable. No PRAGMA in this body (silently ignored
        // inside a transaction).
        migrator.registerMigration("m0003_searchIndexes") { db in
            struct FtsSpec {
                let source: String
                let columns: [String]
            }
            let specs = [
                FtsSpec(source: "prompt",
                        columns: ["name", "goal", "detail", "backstory"]),
                FtsSpec(source: "clarification_summary",
                        columns: ["refined_goal", "refined_detail", "backstory_note"]),
                FtsSpec(source: "clarification",
                        columns: ["question", "answer"]),
                FtsSpec(source: "architecture_summary",
                        columns: ["body"]),
                FtsSpec(source: "architecture_general_change",
                        columns: ["file_path", "reason_brief", "change_code"]),
                FtsSpec(source: "architecture_persistence_change",
                        columns: ["class_name", "file_path", "reason_brief"]),
            ]
            for spec in specs {
                let fts = "\(spec.source)_fts"
                let cols = spec.columns.joined(separator: ", ")
                let newVals = spec.columns.map { "new.\($0)" }.joined(separator: ", ")
                let oldVals = spec.columns.map { "old.\($0)" }.joined(separator: ", ")
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE \(fts) USING fts5(
                        \(cols),
                        content='\(spec.source)',
                        content_rowid='id'
                    );

                    CREATE TRIGGER \(spec.source)_ai AFTER INSERT ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    CREATE TRIGGER \(spec.source)_ad AFTER DELETE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                    END;

                    CREATE TRIGGER \(spec.source)_au AFTER UPDATE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    INSERT INTO \(fts)(\(fts)) VALUES('rebuild');
                    """)
            }

            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [3, Store.isoNow()]
            )
        }

        // m0004 — db-native exploration + review reports (the last two
        // file-based bot reports move into the db). Pure ADD: five new
        // BaseEntity tables + five external-content FTS5 mirrors; no rebuild,
        // no data motion, no domain row touched. One summary per prompt
        // (UNIQUE), children FK the summary with CASCADE. finding_rating is
        // deliberately nullable: NULL marks work-in-progress (unranked);
        // the complete transition refuses while any NULL remains, and GETs
        // always return NULL-rated rows in the full partition. The FtsSpec
        // loop is a private copy of m0003's — frozen migrations stay
        // self-contained; never share helpers across migration bodies. The
        // `_ad` triggers ride the global recursive_triggers pragma so FK
        // cascade deletes stay FTS-synced. No PRAGMA in this body.
        migrator.registerMigration("m0004_explorationReviewReports") { db in
            try db.execute(sql: """
                CREATE TABLE exploration_summary (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    status TEXT NOT NULL DEFAULT 'exploring'
                        CHECK (status IN ('exploring', 'complete')),
                    overview TEXT NOT NULL DEFAULT '',
                    UNIQUE(prompt_uuid)
                );

                CREATE TABLE exploration_key_file (
                    \(baseColumns),
                    exploration_summary_uuid TEXT NOT NULL
                        REFERENCES exploration_summary(uuid) ON DELETE CASCADE,
                    file_path TEXT NOT NULL,
                    UNIQUE(exploration_summary_uuid, file_path)
                );

                CREATE TABLE exploration_finding (
                    \(baseColumns),
                    exploration_summary_uuid TEXT NOT NULL
                        REFERENCES exploration_summary(uuid) ON DELETE CASCADE,
                    kind TEXT NOT NULL
                        CHECK (kind IN ('persistence_model', 'implementation_pattern',
                                        'existing_functionality', 'scope_creep_risk',
                                        'general_relevant_change', 'other')),
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    finding_rating INTEGER
                        CHECK (finding_rating IS NULL OR finding_rating BETWEEN 0 AND 999)
                );

                CREATE TABLE review_summary (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    status TEXT NOT NULL DEFAULT 'reviewing'
                        CHECK (status IN ('reviewing', 'complete')),
                    verdict TEXT
                        CHECK (verdict IN ('approved', 'approved_with_nits',
                                           'changes_requested', 'legacy_unstated')),
                    overview TEXT NOT NULL DEFAULT '',
                    CHECK (status != 'complete' OR verdict IS NOT NULL),
                    UNIQUE(prompt_uuid)
                );

                CREATE TABLE review_finding (
                    \(baseColumns),
                    review_summary_uuid TEXT NOT NULL
                        REFERENCES review_summary(uuid) ON DELETE CASCADE,
                    kind TEXT NOT NULL
                        CHECK (kind IN ('correctness_bug', 'spec_deviation',
                                        'regression_risk', 'security',
                                        'simplification', 'other')),
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    file_path TEXT,
                    line_start INTEGER,
                    line_end INTEGER,
                    agent_name TEXT NOT NULL,
                    finding_rating INTEGER
                        CHECK (finding_rating IS NULL OR finding_rating BETWEEN 0 AND 999),
                    status TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'fixed', 'accepted', 'wont_fix')),
                    CHECK (line_end IS NULL OR line_start IS NOT NULL)
                );

                CREATE INDEX idx_exploration_summary_prompt_uuid
                    ON exploration_summary(prompt_uuid);
                CREATE INDEX idx_exploration_key_file_summary_fk
                    ON exploration_key_file(exploration_summary_uuid);
                CREATE INDEX idx_exploration_finding_summary_fk
                    ON exploration_finding(exploration_summary_uuid);
                CREATE INDEX idx_review_summary_prompt_uuid
                    ON review_summary(prompt_uuid);
                CREATE INDEX idx_review_finding_summary_fk
                    ON review_finding(review_summary_uuid);
                """)

            struct FtsSpec {
                let source: String
                let columns: [String]
            }
            let specs = [
                FtsSpec(source: "exploration_summary",
                        columns: ["overview"]),
                FtsSpec(source: "exploration_key_file",
                        columns: ["file_path"]),
                FtsSpec(source: "exploration_finding",
                        columns: ["title", "body"]),
                FtsSpec(source: "review_summary",
                        columns: ["overview"]),
                FtsSpec(source: "review_finding",
                        columns: ["title", "body", "file_path"]),
            ]
            for spec in specs {
                let fts = "\(spec.source)_fts"
                let cols = spec.columns.joined(separator: ", ")
                let newVals = spec.columns.map { "new.\($0)" }.joined(separator: ", ")
                let oldVals = spec.columns.map { "old.\($0)" }.joined(separator: ", ")
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE \(fts) USING fts5(
                        \(cols),
                        content='\(spec.source)',
                        content_rowid='id'
                    );

                    CREATE TRIGGER \(spec.source)_ai AFTER INSERT ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    CREATE TRIGGER \(spec.source)_ad AFTER DELETE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                    END;

                    CREATE TRIGGER \(spec.source)_au AFTER UPDATE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    INSERT INTO \(fts)(\(fts)) VALUES('rebuild');
                    """)
            }

            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [4, Store.isoNow()]
            )
        }


        // m0005 — purge the legacy concepts. Three rebuilds plus a backfill.
        //
        // The plugin no longer has a legacy tier: YEETS is gone, the yaml era
        // is gone, and every bot report is db-native. What kept the legacy
        // FORK alive was data — 66 clarification rows categorised yeet_type,
        // 84 review verdicts of legacy_unstated, and 105 pre-m0002 prompts
        // carrying no clarification/architecture summary at all, whose only
        // record was an on-disk qualified.md/architecture.md reached through
        // SUMMARY_ABSENT + prompt_is_legacy. This migration removes that data
        // reason so the fork can leave the code. Uniformity was chosen over
        // fidelity by explicit decision: the placeholder summaries assert a
        // completeness the underlying history does not have, and point at the
        // file for anyone who wants the real content.
        //
        // SQLite cannot alter a CHECK, so clarification, review_summary and
        // prompt_artifact rebuild. Registered with NO foreignKeyChecks:
        // argument for the same reason m0002 is — GRDB's default .deferred IS
        // the official SQLite 12-step, and with FK enforcement live the
        // review_summary drop would CASCADE every review_finding away. NO
        // PRAGMA may appear in this body. Each rebuild copies `id` explicitly:
        // the external-content FTS5 mirrors join on content_rowid='id', and a
        // DROP TABLE takes the source table's triggers with it, so every
        // rebuilt table recreates its triggers and re-runs the fts rebuild.
        migrator.registerMigration("m0005_purgeLegacyConcepts") { db in
            // Step 1 — data motion FIRST, so the narrowed CHECKs hold when the
            // rebuilt tables are populated.
            try db.execute(sql: """
                UPDATE clarification SET category = 'detail'
                 WHERE category = 'yeet_type';

                UPDATE review_summary SET verdict = 'approved'
                 WHERE verdict = 'legacy_unstated';
                """)

            // Step 2 — clarification: drop yeet_type from the category CHECK.
            try db.execute(sql: """
                CREATE TABLE clarification_new (
                    \(baseColumns),
                    clarification_summary_uuid TEXT NOT NULL
                        REFERENCES clarification_summary(uuid) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    category TEXT NOT NULL
                        CHECK (category IN ('goal', 'detail')),
                    question TEXT NOT NULL,
                    answer TEXT,
                    answer_source TEXT
                        CHECK (answer_source IN ('user', 'bot_inferred')),
                    status TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'answered', 'skipped')),
                    CHECK (status != 'answered' OR answer IS NOT NULL),
                    UNIQUE(clarification_summary_uuid, seq)
                );

                INSERT INTO clarification_new
                    (id, uuid, version, created_at, updated_at,
                     clarification_summary_uuid, seq, category, question,
                     answer, answer_source, status)
                SELECT id, uuid, version, created_at, updated_at,
                       clarification_summary_uuid, seq, category, question,
                       answer, answer_source, status
                  FROM clarification;

                DROP TABLE clarification;
                ALTER TABLE clarification_new RENAME TO clarification;

                CREATE INDEX idx_clarification_summary_uuid_fk
                    ON clarification(clarification_summary_uuid);
                """)

            // Step 3 — review_summary: drop legacy_unstated from the verdict
            // CHECK. review_finding CASCADE-references this table by uuid;
            // ordering is create-new / copy / drop-old / rename-new so the
            // only ALTER renames a table with zero referrers.
            try db.execute(sql: """
                CREATE TABLE review_summary_new (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    status TEXT NOT NULL DEFAULT 'reviewing'
                        CHECK (status IN ('reviewing', 'complete')),
                    verdict TEXT
                        CHECK (verdict IN ('approved', 'approved_with_nits',
                                           'changes_requested')),
                    overview TEXT NOT NULL DEFAULT '',
                    CHECK (status != 'complete' OR verdict IS NOT NULL),
                    UNIQUE(prompt_uuid)
                );

                INSERT INTO review_summary_new
                    (id, uuid, version, created_at, updated_at,
                     prompt_uuid, status, verdict, overview)
                SELECT id, uuid, version, created_at, updated_at,
                       prompt_uuid, status, verdict, overview
                  FROM review_summary;

                DROP TABLE review_summary;
                ALTER TABLE review_summary_new RENAME TO review_summary;

                CREATE INDEX idx_review_summary_prompt_uuid
                    ON review_summary(prompt_uuid);
                """)

            // Step 4 — prompt_artifact: drop the kind column. Every legal
            // value described a pre-migration report file except 'other',
            // which is the only value a current bot may write; a column with
            // one legal value carries no information. Rows keep file_path and
            // note. No FTS mirror on this table.
            try db.execute(sql: """
                CREATE TABLE prompt_artifact_new (
                    \(baseColumns),
                    prompt_uuid TEXT NOT NULL REFERENCES prompt(uuid) ON DELETE CASCADE,
                    file_path TEXT NOT NULL,
                    note TEXT,
                    UNIQUE(prompt_uuid, file_path)
                );

                INSERT INTO prompt_artifact_new
                    (id, uuid, version, created_at, updated_at,
                     prompt_uuid, file_path, note)
                SELECT id, uuid, version, created_at, updated_at,
                       prompt_uuid, file_path, note
                  FROM prompt_artifact;

                DROP TABLE prompt_artifact;
                ALTER TABLE prompt_artifact_new RENAME TO prompt_artifact;

                CREATE INDEX idx_prompt_artifact_prompt_uuid
                    ON prompt_artifact(prompt_uuid);
                """)

            // Step 5 — recreate the FTS triggers the drops took with them, and
            // rebuild both indexes. A private copy of the m0003 loop: frozen
            // migrations stay self-contained, never share helpers.
            struct FtsSpec {
                let source: String
                let columns: [String]
            }
            let specs = [
                FtsSpec(source: "clarification", columns: ["question", "answer"]),
                FtsSpec(source: "review_summary", columns: ["overview"]),
            ]
            for spec in specs {
                let fts = "\(spec.source)_fts"
                let cols = spec.columns.joined(separator: ", ")
                let newVals = spec.columns.map { "new.\($0)" }.joined(separator: ", ")
                let oldVals = spec.columns.map { "old.\($0)" }.joined(separator: ", ")
                try db.execute(sql: """
                    CREATE TRIGGER \(spec.source)_ai AFTER INSERT ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    CREATE TRIGGER \(spec.source)_ad AFTER DELETE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                    END;

                    CREATE TRIGGER \(spec.source)_au AFTER UPDATE ON \(spec.source) BEGIN
                        INSERT INTO \(fts)(\(fts), rowid, \(cols))
                        VALUES ('delete', old.id, \(oldVals));
                        INSERT INTO \(fts)(rowid, \(cols))
                        VALUES (new.id, \(newVals));
                    END;

                    INSERT INTO \(fts)(\(fts)) VALUES('rebuild');
                    """)
            }

            // Step 6 — the backfill. Every prompt gets a clarification and an
            // architecture summary so SUMMARY_ABSENT can never again mean
            // "this one is legacy, go read a file". Placeholders land at
            // terminal status (complete / approved) so no lifecycle gate sees
            // a half-open summary, and carry ZERO child rows — a placeholder
            // asserts nothing it cannot back up. The body is a pointer to the
            // on-disk file, which stays the real record.
            let now = Store.isoNow()

            let missingClarification = try Row.fetchAll(db, sql: """
                SELECT p.uuid AS prompt_uuid, p.ckfs_relative_storage_path AS storage_path
                  FROM prompt p
                 WHERE NOT EXISTS (
                     SELECT 1 FROM clarification_summary c WHERE c.prompt_uuid = p.uuid
                 )
                """)
            for row in missingClarification {
                let promptUuid: String = row["prompt_uuid"]
                let storagePath: String = row["storage_path"]
                let pointer = """
                    m0005 placeholder. This prompt predates db-native \
                    clarifications; the real record, if any, is the file at \
                    \(storagePath)/memory/qualified.md
                    """
                try db.execute(sql: """
                    INSERT INTO clarification_summary
                        (uuid, version, created_at, updated_at, prompt_uuid,
                         status, backstory_note, refined_goal, refined_detail)
                    VALUES (?, 0, ?, ?, ?, 'complete', ?, ?, ?)
                    """, arguments: [
                        UUID().uuidString.lowercased(), now, now, promptUuid,
                        "Backfilled by m0005; not authored by a bot run.",
                        pointer, pointer,
                    ])
            }

            let missingArchitecture = try Row.fetchAll(db, sql: """
                SELECT p.uuid AS prompt_uuid, p.ckfs_relative_storage_path AS storage_path
                  FROM prompt p
                 WHERE NOT EXISTS (
                     SELECT 1 FROM architecture_summary a WHERE a.prompt_uuid = p.uuid
                 )
                """)
            for row in missingArchitecture {
                let promptUuid: String = row["prompt_uuid"]
                let storagePath: String = row["storage_path"]
                let pointer = """
                    m0005 placeholder. This prompt predates db-native \
                    architectures; the real record, if any, is the file at \
                    \(storagePath)/memory/architecture.md
                    """
                try db.execute(sql: """
                    INSERT INTO architecture_summary
                        (uuid, version, created_at, updated_at, prompt_uuid,
                         body, status)
                    VALUES (?, 0, ?, ?, ?, ?, 'approved')
                    """, arguments: [
                        UUID().uuidString.lowercased(), now, now, promptUuid, pointer,
                    ])
            }

            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [5, Store.isoNow()]
            )
        }


        // m0006 — un-backfill the draft prompts m0005 overreached on.
        //
        // m0005 gave a placeholder clarification + architecture summary to
        // EVERY prompt missing one, so that SUMMARY_ABSENT could never again
        // mean "this prompt is legacy, go read a file". For a prompt that has
        // moved through the lifecycle that is right. For one still at `draft`
        // it is not: the placeholders land at terminal status (complete /
        // approved), and CLARIFY_ASK only accepts rows while the summary is
        // `building` — with no edge back to `building` from either later
        // state. A draft prompt would therefore be unable to author its own
        // clarification, which is precisely the work it exists to do.
        //
        // Deleting them restores the correct meaning for that population:
        // SUMMARY_ABSENT on a draft prompt means "not opened yet — open one",
        // which is the ordinary non-legacy case and needs no fork. Only rows
        // m0005 itself wrote are touched (matched on its backstory_note
        // marker), and only while the prompt is still `draft`, so nothing a
        // bot authored can be caught by this. The FTS mirrors stay synced
        // through the live `_ad` delete triggers.
        //
        // Landed as its own migration rather than a fix to m0005's body: the
        // migrator keys on the migration id and silently skips a changed body
        // on a db that already ran it, so an edit would leave already-migrated
        // databases diverged from fresh ones forever.
        migrator.registerMigration("m0006_dropDraftPlaceholderSummaries") { db in
            let marker = "Backfilled by m0005; not authored by a bot run."
            try db.execute(sql: """
                DELETE FROM clarification_summary
                 WHERE backstory_note = ?
                   AND prompt_uuid IN (SELECT uuid FROM prompt WHERE status = 'draft')
                """, arguments: [marker])
            // The architecture placeholder carries no note column, so it is
            // identified by the body m0005 wrote plus the same draft filter.
            try db.execute(sql: """
                DELETE FROM architecture_summary
                 WHERE body LIKE 'm0005 placeholder.%'
                   AND prompt_uuid IN (SELECT uuid FROM prompt WHERE status = 'draft')
                """)
            try db.execute(
                sql: "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                arguments: [6, Store.isoNow()]
            )
        }

        return migrator
    }
}
