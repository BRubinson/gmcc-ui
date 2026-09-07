import Foundation
import GRDB

/// DOPED domain modeling — scope lifecycle, tree hydration, and the generic
/// per-level node mutations. Whole-tree repo verbs live in Store+DopeRepo.
///
/// Two counters, deliberately split (the touchSession precedent): every row's
/// `version` stays THE optimistic lock, while `dope_scope.revision` is the
/// whole-tree content counter (= the .doped.json version field), advanced by
/// `bumpScopeRevision` WITHOUT touching the scope row's version — a property
/// edit deep in the tree must never invalidate a dope_scope version a
/// GMVibes scope editor is holding.
extension Store {

    // MARK: - Level description limits (pre-validated for friendly errors;
    // the schema CHECKs are the backstop)

    private static let dopeDescriptionLimits: [DopeLevel: Int] = [
        .scope: 512, .domain: 512, .entity: 512,
        .enumeration: 256, .option: 128, .property: 128,
    ]

    // MARK: - Row + scope helpers

    func fetchDopeScope(_ db: Database, uuid: String) throws -> DopeScopeRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM dope_scope WHERE uuid = ?", arguments: [uuid])
            .map(Self.dopeScopeRow)
    }

    private static func dopeScopeRow(_ row: Row) -> DopeScopeRow {
        DopeScopeRow(
            uuid: row["uuid"], version: row["version"],
            sessionUuid: row["session_uuid"], promptUuid: row["prompt_uuid"],
            scopeType: row["scope_type"], code: row["code"], name: row["name"],
            description: row["description"], revision: row["revision"],
            createdAt: row["created_at"], updatedAt: row["updated_at"])
    }

    /// Advance the whole-tree content counter WITHOUT bumping the scope row's
    /// version — see the extension doc comment and Store.touchSession.
    @discardableResult
    func bumpScopeRevision(_ db: Database, scopeUuid: String) throws -> Int64 {
        try db.execute(
            sql: "UPDATE dope_scope SET revision = revision + 1, updated_at = ? WHERE uuid = ?",
            arguments: [Store.isoNow(), scopeUuid])
        guard let revision = try Int64.fetchOne(
            db, sql: "SELECT revision FROM dope_scope WHERE uuid = ?", arguments: [scopeUuid]
        ) else {
            throw StoreError.notFound(entity: "dope_scope", key: scopeUuid)
        }
        return revision
    }

    /// Session-keyed twin of the promptUuid variant in Store+Architecture —
    /// dope's repo verbs are scope-addressed and scopes hang off sessions.
    func instanceRoot(_ db: Database, sessionUuid: String) throws -> String {
        try String.fetchOne(db, sql: """
            SELECT i.absolute_file_system_path
            FROM session s
            JOIN instance i ON i.uuid = s.instance_uuid
            WHERE s.uuid = ?
            """, arguments: [sessionUuid]) ?? ""
    }

    /// Resolve the scope that owns a node at `level`. The join chains are the
    /// registry's parent links spelled out as SQL.
    func dopeOwningScope(_ db: Database, level: DopeLevel, nodeUuid: String) throws -> DopeScopeRow {
        let sql: String
        switch level {
        case .scope:
            sql = "SELECT s.* FROM dope_scope s WHERE s.uuid = ?"
        case .domain:
            sql = """
                SELECT s.* FROM dope_domain d
                JOIN dope_scope s ON s.uuid = d.dope_scope_uuid WHERE d.uuid = ?
                """
        case .entity:
            sql = """
                SELECT s.* FROM dope_domain_entity e
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                JOIN dope_scope s ON s.uuid = d.dope_scope_uuid WHERE e.uuid = ?
                """
        case .property:
            sql = """
                SELECT s.* FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                JOIN dope_scope s ON s.uuid = d.dope_scope_uuid WHERE p.uuid = ?
                """
        case .enumeration:
            sql = """
                SELECT s.* FROM dope_domain_enum n
                JOIN dope_domain d ON d.uuid = n.dope_domain_uuid
                JOIN dope_scope s ON s.uuid = d.dope_scope_uuid WHERE n.uuid = ?
                """
        case .option:
            sql = """
                SELECT s.* FROM dope_domain_enum_option o
                JOIN dope_domain_enum n ON n.uuid = o.dope_domain_enum_uuid
                JOIN dope_domain d ON d.uuid = n.dope_domain_uuid
                JOIN dope_scope s ON s.uuid = d.dope_scope_uuid WHERE o.uuid = ?
                """
        }
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [nodeUuid]) else {
            throw StoreError.notFound(
                entity: DopeLevelSpec.spec(for: level).table, key: nodeUuid)
        }
        return Self.dopeScopeRow(row)
    }

    private func recordDopeChange(
        _ db: Database, scope: DopeScopeRow, action: String, level: DopeLevel?,
        nodeUuid: String?, revision: Int64
    ) throws {
        var payload: [String: Any] = [
            "action": action,
            "scope_uuid": scope.uuid,
            "session_uuid": scope.sessionUuid,
            "scope_type": scope.scopeType,
            "revision": Int(revision),
        ]
        if let level { payload["level"] = level.rawValue }
        if let nodeUuid { payload["node_uuid"] = nodeUuid }
        if let promptUuid = scope.promptUuid { payload["prompt_uuid"] = promptUuid }
        try appendEvent(db, kind: .dopeChange, subjectUuid: scope.uuid,
                        payload: Store.jsonPayload(payload))
        try touchSession(db, uuid: scope.sessionUuid)
    }

    // MARK: - Init

    public func dopeInit(_ req: DopeInitRequest) throws -> DopeScopeResponse {
        try DopeCode.validateCode(req.code, field: "scope code")
        let description = req.description ?? ""
        guard description.count <= 512 else {
            throw StoreError.badRequest(detail: "scope description exceeds 512 characters")
        }
        return try dbQueue.write { db in
            guard try Row.fetchOne(
                db, sql: "SELECT uuid FROM session WHERE uuid = ?", arguments: [req.sessionUuid]
            ) != nil else {
                throw StoreError.notFound(entity: "session", key: req.sessionUuid)
            }
            if let promptUuid = req.promptUuid {
                guard let owner = try String.fetchOne(
                    db, sql: "SELECT session_uuid FROM prompt WHERE uuid = ?",
                    arguments: [promptUuid]
                ) else {
                    throw StoreError.notFound(entity: "prompt", key: promptUuid)
                }
                guard owner == req.sessionUuid else {
                    throw StoreError.badRequest(
                        detail: "prompt \(promptUuid) does not belong to session \(req.sessionUuid)")
                }
            }

            let scopeType: DopeScopeType = req.promptUuid == nil ? .sessionBase : .prompt
            let existingSql = req.promptUuid == nil
                ? "SELECT * FROM dope_scope WHERE session_uuid = ? AND scope_type = 'SESSION_BASE' AND code = ?"
                : "SELECT * FROM dope_scope WHERE session_uuid = ? AND prompt_uuid = ? AND scope_type = 'PROMPT' AND code = ?"
            let existingArgs: StatementArguments = req.promptUuid == nil
                ? [req.sessionUuid, req.code]
                : [req.sessionUuid, req.promptUuid, req.code]
            if let row = try Row.fetchOne(db, sql: existingSql, arguments: existingArgs) {
                return DopeScopeResponse(scope: Self.dopeScopeRow(row), created: false)
            }

            let uuid = try self.insertBase(db, table: "dope_scope", extra: [
                "session_uuid": req.sessionUuid,
                "prompt_uuid": req.promptUuid,
                "scope_type": scopeType.rawValue,
                "code": req.code,
                "name": req.name,
                "description": description,
                "revision": 0,
            ])

            if req.cloneFromSessionBase == true {
                guard req.promptUuid != nil else {
                    throw StoreError.badRequest(
                        detail: "--clone-from-session-base is only meaningful for a PROMPT scope")
                }
                guard let baseRow = try Row.fetchOne(db, sql: """
                    SELECT * FROM dope_scope
                    WHERE session_uuid = ? AND scope_type = 'SESSION_BASE' AND code = ?
                    """, arguments: [req.sessionUuid, req.code]) else {
                    throw StoreError.badRequest(
                        detail: "no SESSION_BASE scope with code '\(req.code)' to clone from")
                }
                let baseTree = try self.fetchDopeTree(db, scope: Self.dopeScopeRow(baseRow))
                let bundle = DopeProjection.documents(from: baseTree)
                _ = try self.insertDopeTree(db, scopeUuid: uuid, domainFiles: bundle.domainFiles)
            }

            guard let scope = try self.fetchDopeScope(db, uuid: uuid) else {
                throw StoreError.corruptState(entity: "dope_scope", detail: "vanished after insert")
            }
            try self.recordDopeChange(db, scope: scope, action: "init", level: .scope,
                                      nodeUuid: uuid, revision: scope.revision)
            return DopeScopeResponse(scope: scope, created: true)
        }
    }

    // MARK: - Read-verb guards + shared candidate query

    /// dopeInit's existence validation (minus the ownership check, a
    /// write-verb concern), hoisted so the read verbs can discriminate an
    /// unknown uuid (NOT_FOUND) from a real-but-uninitialized target
    /// (SUMMARY_ABSENT) — the clarify/arch/explore/review get pattern.
    private func requireDopeTarget(
        _ db: Database, sessionUuid: String, promptUuid: String?
    ) throws {
        guard try Row.fetchOne(
            db, sql: "SELECT uuid FROM session WHERE uuid = ?", arguments: [sessionUuid]
        ) != nil else {
            throw StoreError.notFound(entity: "session", key: sessionUuid)
        }
        if let promptUuid {
            guard try Row.fetchOne(
                db, sql: "SELECT uuid FROM prompt WHERE uuid = ?", arguments: [promptUuid]
            ) != nil else {
                throw StoreError.notFound(entity: "prompt", key: promptUuid)
            }
        }
    }

    /// The scope-candidate query shared by dopeGet's resolution ladder and
    /// dopeList's enumeration — one copy keeps the picker's row order and
    /// the BAD_REQUEST candidate order identical (ORDER BY code).
    // internal, not private: Store+Diagram's binding resolution reuses this
    // exact ladder query (the v12 candidates() promotion precedent).
    func dopeScopeCandidates(
        _ db: Database, sessionUuid: String, scopeType: DopeScopeType,
        promptUuid: String? = nil, code: String? = nil
    ) throws -> [DopeScopeRow] {
        var sql = "SELECT * FROM dope_scope WHERE session_uuid = ? AND scope_type = ?"
        var args: [(any DatabaseValueConvertible)?] = [sessionUuid, scopeType.rawValue]
        if scopeType == .prompt {
            sql += " AND prompt_uuid = ?"
            args.append(promptUuid)
        }
        if let code {
            sql += " AND code = ?"
            args.append(code)
        }
        sql += " ORDER BY code"
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            .map(Self.dopeScopeRow)
    }

    // MARK: - List (v12; picker enumeration — never a PROMPT/SESSION_BASE union)

    public func dopeList(_ req: DopeListRequest) throws -> DopeListResponse {
        try dbQueue.read { db in
            try self.requireDopeTarget(
                db, sessionUuid: req.sessionUuid, promptUuid: req.promptUuid)
            let scopes: [DopeScopeRow]
            if let promptUuid = req.promptUuid {
                scopes = try self.dopeScopeCandidates(
                    db, sessionUuid: req.sessionUuid, scopeType: .prompt,
                    promptUuid: promptUuid)
            } else {
                scopes = try self.dopeScopeCandidates(
                    db, sessionUuid: req.sessionUuid, scopeType: .sessionBase)
            }
            return DopeListResponse(scopes: scopes)
        }
    }

    // MARK: - Get (PROMPT → SESSION_BASE fallback)

    public func dopeGet(_ req: DopeGetRequest) throws -> DopeGetResponse {
        try dbQueue.read { db in
            try self.requireDopeTarget(
                db, sessionUuid: req.sessionUuid, promptUuid: req.promptUuid)

            func pick(_ rows: [DopeScopeRow]) throws -> DopeScopeRow? {
                if rows.count > 1 {
                    throw StoreError.badRequest(detail:
                        "several dope scopes match — pass --code (candidates: "
                        + rows.map(\.code).joined(separator: ", ") + ")")
                }
                return rows.first
            }

            var resolvedVia = "session_base"
            var scope: DopeScopeRow?
            if let promptUuid = req.promptUuid {
                scope = try pick(try self.dopeScopeCandidates(
                    db, sessionUuid: req.sessionUuid, scopeType: .prompt,
                    promptUuid: promptUuid, code: req.code))
                if scope != nil { resolvedVia = "prompt" }
            }
            if scope == nil {
                scope = try pick(try self.dopeScopeCandidates(
                    db, sessionUuid: req.sessionUuid, scopeType: .sessionBase,
                    code: req.code))
            }
            guard let scope else {
                // The target exists (guard above) — this absence means
                // "initialize a scope", not "the uuid is unknown".
                throw StoreError.dopeScopeAbsent(
                    sessionUuid: req.sessionUuid, promptUuid: req.promptUuid, code: req.code)
            }
            let tree = try self.fetchDopeTree(db, scope: scope)
            return DopeGetResponse(tree: tree, resolvedVia: resolvedVia)
        }
    }

    // MARK: - Hydration (five flat queries, grouped in Swift — never per-node
    // recursion; ORDER BY sort_order, code keeps write-repo deterministic)

    func fetchDopeTree(_ db: Database, scope: DopeScopeRow) throws -> DopeScopeTree {
        let domainRows = try Row.fetchAll(db, sql: """
            SELECT * FROM dope_domain WHERE dope_scope_uuid = ?
            ORDER BY sort_order, code
            """, arguments: [scope.uuid])
        let entityRows = try Row.fetchAll(db, sql: """
            SELECT e.* FROM dope_domain_entity e
            JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
            WHERE d.dope_scope_uuid = ? ORDER BY e.sort_order, e.code
            """, arguments: [scope.uuid])
        let enumRows = try Row.fetchAll(db, sql: """
            SELECT n.* FROM dope_domain_enum n
            JOIN dope_domain d ON d.uuid = n.dope_domain_uuid
            WHERE d.dope_scope_uuid = ? ORDER BY n.sort_order, n.code
            """, arguments: [scope.uuid])
        let optionRows = try Row.fetchAll(db, sql: """
            SELECT o.* FROM dope_domain_enum_option o
            JOIN dope_domain_enum n ON n.uuid = o.dope_domain_enum_uuid
            JOIN dope_domain d ON d.uuid = n.dope_domain_uuid
            WHERE d.dope_scope_uuid = ? ORDER BY o.sort_order, o.code
            """, arguments: [scope.uuid])
        let propertyRows = try Row.fetchAll(db, sql: """
            SELECT p.* FROM dope_domain_entity_property p
            JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
            JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
            WHERE d.dope_scope_uuid = ? ORDER BY p.sort_order, p.code
            """, arguments: [scope.uuid])

        // Ref projection maps: uuid → dot-path code.
        var domainCode = [String: String]()
        for row in domainRows { domainCode[row["uuid"]] = row["code"] }
        var entityInfo = [String: (domain: String, code: String)]()
        var entityRef = [String: String]()
        for row in entityRows {
            let domain = domainCode[row["dope_domain_uuid"]] ?? "?"
            entityInfo[row["uuid"]] = (domain, row["code"])
            entityRef[row["uuid"]] = DopeCode.formatEntityRef(
                domain: domain, entity: row["code"])
        }
        var enumRef = [String: String]()
        for row in enumRows {
            let domain = domainCode[row["dope_domain_uuid"]] ?? "?"
            enumRef[row["uuid"]] = DopeCode.formatEnumRef(domain: domain, enumCode: row["code"])
        }
        var propertyRef = [String: String]()
        for row in propertyRows {
            let info = entityInfo[row["dope_domain_entity_uuid"]] ?? (domain: "?", code: "?")
            propertyRef[row["uuid"]] = DopeCode.formatPropertyRef(
                domain: info.domain, entity: info.code, property: row["code"])
        }

        func identity(_ row: Row) -> DopeNodeIdentity {
            DopeNodeIdentity(uuid: row["uuid"], version: row["version"],
                             createdAt: row["created_at"], updatedAt: row["updated_at"])
        }

        var propertiesByEntity = [String: [DopePropertyNode]]()
        for row in propertyRows {
            let node = DopePropertyNode(
                identity: identity(row),
                body: DopePropertyBody(
                    code: row["code"], name: row["name"], description: row["description"],
                    sortOrder: row["sort_order"], dataType: row["data_type"],
                    nullable: (row["nullable"] as Int64) != 0,
                    isUnique: (row["is_unique"] as Int64) != 0,
                    autoIncrement: (row["auto_increment"] as Int64?).map { $0 != 0 },
                    textCharLimit: row["text_char_limit"],
                    enumRef: (row["dope_domain_enum_uuid"] as String?).flatMap { enumRef[$0] },
                    relatedPropertyRef: (row["related_property_uuid"] as String?)
                        .flatMap { propertyRef[$0] },
                    baseOriginRef: (row["base_origin_property_uuid"] as String?)
                        .flatMap { propertyRef[$0] }))
            propertiesByEntity[row["dope_domain_entity_uuid"], default: []].append(node)
        }
        var optionsByEnum = [String: [DopeOptionNode]]()
        for row in optionRows {
            optionsByEnum[row["dope_domain_enum_uuid"], default: []].append(
                DopeOptionNode(identity: identity(row),
                               body: DopeOptionBody(code: row["code"], name: row["name"],
                                                    description: row["description"],
                                                    sortOrder: row["sort_order"])))
        }
        var entitiesByDomain = [String: [DopeEntityNode]]()
        for row in entityRows {
            entitiesByDomain[row["dope_domain_uuid"], default: []].append(
                DopeEntityNode(identity: identity(row),
                               body: DopeEntityBody(
                                    code: row["code"], name: row["name"],
                                    entityType: row["entity_type"],
                                    description: row["description"],
                                    sortOrder: row["sort_order"],
                                    repoRepresentativeFile: row["repo_representative_file"],
                                    baseComposableRef: (row["base_composable_uuid"] as String?)
                                        .flatMap { entityRef[$0] }),
                               properties: propertiesByEntity[row["uuid"]] ?? []))
        }
        var enumsByDomain = [String: [DopeEnumNode]]()
        for row in enumRows {
            enumsByDomain[row["dope_domain_uuid"], default: []].append(
                DopeEnumNode(identity: identity(row),
                             body: DopeEnumBody(
                                code: row["code"], name: row["name"],
                                description: row["description"], sortOrder: row["sort_order"],
                                repoRepresentativeFile: row["repo_representative_file"]),
                             options: optionsByEnum[row["uuid"]] ?? []))
        }
        let domains = domainRows.map { row in
            DopeDomainNode(identity: identity(row),
                           body: DopeDomainBody(code: row["code"], name: row["name"],
                                                description: row["description"],
                                                sortOrder: row["sort_order"]),
                           entities: entitiesByDomain[row["uuid"]] ?? [],
                           enums: enumsByDomain[row["uuid"]] ?? [])
        }
        return DopeScopeTree(
            identity: DopeNodeIdentity(uuid: scope.uuid, version: scope.version,
                                       createdAt: scope.createdAt, updatedAt: scope.updatedAt),
            body: DopeScopeBody(code: scope.code, name: scope.name,
                                description: scope.description),
            sessionUuid: scope.sessionUuid, promptUuid: scope.promptUuid,
            scopeType: scope.scopeType, revision: scope.revision, domains: domains)
    }

    // MARK: - Whole-tree insert (clone + ingest share it). Documents in,
    // rows out; validator-approved input assumed (callers validate first).
    // Insert order is dependency order: domains → enums → options → entities
    // → non-relationship properties → relationship properties.

    @discardableResult
    func insertDopeTree(
        _ db: Database, scopeUuid: String, domainFiles: [DopeDomainFileDocument]
    ) throws -> DopeTreeCounts {
        var counts = (domains: 0, entities: 0, properties: 0, enums: 0, options: 0)
        var domainUuidByCode = [String: String]()
        var enumUuidByRef = [String: String]()
        var propertyUuidByRef = [String: String]()
        var entityUuidByRef = [String: String]()
        var entityRefByUuid = [String: String]()
        var pendingRelationship: [(entityUuid: String, body: DopePropertyBody)] = []
        var pendingBase: [(entityUuid: String, ref: String)] = []
        var pendingBaseOrigin: [(propertyUuid: String, ref: String)] = []

        // Pass 1 — ALL domains, then ALL enums + options, across every file
        // BEFORE any property is inserted: enum refs are cross-domain-capable
        // and domain files arrive in arbitrary (alphabetical) order, so a
        // per-domain forward pass would miss a ref into a later domain and
        // write NULL into a CHECK-coupled column.
        for file in domainFiles {
            let domainUuid = try insertBase(db, table: "dope_domain", extra: [
                "dope_scope_uuid": scopeUuid,
                "code": file.body.code, "name": file.body.name,
                "description": file.body.description, "sort_order": file.body.sortOrder,
            ])
            counts.domains += 1
            domainUuidByCode[file.body.code] = domainUuid
        }
        for file in domainFiles {
            let domainUuid = domainUuidByCode[file.body.code]!
            for en in file.enums {
                let enumUuid = try insertBase(db, table: "dope_domain_enum", extra: [
                    "dope_domain_uuid": domainUuid,
                    "code": en.body.code, "name": en.body.name,
                    "description": en.body.description, "sort_order": en.body.sortOrder,
                    "repo_representative_file": en.body.repoRepresentativeFile,
                ])
                counts.enums += 1
                enumUuidByRef[DopeCode.formatEnumRef(
                    domain: file.body.code, enumCode: en.body.code)] = enumUuid
                for option in en.options {
                    _ = try insertBase(db, table: "dope_domain_enum_option", extra: [
                        "dope_domain_enum_uuid": enumUuid,
                        "code": option.body.code, "name": option.body.name,
                        "description": option.body.description,
                        "sort_order": option.body.sortOrder,
                    ])
                    counts.options += 1
                }
            }
        }

        // Pass 2 — entities + non-relationship properties (every enum target
        // now exists; a missed enum lookup is a loud error, never a NULL).
        for file in domainFiles {
            let domainUuid = domainUuidByCode[file.body.code]!
            for entity in file.entities {
                let entityUuid = try insertBase(db, table: "dope_domain_entity", extra: [
                    "dope_domain_uuid": domainUuid,
                    "code": entity.body.code, "name": entity.body.name,
                    "entity_type": entity.body.entityType,
                    "description": entity.body.description,
                    "sort_order": entity.body.sortOrder,
                    "repo_representative_file": entity.body.repoRepresentativeFile,
                ])
                counts.entities += 1
                let entityRef = DopeCode.formatEntityRef(
                    domain: file.body.code, entity: entity.body.code)
                entityUuidByRef[entityRef] = entityUuid
                entityRefByUuid[entityUuid] = entityRef
                if let ref = entity.body.baseComposableRef {
                    pendingBase.append((entityUuid, ref))
                }
                for property in entity.properties {
                    let body = property.body
                    if body.dataType == DopePropertyDataType.relationship.rawValue {
                        pendingRelationship.append((entityUuid, body))
                        continue
                    }
                    var enumUuid: String?
                    if let enumRef = body.enumRef {
                        guard let resolved = enumUuidByRef[enumRef] else {
                            throw StoreError.badRequest(
                                detail: "enum property '\(body.code)' ref '\(enumRef)' did not resolve during insert")
                        }
                        enumUuid = resolved
                    }
                    let uuid = try insertBase(db, table: "dope_domain_entity_property", extra: [
                        "dope_domain_entity_uuid": entityUuid,
                        "code": body.code, "name": body.name,
                        "description": body.description, "sort_order": body.sortOrder,
                        "data_type": body.dataType,
                        "nullable": body.nullable ? 1 : 0,
                        "is_unique": body.isUnique ? 1 : 0,
                        "auto_increment": body.autoIncrement.map { $0 ? 1 : 0 },
                        "text_char_limit": body.textCharLimit,
                        "dope_domain_enum_uuid": enumUuid,
                        "related_property_uuid": nil,
                    ])
                    counts.properties += 1
                    propertyUuidByRef[DopeCode.formatPropertyRef(
                        domain: file.body.code, entity: entity.body.code,
                        property: body.code)] = uuid
                    if let originRef = body.baseOriginRef {
                        pendingBaseOrigin.append((uuid, originRef))
                    }
                }
            }
        }
        // Pass 3 — base_composable back-fill, after ALL entities exist across
        // ALL files: base refs are cross-domain-capable like enum refs, so an
        // inline resolve would miss a forward ref into a later file. A plain
        // UPDATE, not updateBase — these are fresh rows and the whole-tree
        // counter is dope_scope.revision, so row version stays 0.
        for pending in pendingBase {
            guard let target = entityUuidByRef[pending.ref] else {
                throw StoreError.badRequest(
                    detail: "entity base_composable_ref '\(pending.ref)' did not resolve during insert")
            }
            try db.execute(
                sql: "UPDATE dope_domain_entity SET base_composable_uuid = ? WHERE uuid = ?",
                arguments: [target, pending.entityUuid])
        }
        // Relationship properties last: the validator bans chain refs, so
        // every target is a non-relationship property inserted above.
        for pending in pendingRelationship {
            let body = pending.body
            guard let ref = body.relatedPropertyRef,
                  let target = propertyUuidByRef[ref] else {
                throw StoreError.badRequest(
                    detail: "relationship property '\(body.code)' target '\(body.relatedPropertyRef ?? "nil")' did not resolve during insert")
            }
            let uuid = try insertBase(db, table: "dope_domain_entity_property", extra: [
                "dope_domain_entity_uuid": pending.entityUuid,
                "code": body.code, "name": body.name,
                "description": body.description, "sort_order": body.sortOrder,
                "data_type": body.dataType,
                "nullable": body.nullable ? 1 : 0,
                "is_unique": body.isUnique ? 1 : 0,
                "auto_increment": nil,
                "text_char_limit": nil,
                "dope_domain_enum_uuid": nil,
                "related_property_uuid": target,
            ])
            counts.properties += 1
            if let entityRef = entityRefByUuid[pending.entityUuid] {
                propertyUuidByRef["\(entityRef).\(body.code)"] = uuid
            }
            if let originRef = body.baseOriginRef {
                pendingBaseOrigin.append((uuid, originRef))
            }
        }
        // Pass 5 — base_origin back-fill, after EVERY property (including the
        // deferred relationship rows) exists: origins are cross-domain-capable
        // and, unlike relationship targets, may themselves be relationship
        // properties. Same plain-UPDATE reasoning as pass 3.
        for pending in pendingBaseOrigin {
            guard let target = propertyUuidByRef[pending.ref] else {
                throw StoreError.badRequest(
                    detail: "property base_origin_ref '\(pending.ref)' did not resolve during insert")
            }
            try db.execute(sql: """
                UPDATE dope_domain_entity_property SET base_origin_property_uuid = ? WHERE uuid = ?
                """, arguments: [target, pending.propertyUuid])
        }
        return DopeTreeCounts(domains: counts.domains, entities: counts.entities,
                              properties: counts.properties, enums: counts.enums,
                              options: counts.options)
    }

    /// The ordered whole-tree wipe: relationship properties, then all
    /// remaining properties, then domains (CASCADE clears entities, enums,
    /// options). Never rely on CASCADE to unwind a RESTRICT.
    func wipeDopeTree(_ db: Database, scopeUuid: String) throws {
        // Entities compose each other under an ON DELETE RESTRICT self-FK, so
        // un-link every base BEFORE the domain CASCADE reaches the rows — a
        // base pair inside one domain would otherwise trip the RESTRICT
        // mid-statement. Rows about to be deleted; version deliberately
        // untouched.
        try db.execute(sql: """
            UPDATE dope_domain_entity SET base_composable_uuid = NULL
             WHERE base_composable_uuid IS NOT NULL
               AND dope_domain_uuid IN (
                SELECT uuid FROM dope_domain WHERE dope_scope_uuid = ?)
            """, arguments: [scopeUuid])
        // base_origin is data_type-INDEPENDENT, so the relationship-first
        // DELETE split below cannot separate origin referrers from their
        // targets — NULL every tag before either property DELETE runs.
        try db.execute(sql: """
            UPDATE dope_domain_entity_property SET base_origin_property_uuid = NULL
             WHERE base_origin_property_uuid IS NOT NULL
               AND dope_domain_entity_uuid IN (
                SELECT e.uuid FROM dope_domain_entity e
                  JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                 WHERE d.dope_scope_uuid = ?)
            """, arguments: [scopeUuid])
        try db.execute(sql: """
            DELETE FROM dope_domain_entity_property
             WHERE data_type = 'relationship'
               AND dope_domain_entity_uuid IN (
                SELECT e.uuid FROM dope_domain_entity e
                  JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                 WHERE d.dope_scope_uuid = ?)
            """, arguments: [scopeUuid])
        try db.execute(sql: """
            DELETE FROM dope_domain_entity_property
             WHERE dope_domain_entity_uuid IN (
                SELECT e.uuid FROM dope_domain_entity e
                  JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                 WHERE d.dope_scope_uuid = ?)
            """, arguments: [scopeUuid])
        try db.execute(
            sql: "DELETE FROM dope_domain WHERE dope_scope_uuid = ?",
            arguments: [scopeUuid])
    }

    // MARK: - Generic node mutations

    private func requireOwnedFields(_ fields: DopeNodeFields, level: DopeLevel) throws {
        let spec = DopeLevelSpec.spec(for: level)
        var carried: [DopeField] = []
        if fields.code != nil { carried.append(.code) }
        if fields.name != nil { carried.append(.name) }
        if fields.description != nil { carried.append(.description) }
        if fields.sortOrder != nil { carried.append(.sortOrder) }
        if fields.entityType != nil { carried.append(.entityType) }
        if fields.repoRepresentativeFile != nil || fields.clearRepoRepresentativeFile == true {
            carried.append(.repoRepresentativeFile)
        }
        if fields.baseComposableUuid != nil || fields.clearBaseComposable == true {
            carried.append(.baseComposableUuid)
        }
        if fields.dataType != nil { carried.append(.dataType) }
        if fields.nullable != nil { carried.append(.nullable) }
        if fields.isUnique != nil { carried.append(.isUnique) }
        if fields.autoIncrement != nil || fields.clearAutoIncrement == true {
            carried.append(.autoIncrement)
        }
        if fields.textCharLimit != nil || fields.clearTextCharLimit == true {
            carried.append(.textCharLimit)
        }
        if fields.enumUuid != nil || fields.clearEnum == true { carried.append(.enumUuid) }
        if fields.relatedPropertyUuid != nil || fields.clearRelatedProperty == true {
            carried.append(.relatedPropertyUuid)
        }
        if fields.baseOriginPropertyUuid != nil || fields.clearBaseOrigin == true {
            carried.append(.baseOriginPropertyUuid)
        }
        for field in carried where !spec.ownedFields.contains(field) {
            throw StoreError.badRequest(
                detail: "level '\(level.rawValue)' has no field '\(field.rawValue)'")
        }
    }

    private func validateDopeDescription(_ text: String?, level: DopeLevel) throws {
        guard let text else { return }
        let limit = Self.dopeDescriptionLimits[level] ?? 128
        guard text.count <= limit else {
            throw StoreError.badRequest(
                detail: "\(level.rawValue) description exceeds \(limit) characters")
        }
    }

    /// Same-scope + shape checks for a property's final (post-mutation)
    /// state. The schema CHECKs are the backstop; this produces the friendly
    /// message and enforces what SQL cannot see (same scope, no chain refs).
    private func validatePropertyShape(
        _ db: Database, scope: DopeScopeRow, propertyUuid: String?, entityUuid: String,
        dataType: String, enumUuid: String?, relatedPropertyUuid: String?,
        baseOriginPropertyUuid: String?,
        autoIncrement: Bool?, textCharLimit: Int?
    ) throws {
        guard let type = DopePropertyDataType(rawValue: dataType) else {
            throw StoreError.badRequest(detail: "unknown data_type '\(dataType)'")
        }
        if (type == .enumeration) != (enumUuid != nil) {
            throw StoreError.badRequest(
                detail: "enum properties require --enum-uuid, and only enum properties may carry one")
        }
        if (type == .relationship) != (relatedPropertyUuid != nil) {
            throw StoreError.badRequest(
                detail: "relationship properties require --related-property-uuid, and only relationship properties may carry one")
        }
        if autoIncrement != nil && type != .long {
            throw StoreError.badRequest(detail: "auto_increment is only legal on 'long' properties")
        }
        if textCharLimit != nil && type != .text {
            throw StoreError.badRequest(detail: "text_char_limit is only legal on 'text' properties")
        }
        if let enumUuid {
            let owner = try self.dopeOwningScope(db, level: .enumeration, nodeUuid: enumUuid)
            guard owner.uuid == scope.uuid else {
                throw StoreError.badRequest(
                    detail: "enum \(enumUuid) belongs to a different dope scope")
            }
        }
        if let relatedPropertyUuid {
            let owner = try self.dopeOwningScope(db, level: .property, nodeUuid: relatedPropertyUuid)
            guard owner.uuid == scope.uuid else {
                throw StoreError.badRequest(
                    detail: "target property \(relatedPropertyUuid) belongs to a different dope scope")
            }
            let targetType = try String.fetchOne(
                db, sql: "SELECT data_type FROM dope_domain_entity_property WHERE uuid = ?",
                arguments: [relatedPropertyUuid])
            if targetType == DopePropertyDataType.relationship.rawValue {
                throw StoreError.badRequest(
                    detail: "target property \(relatedPropertyUuid) is itself a relationship — chain refs are not allowed")
            }
        }
        if let origin = baseOriginPropertyUuid {
            if origin == propertyUuid {
                throw StoreError.badRequest(detail: "a property cannot originate from itself")
            }
            let owner = try self.dopeOwningScope(db, level: .property, nodeUuid: origin)
            guard owner.uuid == scope.uuid else {
                throw StoreError.badRequest(
                    detail: "base origin property \(origin) belongs to a different dope scope")
            }
            // dopeOwningScope proves existence + scope; the origin's
            // data_type, owning entity, and that entity's kind ride in on
            // one join.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.data_type AS data_type,
                       e.uuid AS entity_uuid,
                       e.entity_type AS entity_type
                  FROM dope_domain_entity_property p
                  JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                 WHERE p.uuid = ?
                """, arguments: [origin])
            else {
                throw StoreError.corruptState(
                    entity: "dope_domain_entity_property",
                    detail: "base origin \(origin) vanished")
            }
            let originEntity: String = row["entity_uuid"]
            // Defense-in-depth only: every base_composable target is
            // type-checked on write and the demotion guard holds it, so this
            // fires only on corrupt or hand-edited rows.
            guard (row["entity_type"] as String?) == DopeEntityType.baseComposable.rawValue else {
                throw StoreError.badRequest(detail:
                    "base origin property \(origin) lives on \(originEntity), which is not a BASE_COMPOSABLE")
            }
            try self.requireBaseChainReaches(db, entityUuid: entityUuid, targetUuid: originEntity)
            let originType: String = row["data_type"]
            guard originType == dataType else {
                throw StoreError.badRequest(detail:
                    "base origin property \(origin) is '\(originType)', not '\(dataType)' — a materialized property must keep the origin's data_type")
            }
        }
    }

    /// The materialization rule: `entityUuid` must actually compose
    /// `targetUuid`, directly or through the chain. Out-degree is 1, so this
    /// is requireAcyclicBase's pointer-chase walked forwards; the visited set
    /// keeps a pre-existing cycle from hanging the walk.
    private func requireBaseChainReaches(
        _ db: Database, entityUuid: String, targetUuid: String
    ) throws {
        var seen: Set<String> = []
        var node: String? = try String.fetchOne(
            db, sql: "SELECT base_composable_uuid FROM dope_domain_entity WHERE uuid = ?",
            arguments: [entityUuid]) ?? nil
        while let current = node {
            if current == targetUuid { return }
            guard seen.insert(current).inserted else { break }
            node = try String.fetchOne(
                db, sql: "SELECT base_composable_uuid FROM dope_domain_entity WHERE uuid = ?",
                arguments: [current]) ?? nil
        }
        throw StoreError.badRequest(detail:
            "entity \(entityUuid) does not compose \(targetUuid) — a property may only be materialized from a base its entity composes")
    }

    /// Same-scope + shape checks for an entity's final (post-mutation) state.
    /// `entityUuid` is nil on add (a row nothing can reference yet).
    private func validateEntityShape(
        _ db: Database, scope: DopeScopeRow, entityUuid: String?,
        entityType: DopeEntityType, baseComposableUuid: String?
    ) throws {
        if let target = baseComposableUuid {
            if target == entityUuid {
                throw StoreError.badRequest(detail: "an entity cannot compose itself")
            }
            let owner = try self.dopeOwningScope(db, level: .entity, nodeUuid: target)
            guard owner.uuid == scope.uuid else {
                throw StoreError.badRequest(
                    detail: "base entity \(target) belongs to a different dope scope")
            }
            // dopeOwningScope proves existence + scope; the TYPE needs its
            // own read.
            let targetType = try String.fetchOne(
                db, sql: "SELECT entity_type FROM dope_domain_entity WHERE uuid = ?",
                arguments: [target])
            guard targetType == DopeEntityType.baseComposable.rawValue else {
                throw StoreError.badRequest(detail:
                    "base entity \(target) is \(targetType ?? "unknown") — only a BASE_COMPOSABLE may be composed")
            }
            if let entityUuid {
                try self.requireAcyclicBase(db, entityUuid: entityUuid, targetUuid: target)
            }
        }
        // Demotion guard: an entity that others compose may not stop being a
        // BASE_COMPOSABLE. A cross-row rule the schema cannot express, so it
        // lives here and in the whole-tree validator.
        if entityType != .baseComposable, let entityUuid {
            let referrers = try self.baseComposableReferrers(db, entityUuid: entityUuid)
            guard referrers.isEmpty else {
                throw StoreError.badRequest(detail:
                    "cannot set entity_type \(entityType.rawValue): still composed by "
                    + referrers.joined(separator: ", "))
            }
        }
        // Strand guard: this entity's materialized properties tag origins on
        // base entities the FINAL chain must still reach. Receives the final
        // (not requested) base — passing the requested value would
        // false-refuse ordinary updates. Fires on ANY base change that
        // strands a tag (clear OR re-point); no-op on add (no properties
        // yet) and self-neutralizing when the base is unchanged.
        if let entityUuid {
            let tagged = try Row.fetchAll(db, sql: """
                SELECT p.code AS code, oe.uuid AS origin_entity
                  FROM dope_domain_entity_property p
                  JOIN dope_domain_entity_property op ON op.uuid = p.base_origin_property_uuid
                  JOIN dope_domain_entity oe ON oe.uuid = op.dope_domain_entity_uuid
                 WHERE p.dope_domain_entity_uuid = ?
                   AND p.base_origin_property_uuid IS NOT NULL
                """, arguments: [entityUuid])
            if !tagged.isEmpty {
                var reachable = Set<String>()
                var node = baseComposableUuid
                while let current = node, reachable.insert(current).inserted {
                    node = try String.fetchOne(
                        db, sql: "SELECT base_composable_uuid FROM dope_domain_entity WHERE uuid = ?",
                        arguments: [current]) ?? nil
                }
                let stranded = tagged.filter { !reachable.contains($0["origin_entity"] as String) }
                    .map { $0["code"] as String }
                guard stranded.isEmpty else {
                    throw StoreError.badRequest(detail:
                        "cannot change base_composable: property "
                        + stranded.joined(separator: ", ")
                        + " still originates from a base this entity would no longer compose")
                }
            }
        }
    }

    /// Chaining is ALLOWED but must stay acyclic. Out-degree is 1 (a single
    /// nullable column), so "does the chain from target reach entity?" is a
    /// bounded pointer-chase, not a graph search. The visited set is
    /// defensive only — a pre-existing cycle cannot be reached through these
    /// guards.
    private func requireAcyclicBase(
        _ db: Database, entityUuid: String, targetUuid: String
    ) throws {
        var seen: Set<String> = [entityUuid]
        var node: String? = targetUuid
        while let current = node {
            guard seen.insert(current).inserted else {
                if current == entityUuid {
                    throw StoreError.badRequest(detail:
                        "base_composable cycle: \(entityUuid) already sits on \(targetUuid)'s base chain")
                }
                return  // corruption below us; not this mutation's cycle
            }
            node = try String.fetchOne(
                db, sql: "SELECT base_composable_uuid FROM dope_domain_entity WHERE uuid = ?",
                arguments: [current]) ?? nil
        }
    }

    /// Dot-paths of the entities composing `entityUuid` (bounded at 5, the
    /// requireNoExternalReferrers convention).
    private func baseComposableReferrers(
        _ db: Database, entityUuid: String
    ) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT d.code || '.' || e.code
            FROM dope_domain_entity e
            JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
            WHERE e.base_composable_uuid = ? LIMIT 5
            """, arguments: [entityUuid])
    }

    public func dopeNodeAdd(_ req: DopeNodeAddRequest) throws -> DopeNodeResponse {
        guard req.level != .scope else {
            throw StoreError.badRequest(detail: "scopes are created with gm dope init, not node-add")
        }
        let spec = DopeLevelSpec.spec(for: req.level)
        try requireOwnedFields(req.fields, level: req.level)
        guard let code = req.fields.code, let name = req.fields.name else {
            throw StoreError.badRequest(detail: "node-add requires --code and --name")
        }
        try DopeCode.validateCode(code, field: "\(req.level.rawValue) code")
        if req.level == .entity, code == DopeCode.reservedEnumSegment {
            throw StoreError.badRequest(
                detail: "'enums' is a reserved entity code (it disambiguates enum refs)")
        }
        try validateDopeDescription(req.fields.description, level: req.level)

        return try dbQueue.write { db in
            guard let parentLevel = spec.parentLevel, let parentColumn = spec.parentColumn else {
                throw StoreError.corruptState(entity: spec.table, detail: "level has no parent")
            }
            let scope = try self.dopeOwningScope(db, level: parentLevel, nodeUuid: req.parentUuid)

            var extra: [String: (any DatabaseValueConvertible)?] = [
                parentColumn: req.parentUuid,
                "code": code,
                "name": name,
                "description": req.fields.description ?? "",
            ]
            let sortOrder: Int
            if let requested = req.fields.sortOrder {
                sortOrder = requested
            } else {
                sortOrder = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(sort_order), -1) + 1 FROM \(spec.table)
                    WHERE \(parentColumn) = ?
                    """, arguments: [req.parentUuid]) ?? 0
            }
            extra["sort_order"] = sortOrder

            switch req.level {
            case .entity:
                let entityType = req.fields.entityType ?? .model
                try self.validateEntityShape(
                    db, scope: scope, entityUuid: nil, entityType: entityType,
                    baseComposableUuid: req.fields.baseComposableUuid)
                extra["entity_type"] = entityType.rawValue
                extra["repo_representative_file"] = req.fields.repoRepresentativeFile
                extra["base_composable_uuid"] = req.fields.baseComposableUuid
            case .enumeration:
                extra["repo_representative_file"] = req.fields.repoRepresentativeFile
            case .property:
                guard let dataType = req.fields.dataType else {
                    throw StoreError.badRequest(detail: "property-add requires --data-type")
                }
                try self.validatePropertyShape(
                    db, scope: scope, propertyUuid: nil, entityUuid: req.parentUuid,
                    dataType: dataType.rawValue,
                    enumUuid: req.fields.enumUuid,
                    relatedPropertyUuid: req.fields.relatedPropertyUuid,
                    baseOriginPropertyUuid: req.fields.baseOriginPropertyUuid,
                    autoIncrement: req.fields.autoIncrement,
                    textCharLimit: req.fields.textCharLimit)
                extra["data_type"] = dataType.rawValue
                extra["nullable"] = (req.fields.nullable ?? true) ? 1 : 0
                extra["is_unique"] = (req.fields.isUnique ?? false) ? 1 : 0
                extra["auto_increment"] = req.fields.autoIncrement.map { $0 ? 1 : 0 }
                extra["text_char_limit"] = req.fields.textCharLimit
                extra["dope_domain_enum_uuid"] = req.fields.enumUuid
                extra["related_property_uuid"] = req.fields.relatedPropertyUuid
                extra["base_origin_property_uuid"] = req.fields.baseOriginPropertyUuid
            default:
                break
            }

            let uuid = try self.insertBase(db, table: spec.table, extra: extra)
            let revision = try self.bumpScopeRevision(db, scopeUuid: scope.uuid)
            try self.recordDopeChange(db, scope: scope, action: "node_add", level: req.level,
                                      nodeUuid: uuid, revision: revision)
            return DopeNodeResponse(level: req.level, uuid: uuid, version: 0,
                                    scopeUuid: scope.uuid, revision: revision)
        }
    }

    public func dopeNodeUpdate(_ req: DopeNodeUpdateRequest) throws -> DopeNodeResponse {
        let spec = DopeLevelSpec.spec(for: req.level)
        try requireOwnedFields(req.fields, level: req.level)
        if let code = req.fields.code {
            try DopeCode.validateCode(code, field: "\(req.level.rawValue) code")
            if req.level == .entity, code == DopeCode.reservedEnumSegment {
                throw StoreError.badRequest(
                    detail: "'enums' is a reserved entity code (it disambiguates enum refs)")
            }
        }
        try validateDopeDescription(req.fields.description, level: req.level)

        return try dbQueue.write { db in
            let scope = try self.dopeOwningScope(db, level: req.level, nodeUuid: req.nodeUuid)

            var set: [String: (any DatabaseValueConvertible)?] = [:]
            if let code = req.fields.code { set["code"] = code }
            if let name = req.fields.name { set["name"] = name }
            if let description = req.fields.description { set["description"] = description }
            if let sortOrder = req.fields.sortOrder { set["sort_order"] = sortOrder }
            if req.level == .entity, let entityType = req.fields.entityType {
                set["entity_type"] = entityType.rawValue
            }
            if req.level == .entity || req.level == .enumeration {
                if let file = req.fields.repoRepresentativeFile {
                    set["repo_representative_file"] = file
                } else if req.fields.clearRepoRepresentativeFile == true {
                    // updateValue, not subscript: a nil subscript assignment
                    // REMOVES the key and the clear vanishes from the UPDATE.
                    set.updateValue(nil, forKey: "repo_representative_file")
                }
            }

            if req.level == .entity {
                guard let current = try Row.fetchOne(
                    db, sql: "SELECT * FROM dope_domain_entity WHERE uuid = ?",
                    arguments: [req.nodeUuid]
                ) else {
                    throw StoreError.notFound(entity: spec.table, key: req.nodeUuid)
                }
                // Validate the FINAL (entity_type, base_composable) pair —
                // either half can change in one call, and the second call of
                // A.base=B / B.base=A must be the one that gets refused.
                let finalType = req.fields.entityType
                    ?? DopeEntityType(rawValue: current["entity_type"]) ?? .model
                var finalBase: String? = current["base_composable_uuid"]
                if let base = req.fields.baseComposableUuid { finalBase = base }
                if req.fields.clearBaseComposable == true { finalBase = nil }

                try self.validateEntityShape(
                    db, scope: scope, entityUuid: req.nodeUuid,
                    entityType: finalType, baseComposableUuid: finalBase)

                if req.fields.baseComposableUuid != nil || req.fields.clearBaseComposable == true {
                    // updateValue, not subscript: assigning a typed nil to a
                    // dictionary with Optional values REMOVES the key, and the
                    // clear would silently vanish from the UPDATE.
                    set.updateValue(finalBase, forKey: "base_composable_uuid")
                }
            }

            if req.level == .property {
                guard let current = try Row.fetchOne(
                    db, sql: "SELECT * FROM dope_domain_entity_property WHERE uuid = ?",
                    arguments: [req.nodeUuid]
                ) else {
                    throw StoreError.notFound(entity: spec.table, key: req.nodeUuid)
                }
                let finalDataType: String = req.fields.dataType?.rawValue
                    ?? (current["data_type"] as String)
                var finalEnum: String? = current["dope_domain_enum_uuid"]
                if let enumUuid = req.fields.enumUuid { finalEnum = enumUuid }
                if req.fields.clearEnum == true { finalEnum = nil }
                var finalRelated: String? = current["related_property_uuid"]
                if let related = req.fields.relatedPropertyUuid { finalRelated = related }
                if req.fields.clearRelatedProperty == true { finalRelated = nil }
                var finalAutoIncrement = (current["auto_increment"] as Int64?).map { $0 != 0 }
                if let autoIncrement = req.fields.autoIncrement { finalAutoIncrement = autoIncrement }
                if req.fields.clearAutoIncrement == true { finalAutoIncrement = nil }
                var finalCharLimit: Int? = current["text_char_limit"]
                if let limit = req.fields.textCharLimit { finalCharLimit = limit }
                if req.fields.clearTextCharLimit == true { finalCharLimit = nil }
                var finalBaseOrigin: String? = current["base_origin_property_uuid"]
                if let origin = req.fields.baseOriginPropertyUuid { finalBaseOrigin = origin }
                if req.fields.clearBaseOrigin == true { finalBaseOrigin = nil }

                try self.validatePropertyShape(
                    db, scope: scope, propertyUuid: req.nodeUuid,
                    entityUuid: current["dope_domain_entity_uuid"],
                    dataType: finalDataType,
                    enumUuid: finalEnum, relatedPropertyUuid: finalRelated,
                    baseOriginPropertyUuid: finalBaseOrigin,
                    autoIncrement: finalAutoIncrement, textCharLimit: finalCharLimit)

                if let dataType = req.fields.dataType { set["data_type"] = dataType.rawValue }
                if let nullable = req.fields.nullable { set["nullable"] = nullable ? 1 : 0 }
                if let isUnique = req.fields.isUnique { set["is_unique"] = isUnique ? 1 : 0 }
                // updateValue throughout, not subscript: a typed-nil subscript
                // assignment REMOVES the key, so a clear-alone call would
                // throw emptyUpdate and a combined call would silently skip
                // the clear (the base_composable_uuid trap, all five sites).
                if req.fields.autoIncrement != nil || req.fields.clearAutoIncrement == true {
                    set.updateValue(finalAutoIncrement.map { $0 ? 1 : 0 },
                                    forKey: "auto_increment")
                }
                if req.fields.textCharLimit != nil || req.fields.clearTextCharLimit == true {
                    set.updateValue(finalCharLimit, forKey: "text_char_limit")
                }
                if req.fields.enumUuid != nil || req.fields.clearEnum == true {
                    set.updateValue(finalEnum, forKey: "dope_domain_enum_uuid")
                }
                if req.fields.relatedPropertyUuid != nil || req.fields.clearRelatedProperty == true {
                    set.updateValue(finalRelated, forKey: "related_property_uuid")
                }
                if req.fields.baseOriginPropertyUuid != nil || req.fields.clearBaseOrigin == true {
                    // updateValue, not subscript — the typed-nil clear trap
                    // (same shape as base_composable_uuid above).
                    set.updateValue(finalBaseOrigin, forKey: "base_origin_property_uuid")
                }
            }

            guard !set.isEmpty else {
                throw StoreError.emptyUpdate(entity: spec.table)
            }
            try self.updateBase(db, table: spec.table, uuid: req.nodeUuid,
                                expectedVersion: req.expectedVersion, set: set)
            let revision = try self.bumpScopeRevision(db, scopeUuid: scope.uuid)
            try self.recordDopeChange(db, scope: scope, action: "node_update", level: req.level,
                                      nodeUuid: req.nodeUuid, revision: revision)
            guard let version = try Int64.fetchOne(
                db, sql: "SELECT version FROM \(spec.table) WHERE uuid = ?",
                arguments: [req.nodeUuid]
            ) else {
                throw StoreError.corruptState(entity: spec.table, detail: "vanished after update")
            }
            return DopeNodeResponse(level: req.level, uuid: req.nodeUuid, version: version,
                                    scopeUuid: scope.uuid, revision: revision)
        }
    }

    public func dopeNodeDelete(_ req: DopeNodeDeleteRequest) throws -> DopeNodeDeleteResponse {
        guard req.level != .scope else {
            throw StoreError.badRequest(
                detail: "scope deletion is deferred to a later pass (it destroys the whole tree)")
        }
        let spec = DopeLevelSpec.spec(for: req.level)
        return try dbQueue.write { db in
            let scope = try self.dopeOwningScope(db, level: req.level, nodeUuid: req.nodeUuid)
            try self.requireNoExternalReferrers(db, level: req.level, nodeUuid: req.nodeUuid)
            let cascaded = try self.dopeCascadeCounts(db, level: req.level, nodeUuid: req.nodeUuid)

            // Ordered deletes so a CASCADE can never race a RESTRICT: a
            // node's own relationship properties (referrers) go first, then
            // the remaining properties under it, then the guarded row.
            switch req.level {
            case .domain:
                // Entities inside this domain may compose one another under
                // an ON DELETE RESTRICT self-FK; the CASCADE below would trip
                // it. External composers were already refused by the guard.
                try db.execute(sql: """
                    UPDATE dope_domain_entity SET base_composable_uuid = NULL
                     WHERE dope_domain_uuid = ? AND base_composable_uuid IS NOT NULL
                    """, arguments: [req.nodeUuid])
                // Origin tags are data_type-independent — NULL them before
                // BOTH property DELETEs, or a tagged origin that is itself a
                // relationship property trips the RESTRICT mid-statement.
                try db.execute(sql: """
                    UPDATE dope_domain_entity_property SET base_origin_property_uuid = NULL
                     WHERE base_origin_property_uuid IS NOT NULL
                       AND dope_domain_entity_uuid IN (
                        SELECT uuid FROM dope_domain_entity WHERE dope_domain_uuid = ?)
                    """, arguments: [req.nodeUuid])
                try db.execute(sql: """
                    DELETE FROM dope_domain_entity_property
                     WHERE data_type = 'relationship'
                       AND dope_domain_entity_uuid IN (
                        SELECT uuid FROM dope_domain_entity WHERE dope_domain_uuid = ?)
                    """, arguments: [req.nodeUuid])
                try db.execute(sql: """
                    DELETE FROM dope_domain_entity_property
                     WHERE dope_domain_entity_uuid IN (
                        SELECT uuid FROM dope_domain_entity WHERE dope_domain_uuid = ?)
                    """, arguments: [req.nodeUuid])
            case .entity:
                // Same relationship-first split as the domain case: a bulk
                // delete can scan a same-entity relationship TARGET before
                // its referencer and trip the RESTRICT FK mid-statement.
                try db.execute(sql: """
                    UPDATE dope_domain_entity_property SET base_origin_property_uuid = NULL
                     WHERE base_origin_property_uuid IS NOT NULL
                       AND dope_domain_entity_uuid = ?
                    """, arguments: [req.nodeUuid])
                try db.execute(sql: """
                    DELETE FROM dope_domain_entity_property
                     WHERE data_type = 'relationship'
                       AND dope_domain_entity_uuid = ?
                    """, arguments: [req.nodeUuid])
                try db.execute(sql: """
                    DELETE FROM dope_domain_entity_property
                     WHERE dope_domain_entity_uuid = ?
                    """, arguments: [req.nodeUuid])
            default:
                break
            }
            try self.deleteBase(db, table: spec.table, uuid: req.nodeUuid,
                                expectedVersion: req.expectedVersion)
            let revision = try self.bumpScopeRevision(db, scopeUuid: scope.uuid)
            try self.recordDopeChange(db, scope: scope, action: "node_delete", level: req.level,
                                      nodeUuid: req.nodeUuid, revision: revision)
            return DopeNodeDeleteResponse(deletedUuid: req.nodeUuid, cascaded: cascaded,
                                          scopeUuid: scope.uuid, revision: revision)
        }
    }

    /// RESTRICT-friendly pre-checks: name the referring dot-paths instead of
    /// surfacing an opaque FK error. "External" means outside the subtree
    /// being deleted — internal referrers are handled by the ordered deletes.
    private func requireNoExternalReferrers(
        _ db: Database, level: DopeLevel, nodeUuid: String
    ) throws {
        // A list, not one statement: the base-composable referrer queries
        // select FROM dope_domain_entity while the property-ref queries
        // select FROM dope_domain_entity_property, so they cannot share an
        // OR clause.
        var queries: [(sql: String, args: StatementArguments)] = []
        switch level {
        case .enumeration:
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE p.dope_domain_enum_uuid = ? LIMIT 5
                """, [nodeUuid]))
        case .property:
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE p.related_property_uuid = ? LIMIT 5
                """, [nodeUuid]))
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE p.base_origin_property_uuid = ? LIMIT 5
                """, [nodeUuid]))
        case .entity:
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                JOIN dope_domain_entity_property tp ON tp.uuid = p.related_property_uuid
                WHERE tp.dope_domain_entity_uuid = ?
                  AND p.dope_domain_entity_uuid != ? LIMIT 5
                """, [nodeUuid, nodeUuid]))
            queries.append(("""
                SELECT d.code || '.' || e.code
                FROM dope_domain_entity e
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE e.base_composable_uuid = ? LIMIT 5
                """, [nodeUuid]))
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                JOIN dope_domain_entity_property op ON op.uuid = p.base_origin_property_uuid
                WHERE op.dope_domain_entity_uuid = ?
                  AND p.dope_domain_entity_uuid != ? LIMIT 5
                """, [nodeUuid, nodeUuid]))
        case .domain:
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE d.uuid != ?
                  AND (p.dope_domain_enum_uuid IN
                        (SELECT uuid FROM dope_domain_enum WHERE dope_domain_uuid = ?)
                    OR p.related_property_uuid IN
                        (SELECT pp.uuid FROM dope_domain_entity_property pp
                          JOIN dope_domain_entity ee ON ee.uuid = pp.dope_domain_entity_uuid
                         WHERE ee.dope_domain_uuid = ?))
                LIMIT 5
                """, [nodeUuid, nodeUuid, nodeUuid]))
            queries.append(("""
                SELECT d.code || '.' || e.code
                FROM dope_domain_entity e
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE d.uuid != ?
                  AND e.base_composable_uuid IN
                      (SELECT uuid FROM dope_domain_entity WHERE dope_domain_uuid = ?)
                LIMIT 5
                """, [nodeUuid, nodeUuid]))
            queries.append(("""
                SELECT d.code || '.' || e.code || '.' || p.code
                FROM dope_domain_entity_property p
                JOIN dope_domain_entity e ON e.uuid = p.dope_domain_entity_uuid
                JOIN dope_domain d ON d.uuid = e.dope_domain_uuid
                WHERE d.uuid != ?
                  AND p.base_origin_property_uuid IN
                      (SELECT pp.uuid FROM dope_domain_entity_property pp
                        JOIN dope_domain_entity ee ON ee.uuid = pp.dope_domain_entity_uuid
                       WHERE ee.dope_domain_uuid = ?)
                LIMIT 5
                """, [nodeUuid, nodeUuid]))
        case .scope, .option:
            return
        }
        let referrers = try queries.flatMap {
            try String.fetchAll(db, sql: $0.sql, arguments: $0.args)
        }
        guard referrers.isEmpty else {
            throw StoreError.badRequest(detail:
                "cannot delete: still referenced by " + referrers.joined(separator: ", "))
        }
    }

    private func dopeCascadeCounts(
        _ db: Database, level: DopeLevel, nodeUuid: String
    ) throws -> DopeTreeCounts {
        func count(_ sql: String, _ args: StatementArguments = StatementArguments()) throws -> Int {
            try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
        }
        switch level {
        case .domain:
            let entities = try count(
                "SELECT COUNT(*) FROM dope_domain_entity WHERE dope_domain_uuid = ?", [nodeUuid])
            let enums = try count(
                "SELECT COUNT(*) FROM dope_domain_enum WHERE dope_domain_uuid = ?", [nodeUuid])
            let options = try count("""
                SELECT COUNT(*) FROM dope_domain_enum_option WHERE dope_domain_enum_uuid IN
                    (SELECT uuid FROM dope_domain_enum WHERE dope_domain_uuid = ?)
                """, [nodeUuid])
            let properties = try count("""
                SELECT COUNT(*) FROM dope_domain_entity_property WHERE dope_domain_entity_uuid IN
                    (SELECT uuid FROM dope_domain_entity WHERE dope_domain_uuid = ?)
                """, [nodeUuid])
            return DopeTreeCounts(domains: 1, entities: entities, properties: properties,
                                  enums: enums, options: options)
        case .entity:
            let properties = try count(
                "SELECT COUNT(*) FROM dope_domain_entity_property WHERE dope_domain_entity_uuid = ?",
                [nodeUuid])
            return DopeTreeCounts(domains: 0, entities: 1, properties: properties,
                                  enums: 0, options: 0)
        case .enumeration:
            let options = try count(
                "SELECT COUNT(*) FROM dope_domain_enum_option WHERE dope_domain_enum_uuid = ?",
                [nodeUuid])
            return DopeTreeCounts(domains: 0, entities: 0, properties: 0,
                                  enums: 1, options: options)
        case .property:
            return DopeTreeCounts(domains: 0, entities: 0, properties: 1, enums: 0, options: 0)
        case .option:
            return DopeTreeCounts(domains: 0, entities: 0, properties: 0, enums: 0, options: 1)
        case .scope:
            return DopeTreeCounts(domains: 0, entities: 0, properties: 0, enums: 0, options: 0)
        }
    }
}
