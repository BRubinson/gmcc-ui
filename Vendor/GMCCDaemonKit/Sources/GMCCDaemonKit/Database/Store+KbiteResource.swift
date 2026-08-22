import Foundation
import GRDB

// KBITE_DIGEST / KBITE_GET / KBITE_FILE_GET / KBITE_SEARCH /
// KBITE_KEYWORD_TAG — the digested-content family over the m0002 tables.
// The db is canonical for digested text; the filesystem keeps raw sources
// (re-chewable) and open maws.

extension Store {
    /// Raw file content larger than this stays filesystem-only (row gets a
    /// NULL content, like binaries).
    private static let maxInlineContentBytes = 2 * 1024 * 1024

    /// The one-step import. Walks {open}/{axis1}/{axis2}/*_chewed.md, parses
    /// each chewed artifact, and writes resource/file/keyword rows in ONE
    /// transaction — re-digesting a resource replaces its previous rows.
    /// Chewed files are deleted only AFTER the commit succeeds (a rollback
    /// never destroys the artifacts); raw sources are always kept.
    public func digestKbite(_ req: KbiteDigestRequest) throws -> KbiteDigestResponse {
        let fm = FileManager.default
        let openURL = URL(fileURLWithPath: req.kbiteOpenPath, isDirectory: true)

        // Scan the maw up front — pure filesystem, no reason to hold the
        // write lock for it.
        var found: [(artifact: ChewedArtifact, axis1: String, axis2: String, chewedPath: String)] = []
        for axis1 in ["primary", "secondary"] {
            for axis2 in ["documentation", "example_project", "api_reference", "blogs", "all_others"] {
                let dir = openURL.appendingPathComponent(axis1, isDirectory: true)
                    .appendingPathComponent(axis2, isDirectory: true)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names.sorted() where name.hasSuffix("_chewed.md") {
                    let chewedURL = dir.appendingPathComponent(name)
                    guard let text = try? String(contentsOf: chewedURL, encoding: .utf8) else { continue }
                    let fallback = String(name.dropLast("_chewed.md".count))
                    var artifact = ChewedArtifactParser.parse(text: text, fallbackName: fallback)
                    // Entries with no absolute path resolve against the
                    // sibling raw-source folder ({axis2}/{resource_name}/).
                    let sourceDir = dir.appendingPathComponent(artifact.resourceName, isDirectory: true)
                    artifact = ChewedArtifact(
                        resourceName: artifact.resourceName,
                        confidence: artifact.confidence,
                        body: artifact.body,
                        files: artifact.files.map { entry in
                            entry.fullPath != nil ? entry : ChewedFileEntry(
                                name: entry.name,
                                type: entry.type,
                                description: entry.description,
                                fullPath: sourceDir.appendingPathComponent(entry.name).path)
                        },
                        keywords: artifact.keywords
                    )
                    found.append((artifact, axis1, axis2, chewedURL.path))
                }
            }
        }

        // Raw-source content is also read up front — inlineContent stats and
        // reads up to 2 MB per file, which must not happen while the single
        // serialized connection holds the write lock.
        let inlinedContents: [[String?]] = found.map { item in
            item.artifact.files.map { self.inlineContent($0) }
        }

        var resourceCount = 0
        var fileCount = 0
        var attachedKeywords: Set<String> = []

        let kbiteUuid = try dbQueue.write { db -> String in
            let kbiteUuid = try self.ensureKbite(db, code: req.code)
            for (itemIndex, item) in found.enumerated() {
                // Replace an earlier digest of the same resource: the CASCADE
                // clears its files/junctions and the FTS triggers keep the
                // mirror in sync (recursive_triggers is ON).
                try db.execute(
                    sql: "DELETE FROM kbite_resource WHERE kbite_uuid = ? AND resource_name = ?",
                    arguments: [kbiteUuid, item.artifact.resourceName])
                let resourceUuid = try self.insertBase(db, table: "kbite_resource", extra: [
                    "kbite_uuid": kbiteUuid,
                    "resource_name": item.artifact.resourceName,
                    "resource_summary": item.artifact.body,
                    "resource_type": item.axis2,
                    "resource_trust": item.axis1 == "primary" ? 0 : 100,
                ])
                resourceCount += 1

                var fileUuids: [String] = []
                for (entryIndex, entry) in item.artifact.files.enumerated() {
                    let content = inlinedContents[itemIndex][entryIndex]
                    let fileUuid = try self.insertBase(db, table: "kbite_resource_file", extra: [
                        "kbite_resource_uuid": resourceUuid,
                        "resource_file_name": entry.name,
                        "resource_file_summary": entry.description,
                        "resource_file_content": content,
                    ])
                    fileUuids.append(fileUuid)
                    fileCount += 1
                }

                for keyword in item.artifact.keywords {
                    let keywordUuid = try self.ensureKeyword(db, keyword)
                    try self.attachKeyword(
                        db, table: "kbite_keyword_junction",
                        ownerColumn: "kbite_uuid", ownerUuid: kbiteUuid, keywordUuid: keywordUuid)
                    for fileUuid in fileUuids {
                        try self.attachKeyword(
                            db, table: "resource_file_keyword_junction",
                            ownerColumn: "file_uuid", ownerUuid: fileUuid, keywordUuid: keywordUuid)
                    }
                    attachedKeywords.insert(keyword)
                }
            }
            try self.appendEvent(
                db, kind: .kbiteDigest, subjectUuid: kbiteUuid,
                payload: Store.jsonPayload([
                    "code": req.code,
                    "resources": resourceCount,
                    "files": fileCount,
                    "keywords": attachedKeywords.count,
                ]))
            return kbiteUuid
        }

        // Commit succeeded — now (and only now) the temporary chewed files go.
        var deleted: [String] = []
        for item in found where (try? fm.removeItem(atPath: item.chewedPath)) != nil {
            deleted.append(item.chewedPath)
        }

        return KbiteDigestResponse(
            kbiteUuid: kbiteUuid,
            resourceCount: resourceCount,
            fileCount: fileCount,
            keywordCount: attachedKeywords.count,
            deletedChewedFiles: deleted
        )
    }

    /// Full text for text types under the size cap; NULL for everything else
    /// (missing, unreadable, binary, oversized) — the row still exists so the
    /// file is discoverable, the filesystem keeps the raw bytes.
    private func inlineContent(_ entry: ChewedFileEntry) -> String? {
        guard let path = entry.fullPath, ChewedArtifactParser.isTextType(fileName: entry.name) else {
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs?[.size] as? Int, size > Store.maxInlineContentBytes {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    public func getKbite(_ req: KbiteGetRequest) throws -> KbiteGetResponse {
        try dbQueue.read { db in
            guard let kbiteRow = try Row.fetchOne(
                db,
                sql: "SELECT uuid, version, code, created_at, updated_at FROM kbite WHERE code = ?",
                arguments: [req.code]
            ) else {
                throw StoreError.notFound(entity: "kbite", key: req.code)
            }
            let kbite = KbiteRow(
                uuid: kbiteRow["uuid"],
                version: kbiteRow["version"],
                code: kbiteRow["code"],
                createdAt: kbiteRow["created_at"],
                updatedAt: kbiteRow["updated_at"]
            )
            var resources: [KbiteResourceRow] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT uuid, kbite_uuid, resource_name, resource_summary, resource_type, resource_trust
                FROM kbite_resource WHERE kbite_uuid = ? ORDER BY resource_name
                """, arguments: [kbite.uuid]) {
                let resourceUuid: String = row["uuid"]
                let stubs = try Row.fetchAll(db, sql: """
                    SELECT uuid, resource_file_name, resource_file_summary,
                           resource_file_content IS NOT NULL AS has_content
                    FROM kbite_resource_file WHERE kbite_resource_uuid = ?
                    ORDER BY resource_file_name
                    """, arguments: [resourceUuid]).map { fileRow in
                    KbiteResourceFileStub(
                        uuid: fileRow["uuid"],
                        resourceFileName: fileRow["resource_file_name"],
                        resourceFileSummary: fileRow["resource_file_summary"],
                        hasContent: fileRow["has_content"]
                    )
                }
                resources.append(KbiteResourceRow(
                    uuid: resourceUuid,
                    kbiteUuid: row["kbite_uuid"],
                    resourceName: row["resource_name"],
                    resourceSummary: row["resource_summary"],
                    resourceType: row["resource_type"],
                    resourceTrust: row["resource_trust"],
                    files: stubs
                ))
            }
            let keywords = try String.fetchAll(db, sql: """
                SELECT kw.keyword FROM keyword kw
                JOIN kbite_keyword_junction j ON j.keyword_uuid = kw.uuid
                WHERE j.kbite_uuid = ? ORDER BY kw.keyword
                """, arguments: [kbite.uuid])
            return KbiteGetResponse(kbite: kbite, resources: resources, keywords: keywords)
        }
    }

    /// The targeted load replacing "cat the chewed file".
    public func getKbiteFile(_ req: KbiteFileGetRequest) throws -> KbiteFileGetResponse {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT uuid, kbite_resource_uuid, resource_file_name, resource_file_summary,
                       resource_file_content, created_at
                FROM kbite_resource_file WHERE uuid = ?
                """, arguments: [req.fileUuid]
            ) else {
                throw StoreError.notFound(entity: "kbite_resource_file", key: req.fileUuid)
            }
            return KbiteFileGetResponse(file: KbiteResourceFileRow(
                uuid: row["uuid"],
                kbiteResourceUuid: row["kbite_resource_uuid"],
                resourceFileName: row["resource_file_name"],
                resourceFileSummary: row["resource_file_summary"],
                resourceFileContent: row["resource_file_content"],
                createdAt: row["created_at"]
            ))
        }
    }

    /// FTS5 query, bm25-ranked (name ≫ summary ≫ content, smaller = better),
    /// optionally scoped to a kbite_uuids list. The MATCH pattern is built by
    /// GRDB from the raw query — user text never reaches SQL.
    public func searchKbites(_ req: KbiteSearchRequest) throws -> KbiteSearchResponse {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: req.query) else {
            return KbiteSearchResponse(hits: [])
        }
        return try dbQueue.read { db in
            let limit = min(max(req.limit ?? 50, 1), 500)
            var sql = """
                SELECT k.code AS kbite_code, kr.kbite_uuid AS kbite_uuid,
                       kr.resource_name AS resource_name,
                       f.uuid AS file_uuid, f.resource_file_name AS file_name,
                       f.resource_file_summary AS file_summary,
                       bm25(kbite_resource_file_fts, 10.0, 5.0, 1.0) AS score,
                       (SELECT group_concat(kw.keyword, ',')
                          FROM resource_file_keyword_junction j
                          JOIN keyword kw ON kw.uuid = j.keyword_uuid
                         WHERE j.file_uuid = f.uuid) AS matched_keywords
                FROM kbite_resource_file_fts fts
                JOIN kbite_resource_file f ON f.id = fts.rowid
                JOIN kbite_resource kr ON kr.uuid = f.kbite_resource_uuid
                JOIN kbite k ON k.uuid = kr.kbite_uuid
                WHERE kbite_resource_file_fts MATCH ?
                """
            var arguments: [any DatabaseValueConvertible] = [pattern]
            if let kbiteUuids = req.kbiteUuids, !kbiteUuids.isEmpty {
                let placeholders = Array(repeating: "?", count: kbiteUuids.count).joined(separator: ", ")
                sql += " AND kr.kbite_uuid IN (\(placeholders))"
                arguments.append(contentsOf: kbiteUuids)
            }
            sql += " ORDER BY score LIMIT \(limit)"
            return KbiteSearchResponse(hits: try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(arguments)
            ).map { row in
                let joined: String? = row["matched_keywords"]
                return KbiteSearchHit(
                    kbiteCode: row["kbite_code"],
                    kbiteUuid: row["kbite_uuid"],
                    resourceName: row["resource_name"],
                    fileUuid: row["file_uuid"],
                    fileName: row["file_name"],
                    fileSummary: row["file_summary"],
                    matchedKeywords: joined?.split(separator: ",").map(String.init) ?? [],
                    score: row["score"]
                )
            })
        }
    }

    /// Attach/detach normalized keywords at kbite or resource-file level.
    public func tagKeyword(_ req: KbiteKeywordTagRequest) throws -> KbiteKeywordTagResponse {
        try dbQueue.write { db in
            let (table, ownerColumn, ownerTable): (String, String, String)
            switch req.level {
            case .kbite:
                (table, ownerColumn, ownerTable) = ("kbite_keyword_junction", "kbite_uuid", "kbite")
            case .file:
                (table, ownerColumn, ownerTable) =
                    ("resource_file_keyword_junction", "file_uuid", "kbite_resource_file")
            }
            guard try Row.fetchOne(
                db, sql: "SELECT 1 FROM \(ownerTable) WHERE uuid = ?", arguments: [req.targetUuid]
            ) != nil else {
                throw StoreError.notFound(entity: ownerTable, key: req.targetUuid)
            }

            var attached = 0
            var detached = 0
            for raw in req.keywords {
                let keyword = ChewedArtifactParser.normalizeKeyword(raw)
                guard !keyword.isEmpty else { continue }
                if req.detach {
                    guard let keywordUuid = try String.fetchOne(
                        db, sql: "SELECT uuid FROM keyword WHERE keyword = ?", arguments: [keyword]
                    ) else { continue }
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE \(ownerColumn) = ? AND keyword_uuid = ?",
                        arguments: [req.targetUuid, keywordUuid])
                    detached += db.changesCount
                } else {
                    let keywordUuid = try self.ensureKeyword(db, keyword)
                    if try self.attachKeyword(
                        db, table: table, ownerColumn: ownerColumn,
                        ownerUuid: req.targetUuid, keywordUuid: keywordUuid) {
                        attached += 1
                    }
                }
            }
            if attached > 0 || detached > 0 {
                try self.appendEvent(
                    db, kind: .kbiteKeywordTag, subjectUuid: req.targetUuid,
                    payload: Store.jsonPayload([
                        "level": req.level.rawValue,
                        "attached": attached,
                        "detached": detached,
                    ]))
            }
            return KbiteKeywordTagResponse(attached: attached, detached: detached)
        }
    }

    // MARK: - Keyword primitives

    /// Upsert the shared vocabulary by normalized text (mirrors ensureKbite).
    func ensureKeyword(_ db: Database, _ keyword: String) throws -> String {
        if let existing = try String.fetchOne(
            db, sql: "SELECT uuid FROM keyword WHERE keyword = ?", arguments: [keyword]
        ) {
            return existing
        }
        return try insertBase(db, table: "keyword", extra: ["keyword": keyword])
    }

    /// Idempotent junction insert; returns whether a row was created.
    @discardableResult
    private func attachKeyword(
        _ db: Database, table: String, ownerColumn: String, ownerUuid: String, keywordUuid: String
    ) throws -> Bool {
        let exists = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM \(table) WHERE \(ownerColumn) = ? AND keyword_uuid = ?",
            arguments: [ownerUuid, keywordUuid]) != nil
        guard !exists else { return false }
        try insertBase(db, table: table, extra: [
            ownerColumn: ownerUuid,
            "keyword_uuid": keywordUuid,
        ])
        return true
    }
}
