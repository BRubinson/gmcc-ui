import Foundation
import GRDB

/// DIAGRAM domain modeling — db-persisted canvases over the dope subsystem.
///
/// One write path: `applyDiagramMutations` is the ONLY mutation body. The
/// granular node verbs build one-mutation batches over it, so granular and
/// batch semantics structurally cannot drift. Every batch (of any size) runs
/// in one transaction, bumps `diagram.revision` exactly once
/// (`bumpDiagramRevision` — the bumpScopeRevision twin: never the row's
/// optimistic-lock version) and emits exactly one DIAGRAM_CHANGE event.
///
/// dope bindings are TEXT codes resolved at READ time through the existing
/// `dopeScopeCandidates` ladder against the diagram row's own session/prompt
/// FKs. Dangling codes are a LEGAL renderable state (ghosts) — diagram
/// elements never join `requireNoExternalReferrers`, and no dope write path
/// knows diagrams exist.
extension Store {

    // MARK: - Row + revision helpers

    static func diagramRow(_ row: Row) -> DiagramRow {
        DiagramRow(
            uuid: row["uuid"], version: row["version"], tier: row["tier"],
            projectUuid: row["project_uuid"], instanceUuid: row["instance_uuid"],
            sessionUuid: row["session_uuid"], promptUuid: row["prompt_uuid"],
            code: row["code"], name: row["name"], description: row["description"],
            gmccDiagramPath: row["gmcc_diagram_path"], revision: row["revision"],
            createdAt: row["created_at"], updatedAt: row["updated_at"])
    }

    func fetchDiagram(_ db: Database, uuid: String) throws -> DiagramRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM diagram WHERE uuid = ?", arguments: [uuid])
            .map(Self.diagramRow)
    }

    /// Advance the whole-tree content counter WITHOUT bumping the diagram
    /// row's version — a geometry edit deep in the tree must never invalidate
    /// a diagram version a GMVibes editor is holding.
    @discardableResult
    func bumpDiagramRevision(_ db: Database, diagramUuid: String) throws -> Int64 {
        try db.execute(
            sql: "UPDATE diagram SET revision = revision + 1, updated_at = ? WHERE uuid = ?",
            arguments: [Store.isoNow(), diagramUuid])
        guard let revision = try Int64.fetchOne(
            db, sql: "SELECT revision FROM diagram WHERE uuid = ?", arguments: [diagramUuid]
        ) else {
            throw StoreError.notFound(entity: "diagram", key: diagramUuid)
        }
        return revision
    }

    private func recordDiagramChange(
        _ db: Database, diagram: DiagramRow, action: String,
        elementUuid: String?, mutationCount: Int?, revision: Int64
    ) throws {
        var payload: [String: Any] = [
            "action": action,
            "diagram_uuid": diagram.uuid,
            "tier": diagram.tier,
            "project_uuid": diagram.projectUuid,
            "revision": Int(revision),
        ]
        if let elementUuid { payload["element_uuid"] = elementUuid }
        if let mutationCount { payload["mutation_count"] = mutationCount }
        if let sessionUuid = diagram.sessionUuid { payload["session_uuid"] = sessionUuid }
        if let promptUuid = diagram.promptUuid { payload["prompt_uuid"] = promptUuid }
        try appendEvent(db, kind: .diagramChange, subjectUuid: diagram.uuid,
                        payload: Store.jsonPayload(payload))
        // touchSession only when session-owned — PROJECT/INSTANCE-tier
        // diagrams have no session to touch.
        if let sessionUuid = diagram.sessionUuid {
            try touchSession(db, uuid: sessionUuid)
        }
    }

    // MARK: - Owner addressing (the chain-non-null tier ladder)

    struct DiagramOwner {
        let tier: DiagramTier
        let projectUuid: String
        let instanceUuid: String?
        let sessionUuid: String?
        let promptUuid: String?

        var ownerKind: String { tier.rawValue.lowercased() }
        var ownerColumn: String {
            switch tier {
            case .project: return "project_uuid"
            case .instance: return "instance_uuid"
            case .session: return "session_uuid"
            case .prompt: return "prompt_uuid"
            }
        }
        var ownerUuid: String {
            switch tier {
            case .project: return projectUuid
            case .instance: return instanceUuid!
            case .session: return sessionUuid!
            case .prompt: return promptUuid!
            }
        }
    }

    /// Validate that EXACTLY one owner uuid was passed, that the row exists
    /// (unknown uuid → NOT_FOUND, the three-way absence discrimination's
    /// first guard), and derive the full ancestor chain by joins.
    func resolveDiagramOwner(
        _ db: Database, projectUuid: String?, instanceUuid: String?,
        sessionUuid: String?, promptUuid: String?
    ) throws -> DiagramOwner {
        let owners: [(String?, DiagramTier)] = [
            (projectUuid, .project), (instanceUuid, .instance),
            (sessionUuid, .session), (promptUuid, .prompt),
        ]
        let present = owners.filter { $0.0 != nil }
        guard present.count == 1, let (uuid, tier) = present.first, let uuid else {
            throw StoreError.badRequest(detail:
                "pass exactly one of project/instance/session/prompt uuid (got \(present.count))")
        }
        switch tier {
        case .project:
            guard try Row.fetchOne(
                db, sql: "SELECT uuid FROM project WHERE uuid = ?", arguments: [uuid]
            ) != nil else {
                throw StoreError.notFound(entity: "project", key: uuid)
            }
            return DiagramOwner(tier: .project, projectUuid: uuid,
                                instanceUuid: nil, sessionUuid: nil, promptUuid: nil)
        case .instance:
            guard let project = try String.fetchOne(
                db, sql: "SELECT project_uuid FROM instance WHERE uuid = ?", arguments: [uuid]
            ) else {
                throw StoreError.notFound(entity: "instance", key: uuid)
            }
            return DiagramOwner(tier: .instance, projectUuid: project,
                                instanceUuid: uuid, sessionUuid: nil, promptUuid: nil)
        case .session:
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.instance_uuid AS instance_uuid, i.project_uuid AS project_uuid
                FROM session s JOIN instance i ON i.uuid = s.instance_uuid
                WHERE s.uuid = ?
                """, arguments: [uuid]) else {
                throw StoreError.notFound(entity: "session", key: uuid)
            }
            return DiagramOwner(tier: .session, projectUuid: row["project_uuid"],
                                instanceUuid: row["instance_uuid"],
                                sessionUuid: uuid, promptUuid: nil)
        case .prompt:
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.session_uuid AS session_uuid, s.instance_uuid AS instance_uuid,
                       i.project_uuid AS project_uuid
                FROM prompt p
                JOIN session s ON s.uuid = p.session_uuid
                JOIN instance i ON i.uuid = s.instance_uuid
                WHERE p.uuid = ?
                """, arguments: [uuid]) else {
                throw StoreError.notFound(entity: "prompt", key: uuid)
            }
            return DiagramOwner(tier: .prompt, projectUuid: row["project_uuid"],
                                instanceUuid: row["instance_uuid"],
                                sessionUuid: row["session_uuid"], promptUuid: uuid)
        }
    }

    // MARK: - Init

    public func diagramInit(_ req: DiagramInitRequest) throws -> DiagramResponse {
        try DopeCode.validateCode(req.code, field: "diagram code")
        let description = req.description ?? ""
        guard description.count <= 512 else {
            throw StoreError.badRequest(detail: "diagram description exceeds 512 characters")
        }
        return try dbQueue.write { db in
            let owner = try self.resolveDiagramOwner(
                db, projectUuid: req.projectUuid, instanceUuid: req.instanceUuid,
                sessionUuid: req.sessionUuid, promptUuid: req.promptUuid)
            if req.gmccDiagramPath != nil, owner.tier == .project {
                throw StoreError.badRequest(
                    detail: "gmcc_diagram_path is unresolvable at PROJECT tier (no instance root)")
            }
            if let existing = try Row.fetchOne(db, sql: """
                SELECT * FROM diagram WHERE tier = ? AND \(owner.ownerColumn) = ? AND code = ?
                """, arguments: [owner.tier.rawValue, owner.ownerUuid, req.code]) {
                return DiagramResponse(diagram: Self.diagramRow(existing), created: false)
            }
            let uuid = try self.insertBase(db, table: "diagram", extra: [
                "project_uuid": owner.projectUuid,
                "instance_uuid": owner.instanceUuid,
                "session_uuid": owner.sessionUuid,
                "prompt_uuid": owner.promptUuid,
                "tier": owner.tier.rawValue,
                "code": req.code,
                "name": req.name,
                "description": description,
                "gmcc_diagram_path": req.gmccDiagramPath,
                "revision": 0,
            ])
            guard let diagram = try self.fetchDiagram(db, uuid: uuid) else {
                throw StoreError.corruptState(entity: "diagram", detail: "vanished after insert")
            }
            try self.recordDiagramChange(db, diagram: diagram, action: "init",
                                         elementUuid: nil, mutationCount: nil,
                                         revision: diagram.revision)
            return DiagramResponse(diagram: diagram, created: true)
        }
    }

    // MARK: - List (v12 semantics: one owner, one tier, never a union)

    public func diagramList(_ req: DiagramListRequest) throws -> DiagramListResponse {
        try dbQueue.read { db in
            let owner = try self.resolveDiagramOwner(
                db, projectUuid: req.projectUuid, instanceUuid: req.instanceUuid,
                sessionUuid: req.sessionUuid, promptUuid: req.promptUuid)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM diagram WHERE tier = ? AND \(owner.ownerColumn) = ?
                ORDER BY code
                """, arguments: [owner.tier.rawValue, owner.ownerUuid])
            return DiagramListResponse(diagrams: rows.map(Self.diagramRow))
        }
    }

    // MARK: - Get (uuid or owner+code; no cross-tier ladder)

    public func diagramGet(_ req: DiagramGetRequest) throws -> DiagramGetResponse {
        try dbQueue.read { db in
            let diagram: DiagramRow
            if let diagramUuid = req.diagramUuid {
                guard let found = try self.fetchDiagram(db, uuid: diagramUuid) else {
                    throw StoreError.notFound(entity: "diagram", key: diagramUuid)
                }
                diagram = found
            } else {
                let owner = try self.resolveDiagramOwner(
                    db, projectUuid: req.projectUuid, instanceUuid: req.instanceUuid,
                    sessionUuid: req.sessionUuid, promptUuid: req.promptUuid)
                var sql = "SELECT * FROM diagram WHERE tier = ? AND \(owner.ownerColumn) = ?"
                var args: [(any DatabaseValueConvertible)?] = [owner.tier.rawValue, owner.ownerUuid]
                if let code = req.code {
                    sql += " AND code = ?"
                    args.append(code)
                }
                sql += " ORDER BY code"
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                    .map(Self.diagramRow)
                if rows.count > 1 {
                    throw StoreError.badRequest(detail:
                        "several diagrams match — pass --code (candidates: "
                        + rows.map(\.code).joined(separator: ", ") + ")")
                }
                guard let found = rows.first else {
                    // The owner exists (resolveDiagramOwner's guard) — this
                    // absence means "initialize a diagram", not "unknown uuid".
                    throw StoreError.diagramAbsent(
                        ownerKind: owner.ownerKind, ownerUuid: owner.ownerUuid, code: req.code)
                }
                diagram = found
            }
            let tree = try self.fetchDiagramTree(db, diagram: diagram)
            let bindings = try self.resolveDiagramBindings(db, diagram: diagram, tree: tree)
            return DiagramGetResponse(tree: tree, bindings: bindings)
        }
    }

    // MARK: - Hydration (8 flat queries grouped in Swift — never per-node
    // recursion; ORDER BY element_z, sort_order, code keeps reads and
    // screenshots deterministic)

    func fetchDiagramTree(_ db: Database, diagram: DiagramRow) throws -> DiagramTree {
        let elementRows = try Row.fetchAll(db, sql: """
            SELECT * FROM diagram_element WHERE diagram_uuid = ?
            ORDER BY element_z, sort_order, code
            """, arguments: [diagram.uuid])

        func subtypeRows(_ table: String) throws -> [String: Row] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.* FROM \(table) t
                JOIN diagram_element e ON e.uuid = t.element_uuid
                WHERE e.diagram_uuid = ?
                """, arguments: [diagram.uuid])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["element_uuid"], $0) })
        }
        let layers = try subtypeRows("diagram_drawing_layer")
        let strokes = try subtypeRows("diagram_drawing_stroke")
        let shapes = try subtypeRows("diagram_drawing_shape")
        let scopes = try subtypeRows("diagram_dope_scope")
        let entities = try subtypeRows("diagram_dope_entity")

        func vertexRows(_ table: String, _ parentColumn: String) throws -> [String: [DiagramVertex]] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT v.* FROM \(table) v
                JOIN diagram_element e ON e.uuid = v.\(parentColumn)
                WHERE e.diagram_uuid = ? ORDER BY v.seq
                """, arguments: [diagram.uuid])
            var grouped = [String: [DiagramVertex]]()
            for row in rows {
                let vertex = DiagramVertex(
                    x: row["x"], y: row["y"],
                    pressure: row.hasColumn("pressure") ? row["pressure"] : nil)
                grouped[row[parentColumn], default: []].append(vertex)
            }
            return grouped
        }
        let strokeVertices = try vertexRows("diagram_stroke_vertex", "stroke_element_uuid")
        let shapeVertices = try vertexRows("diagram_shape_vertex", "shape_element_uuid")

        func payload(for row: Row) throws -> DiagramElementPayload {
            let uuid: String = row["uuid"]
            guard let type = DiagramElementType(rawValue: row["element_type"]) else {
                throw StoreError.corruptState(
                    entity: "diagram_element",
                    detail: "unknown element_type '\(row["element_type"] as String)'")
            }
            switch type {
            case .drawingLayer:
                guard let sub = layers[uuid] else { break }
                return .drawingLayer(DrawingLayerPayload(
                    opacity: sub["opacity"],
                    visible: (sub["visible"] as Int64) != 0,
                    locked: (sub["locked"] as Int64) != 0))
            case .drawingStroke:
                guard let sub = strokes[uuid] else { break }
                return .drawingStroke(DrawingStrokePayload(
                    tool: DiagramStrokeTool(rawValue: sub["tool"]) ?? .pencil,
                    strokeColor: sub["stroke_color"], strokeWidth: sub["stroke_width"],
                    vertices: strokeVertices[uuid] ?? []))
            case .drawingShape:
                guard let sub = shapes[uuid] else { break }
                guard let kind = DiagramShapeKind(rawValue: sub["shape_kind"]) else {
                    throw StoreError.corruptState(
                        entity: "diagram_drawing_shape",
                        detail: "unknown shape_kind '\(sub["shape_kind"] as String)'")
                }
                return .drawingShape(DrawingShapePayload(
                    shapeKind: kind, strokeColor: sub["stroke_color"],
                    strokeWidth: sub["stroke_width"], fillColor: sub["fill_color"],
                    cornerRadius: sub["corner_radius"],
                    vertices: shapeVertices[uuid] ?? []))
            case .dopeScope:
                guard let sub = scopes[uuid] else { break }
                return .dopeScope(DopeScopePayload(dopeScopeCode: sub["dope_scope_code"]))
            case .dopeEntity:
                guard let sub = entities[uuid] else { break }
                return .dopeEntity(DopeEntityPayload(entityCode: sub["entity_code"]))
            }
            throw StoreError.corruptState(
                entity: "diagram_element", detail: "element \(uuid) has no subtype row")
        }

        var childrenByParent = [String: [Row]]()
        var topLevel: [Row] = []
        for row in elementRows {
            if let parent: String = row["parent_element_uuid"] {
                childrenByParent[parent, default: []].append(row)
            } else {
                topLevel.append(row)
            }
        }

        func node(_ row: Row) throws -> DiagramElementNode {
            DiagramElementNode(
                identity: DopeNodeIdentity(
                    uuid: row["uuid"], version: row["version"],
                    createdAt: row["created_at"], updatedAt: row["updated_at"]),
                base: DiagramElementBase(
                    code: row["code"], name: row["name"], description: row["description"],
                    sortOrder: row["sort_order"], centerX: row["center_x"],
                    centerY: row["center_y"], elementZ: row["element_z"],
                    scale: row["scale"]),
                payload: try payload(for: row),
                children: try (childrenByParent[row["uuid"]] ?? []).map(node))
        }

        return DiagramTree(
            identity: DopeNodeIdentity(uuid: diagram.uuid, version: diagram.version,
                                       createdAt: diagram.createdAt, updatedAt: diagram.updatedAt),
            tier: diagram.tier, projectUuid: diagram.projectUuid,
            instanceUuid: diagram.instanceUuid, sessionUuid: diagram.sessionUuid,
            promptUuid: diagram.promptUuid, code: diagram.code, name: diagram.name,
            description: diagram.description, gmccDiagramPath: diagram.gmccDiagramPath,
            revision: diagram.revision, elements: try topLevel.map(node))
    }

    // MARK: - Binding resolution (read-time, ghost-tolerant)

    /// One row per dope_scope element, resolved through the EXISTING dope
    /// ladder against the DIAGRAM row's own session/prompt context: PROMPT
    /// scope preferred, SESSION_BASE fallback, resolvedVia surfaced. A
    /// PROJECT/INSTANCE-tier diagram has no session — every binding resolves
    /// absent by construction. Never an error, never a dope delete guard.
    func resolveDiagramBindings(
        _ db: Database, diagram: DiagramRow, tree: DiagramTree
    ) throws -> [DiagramBindingResolution] {
        var bindings: [DiagramBindingResolution] = []

        func walk(_ node: DiagramElementNode) throws {
            if case .dopeScope(let payload) = node.payload {
                var resolvedVia: String?
                var scope: DopeScopeRow?
                if let sessionUuid = diagram.sessionUuid {
                    if let promptUuid = diagram.promptUuid {
                        scope = try self.dopeScopeCandidates(
                            db, sessionUuid: sessionUuid, scopeType: .prompt,
                            promptUuid: promptUuid, code: payload.dopeScopeCode).first
                        if scope != nil { resolvedVia = "prompt" }
                    }
                    if scope == nil {
                        scope = try self.dopeScopeCandidates(
                            db, sessionUuid: sessionUuid, scopeType: .sessionBase,
                            code: payload.dopeScopeCode).first
                        if scope != nil { resolvedVia = "session_base" }
                    }
                }
                bindings.append(DiagramBindingResolution(
                    elementUuid: node.identity.uuid,
                    dopeScopeCode: payload.dopeScopeCode,
                    resolvedVia: resolvedVia,
                    scopeUuid: scope?.uuid,
                    dopeRevision: scope?.revision))
            }
            for child in node.children { try walk(child) }
        }
        for element in tree.elements { try walk(element) }
        return bindings
    }

    // MARK: - Element validation + code minting

    private struct ElementRowInfo {
        let uuid: String
        let diagramUuid: String
        let parentElementUuid: String?
        let type: DiagramElementType
    }

    private func fetchElementInfo(_ db: Database, uuid: String) throws -> ElementRowInfo {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM diagram_element WHERE uuid = ?", arguments: [uuid]
        ) else {
            throw StoreError.notFound(entity: "diagram_element", key: uuid)
        }
        guard let type = DiagramElementType(rawValue: row["element_type"]) else {
            throw StoreError.corruptState(
                entity: "diagram_element",
                detail: "unknown element_type '\(row["element_type"] as String)'")
        }
        return ElementRowInfo(uuid: row["uuid"], diagramUuid: row["diagram_uuid"],
                              parentElementUuid: row["parent_element_uuid"], type: type)
    }

    /// Containment + payload shape: the cross-row rules the schema cannot
    /// see (which parent types may hold which child types), plus code
    /// validation on binding payloads. Existence of the dope target is
    /// deliberately NOT checked — dangling is legal.
    private func validateDiagramElementShape(
        _ db: Database, diagramUuid: String, type: DiagramElementType,
        parent: ElementRowInfo?, payload: DiagramElementPayload
    ) throws {
        guard payload.elementType == type else {
            throw StoreError.badRequest(detail:
                "payload kind '\(payload.elementType.rawValue)' does not match element type '\(type.rawValue)' — type morphing is refused")
        }
        let spec = DiagramElementTypeSpec.spec(for: type)
        if let allowed = spec.allowedParentTypes {
            guard let parent else {
                throw StoreError.badRequest(detail:
                    "\(type.rawValue) elements need a parent element ("
                    + allowed.map(\.rawValue).sorted().joined(separator: "/") + ")")
            }
            guard allowed.contains(parent.type) else {
                throw StoreError.badRequest(detail:
                    "a \(type.rawValue) cannot live under a \(parent.type.rawValue) (legal: "
                    + allowed.map(\.rawValue).sorted().joined(separator: "/") + ")")
            }
            guard parent.diagramUuid == diagramUuid else {
                throw StoreError.badRequest(detail:
                    "parent element \(parent.uuid) belongs to a different diagram")
            }
        } else if parent != nil {
            throw StoreError.badRequest(detail:
                "\(type.rawValue) is a top-level element type and cannot have a parent")
        }
        switch payload {
        case .dopeScope(let p):
            try DopeCode.validateCode(p.dopeScopeCode, field: "dope_scope binding code")
        case .dopeEntity(let p):
            _ = try DopeCode.parseEntityRef(p.entityCode, field: "dope entity binding")
        case .drawingStroke(let p):
            if !p.vertices.isEmpty, p.vertices.count < 2 {
                throw StoreError.badRequest(detail: "a stroke needs at least 2 vertices (or none)")
            }
        case .drawingShape(let p):
            if p.cornerRadius != nil, p.shapeKind != .rectangle {
                throw StoreError.badRequest(detail: "corner_radius is only legal on rectangles")
            }
        case .drawingLayer:
            break
        }
    }

    /// Mint `stroke_0007`-style codes when an add omits one — hand-naming
    /// hundreds of freedraw strokes is hostile. MAX numeric suffix + 1 per
    /// type prefix within the diagram-wide code namespace.
    ///
    /// The LIKE underscore is ESCAPEd (it is a single-char wildcard, so a
    /// bare `stroke_%` would also match `strokes9000`), and suffixes are
    /// bounded before the +1 so a crafted 19-digit code can never overflow
    /// Int and trap the shared single-writer daemon — absurd suffixes are
    /// simply ignored by the mint.
    private static let maxMintedSuffix = 999_999

    private func mintElementCode(
        _ db: Database, diagramUuid: String, type: DiagramElementType
    ) throws -> String {
        let prefix = type.codePrefix + "_"
        let pattern = prefix.replacingOccurrences(of: "_", with: "\\_") + "%"
        let existing = try String.fetchAll(db, sql: """
            SELECT code FROM diagram_element WHERE diagram_uuid = ? AND code LIKE ? ESCAPE '\\'
            """, arguments: [diagramUuid, pattern])
        let maxSuffix = existing
            .compactMap { Int($0.dropFirst(prefix.count)) }
            .filter { (0...Self.maxMintedSuffix).contains($0) }
            .max() ?? 0
        return prefix + String(format: "%04d", maxSuffix + 1)
    }

    // MARK: - The single write path

    public func diagramBatchApply(_ req: DiagramBatchApplyRequest) throws -> DiagramBatchApplyResponse {
        guard !req.mutations.isEmpty else {
            throw StoreError.badRequest(detail: "batch-apply carried no mutations")
        }
        return try dbQueue.write { db in
            guard let diagram = try self.fetchDiagram(db, uuid: req.diagramUuid) else {
                throw StoreError.notFound(entity: "diagram", key: req.diagramUuid)
            }
            if let expected = req.expectedRevision, expected != diagram.revision {
                throw StoreError.revisionConflict(
                    scopeUuid: diagram.uuid, expected: expected, actual: diagram.revision)
            }
            var ledger: [String: String] = [:]
            var results: [DiagramMutationResult] = []
            // Tracked so later mutations validate against POST-mutation state
            // (a promotion earlier in the batch changes the tier the next
            // diagramUpdate must see) and the event carries the final row.
            var currentDiagram = diagram
            var lastElementUuid: String?
            for (index, mutation) in req.mutations.enumerated() {
                switch mutation {
                case .elementAdd(let add):
                    let result = try self.applyElementAdd(
                        db, diagram: currentDiagram, add: add, ledger: &ledger, index: index)
                    results.append(result)
                    lastElementUuid = result.uuid
                case .elementUpdate(let update):
                    let result = try self.applyElementUpdate(
                        db, diagram: currentDiagram, update: update, index: index)
                    results.append(result)
                    lastElementUuid = result.uuid
                case .elementDelete(let delete):
                    let result = try self.applyElementDelete(
                        db, diagram: currentDiagram, delete: delete, index: index)
                    results.append(result)
                    lastElementUuid = result.uuid
                case .diagramUpdate(let update):
                    let result = try self.applyDiagramRowUpdate(
                        db, diagram: currentDiagram, update: update, index: index)
                    results.append(result)
                    guard let refreshed = try self.fetchDiagram(db, uuid: diagram.uuid) else {
                        throw StoreError.corruptState(
                            entity: "diagram", detail: "vanished mid-batch")
                    }
                    currentDiagram = refreshed
                }
            }
            let revision = try self.bumpDiagramRevision(db, diagramUuid: diagram.uuid)
            let action = req.mutations.count == 1
                ? req.mutations[0].kind : "batch_apply"
            // The event carries the FINAL row: a batch containing a promotion
            // must signal the NEW tier/session (and touch the new session),
            // or a GMVibes window filtering by session never sees a diagram
            // promoted into it. element_uuid is set only for a single ELEMENT
            // mutation — a lone diagram_update names no element.
            try self.recordDiagramChange(
                db, diagram: currentDiagram, action: action,
                elementUuid: req.mutations.count == 1 ? lastElementUuid : nil,
                mutationCount: req.mutations.count, revision: revision)
            return DiagramBatchApplyResponse(
                diagramUuid: diagram.uuid, revision: revision, results: results)
        }
    }

    // MARK: - Per-mutation bodies (called ONLY from diagramBatchApply)

    private func applyElementAdd(
        _ db: Database, diagram: DiagramRow, add: DiagramElementAdd,
        ledger: inout [String: String], index: Int
    ) throws -> DiagramMutationResult {
        let type = add.payload.elementType
        if add.parentElementUuid != nil, add.parentClientRef != nil {
            throw StoreError.badRequest(
                detail: "pass parentElementUuid OR parentClientRef, not both")
        }
        var parentUuid = add.parentElementUuid
        if let ref = add.parentClientRef {
            guard let resolved = ledger[ref] else {
                throw StoreError.badRequest(detail:
                    "parentClientRef '\(ref)' does not name an earlier elementAdd in this batch")
            }
            parentUuid = resolved
        }
        let parent = try parentUuid.map { try self.fetchElementInfo(db, uuid: $0) }
        try self.validateDiagramElementShape(
            db, diagramUuid: diagram.uuid, type: type, parent: parent, payload: add.payload)

        let code: String
        if let requested = add.code {
            try DopeCode.validateCode(requested, field: "element code")
            code = requested
        } else {
            code = try self.mintElementCode(db, diagramUuid: diagram.uuid, type: type)
        }
        if let description = add.description, description.count > 512 {
            throw StoreError.badRequest(detail: "element description exceeds 512 characters")
        }
        let sortOrder: Int
        if let requested = add.sortOrder {
            sortOrder = requested
        } else if let parentUuid {
            sortOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM diagram_element
                WHERE parent_element_uuid = ?
                """, arguments: [parentUuid]) ?? 0
        } else {
            sortOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1 FROM diagram_element
                WHERE diagram_uuid = ? AND parent_element_uuid IS NULL
                """, arguments: [diagram.uuid]) ?? 0
        }
        if let scale = add.scale, scale <= 0 {
            throw StoreError.badRequest(detail: "scale must be > 0")
        }

        let uuid = try self.insertBase(db, table: "diagram_element", extra: [
            "diagram_uuid": diagram.uuid,
            "parent_element_uuid": parentUuid,
            "element_type": type.rawValue,
            "code": code,
            "name": add.name ?? type.defaultName,
            "description": add.description ?? "",
            "sort_order": sortOrder,
            "center_x": add.centerX ?? 0,
            "center_y": add.centerY ?? 0,
            "element_z": add.elementZ ?? 0,
            "scale": add.scale ?? 1,
        ])
        try self.insertSubtypeRow(db, elementUuid: uuid, payload: add.payload)
        if let ref = add.clientRef { ledger[ref] = uuid }
        return DiagramMutationResult(
            index: index, kind: "element_add", clientRef: add.clientRef,
            uuid: uuid, version: 0)
    }

    private func applyElementUpdate(
        _ db: Database, diagram: DiagramRow, update: DiagramElementUpdate, index: Int
    ) throws -> DiagramMutationResult {
        let info = try self.fetchElementInfo(db, uuid: update.elementUuid)
        guard info.diagramUuid == diagram.uuid else {
            throw StoreError.badRequest(detail:
                "element \(update.elementUuid) belongs to a different diagram")
        }

        var set: [String: (any DatabaseValueConvertible)?] = [:]
        if let code = update.code {
            try DopeCode.validateCode(code, field: "element code")
            set["code"] = code
        }
        if let name = update.name { set["name"] = name }
        if let description = update.description {
            guard description.count <= 512 else {
                throw StoreError.badRequest(detail: "element description exceeds 512 characters")
            }
            set["description"] = description
        }
        if let sortOrder = update.sortOrder { set["sort_order"] = sortOrder }
        if let centerX = update.centerX { set["center_x"] = centerX }
        if let centerY = update.centerY { set["center_y"] = centerY }
        if let elementZ = update.elementZ { set["element_z"] = elementZ }
        if let scale = update.scale {
            guard scale > 0 else { throw StoreError.badRequest(detail: "scale must be > 0") }
            set["scale"] = scale
        }
        if let newParent = update.parentElementUuid {
            guard newParent != info.uuid else {
                throw StoreError.badRequest(detail: "an element cannot parent itself")
            }
            set["parent_element_uuid"] = newParent
        }

        // Validate the FINAL (parent, payload) shape — reparent and payload
        // can change in one call.
        let finalParentUuid = update.parentElementUuid ?? info.parentElementUuid
        let finalParent = try finalParentUuid.map { try self.fetchElementInfo(db, uuid: $0) }
        let currentPayload = update.payload
        if let payload = currentPayload {
            try self.validateDiagramElementShape(
                db, diagramUuid: diagram.uuid, type: info.type,
                parent: finalParent, payload: payload)
        } else if update.parentElementUuid != nil {
            // Reparent without a payload still needs the containment check;
            // fabricate nothing — check the parent-type rule directly.
            let spec = DiagramElementTypeSpec.spec(for: info.type)
            guard let allowed = spec.allowedParentTypes else {
                throw StoreError.badRequest(detail:
                    "\(info.type.rawValue) is a top-level element type and cannot be reparented")
            }
            guard let finalParent, allowed.contains(finalParent.type) else {
                throw StoreError.badRequest(detail:
                    "a \(info.type.rawValue) cannot live under a "
                    + "\(finalParent?.type.rawValue ?? "missing parent") (legal: "
                    + allowed.map(\.rawValue).sorted().joined(separator: "/") + ")")
            }
            guard finalParent.diagramUuid == diagram.uuid else {
                throw StoreError.badRequest(detail:
                    "parent element \(finalParent.uuid) belongs to a different diagram")
            }
        }
        guard !set.isEmpty || update.payload != nil else {
            throw StoreError.emptyUpdate(entity: "diagram_element")
        }

        // updateBase with an empty set still bumps version + updated_at under
        // the optimistic-lock guard — exactly right for a payload-only edit
        // (the element row's version IS the aggregate lock).
        try self.updateBase(db, table: "diagram_element", uuid: info.uuid,
                            expectedVersion: update.expectedVersion, set: set)
        if let payload = update.payload {
            try self.replaceSubtypeRow(db, elementUuid: info.uuid, payload: payload)
        }
        guard let version = try Int64.fetchOne(
            db, sql: "SELECT version FROM diagram_element WHERE uuid = ?", arguments: [info.uuid]
        ) else {
            throw StoreError.corruptState(entity: "diagram_element", detail: "vanished after update")
        }
        return DiagramMutationResult(index: index, kind: "element_update",
                                     uuid: info.uuid, version: version)
    }

    private func applyElementDelete(
        _ db: Database, diagram: DiagramRow, delete: DiagramElementDelete, index: Int
    ) throws -> DiagramMutationResult {
        let info = try self.fetchElementInfo(db, uuid: delete.elementUuid)
        guard info.diagramUuid == diagram.uuid else {
            throw StoreError.badRequest(detail:
                "element \(delete.elementUuid) belongs to a different diagram")
        }
        // Nesting depth is exactly 2 (top-level + children), so the subtree
        // count is self + direct children.
        let children = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM diagram_element WHERE parent_element_uuid = ?",
            arguments: [info.uuid]) ?? 0
        // Plain CASCADE unwinds everything: children via the self-FK, subtype
        // rows via element_uuid, vertex rows via the subtype FKs. No RESTRICT
        // anywhere in the family.
        try self.deleteBase(db, table: "diagram_element", uuid: info.uuid,
                            expectedVersion: delete.expectedVersion)
        return DiagramMutationResult(index: index, kind: "element_delete",
                                     uuid: info.uuid, cascadedElements: children + 1)
    }

    private func applyDiagramRowUpdate(
        _ db: Database, diagram: DiagramRow, update: DiagramRowUpdate, index: Int
    ) throws -> DiagramMutationResult {
        var set: [String: (any DatabaseValueConvertible)?] = [:]
        if let code = update.code {
            try DopeCode.validateCode(code, field: "diagram code")
            set["code"] = code
        }
        if let name = update.name { set["name"] = name }
        if let description = update.description {
            guard description.count <= 512 else {
                throw StoreError.badRequest(detail: "diagram description exceeds 512 characters")
            }
            set["description"] = description
        }

        var finalTier = DiagramTier(rawValue: diagram.tier)
        if let promotion = update.promotion {
            let owner: DiagramOwner
            switch promotion.tier {
            case .project:
                owner = try self.resolveDiagramOwner(
                    db, projectUuid: promotion.ownerUuid, instanceUuid: nil,
                    sessionUuid: nil, promptUuid: nil)
            case .instance:
                owner = try self.resolveDiagramOwner(
                    db, projectUuid: nil, instanceUuid: promotion.ownerUuid,
                    sessionUuid: nil, promptUuid: nil)
            case .session:
                owner = try self.resolveDiagramOwner(
                    db, projectUuid: nil, instanceUuid: nil,
                    sessionUuid: promotion.ownerUuid, promptUuid: nil)
            case .prompt:
                owner = try self.resolveDiagramOwner(
                    db, projectUuid: nil, instanceUuid: nil,
                    sessionUuid: nil, promptUuid: promotion.ownerUuid)
            }
            guard owner.projectUuid == diagram.projectUuid else {
                throw StoreError.badRequest(detail:
                    "promotion target resolves to a different project — a diagram never changes project")
            }
            // Same-code collision at the new tier would trip the partial
            // unique index mid-UPDATE; pre-check for the friendly message.
            let finalCode = update.code ?? diagram.code
            if try Row.fetchOne(db, sql: """
                SELECT uuid FROM diagram
                WHERE tier = ? AND \(owner.ownerColumn) = ? AND code = ? AND uuid != ?
                """, arguments: [owner.tier.rawValue, owner.ownerUuid, finalCode, diagram.uuid]
            ) != nil {
                throw StoreError.badRequest(detail:
                    "a diagram coded '\(finalCode)' already exists at the target tier")
            }
            set["tier"] = owner.tier.rawValue
            // updateValue, not subscript: typed-nil subscript assignment
            // REMOVES the key and the NULL-out silently vanishes (the
            // base_composable_uuid lesson).
            set.updateValue(owner.instanceUuid, forKey: "instance_uuid")
            set.updateValue(owner.sessionUuid, forKey: "session_uuid")
            set.updateValue(owner.promptUuid, forKey: "prompt_uuid")
            finalTier = owner.tier
        }

        if let patch = update.gmccDiagramPath {
            switch patch {
            case .set(let path):
                guard finalTier != .project else {
                    throw StoreError.badRequest(detail:
                        "gmcc_diagram_path is unresolvable at PROJECT tier (no instance root)")
                }
                set["gmcc_diagram_path"] = path
            case .clear:
                set.updateValue(nil, forKey: "gmcc_diagram_path")
            }
        } else if finalTier == .project, diagram.gmccDiagramPath != nil {
            // Promotion to PROJECT with a path still set would trip the
            // schema CHECK — clear it as part of the promotion.
            set.updateValue(nil, forKey: "gmcc_diagram_path")
        }

        guard !set.isEmpty else {
            throw StoreError.emptyUpdate(entity: "diagram")
        }
        try self.updateBase(db, table: "diagram", uuid: diagram.uuid,
                            expectedVersion: update.expectedVersion, set: set)
        guard let version = try Int64.fetchOne(
            db, sql: "SELECT version FROM diagram WHERE uuid = ?", arguments: [diagram.uuid]
        ) else {
            throw StoreError.corruptState(entity: "diagram", detail: "vanished after update")
        }
        return DiagramMutationResult(index: index, kind: "diagram_update",
                                     uuid: diagram.uuid, version: version)
    }

    // MARK: - Subtype persistence (whole-row insert / whole-row replace —
    // dispatched through the payload's own switch, so a sixth element type
    // cannot compile without a branch here)

    private func insertSubtypeRow(
        _ db: Database, elementUuid: String, payload: DiagramElementPayload
    ) throws {
        switch payload {
        case .drawingLayer(let p):
            _ = try insertBase(db, table: "diagram_drawing_layer", extra: [
                "element_uuid": elementUuid,
                "opacity": p.opacity,
                "visible": p.visible ? 1 : 0,
                "locked": p.locked ? 1 : 0,
            ])
        case .drawingStroke(let p):
            _ = try insertBase(db, table: "diagram_drawing_stroke", extra: [
                "element_uuid": elementUuid,
                "tool": p.tool.rawValue,
                "stroke_color": p.strokeColor,
                "stroke_width": p.strokeWidth,
            ])
            try replaceVertices(db, table: "diagram_stroke_vertex",
                                parentColumn: "stroke_element_uuid",
                                elementUuid: elementUuid, vertices: p.vertices,
                                withPressure: true)
        case .drawingShape(let p):
            _ = try insertBase(db, table: "diagram_drawing_shape", extra: [
                "element_uuid": elementUuid,
                "shape_kind": p.shapeKind.rawValue,
                "stroke_color": p.strokeColor,
                "stroke_width": p.strokeWidth,
                "fill_color": p.fillColor,
                "corner_radius": p.cornerRadius,
            ])
            try replaceVertices(db, table: "diagram_shape_vertex",
                                parentColumn: "shape_element_uuid",
                                elementUuid: elementUuid, vertices: p.vertices,
                                withPressure: false)
        case .dopeScope(let p):
            _ = try insertBase(db, table: "diagram_dope_scope", extra: [
                "element_uuid": elementUuid,
                "dope_scope_code": p.dopeScopeCode,
            ])
        case .dopeEntity(let p):
            _ = try insertBase(db, table: "diagram_dope_entity", extra: [
                "element_uuid": elementUuid,
                "entity_code": p.entityCode,
            ])
        }
    }

    /// Whole-row replacement: subtype rows are owned value rows (the element
    /// version is the aggregate lock), so a payload update rewrites every
    /// subtype column and the vertex set — no field patching, no clear flags.
    private func replaceSubtypeRow(
        _ db: Database, elementUuid: String, payload: DiagramElementPayload
    ) throws {
        let now = Store.isoNow()
        func requireRow(_ table: String) throws {
            guard db.changesCount > 0 else {
                throw StoreError.corruptState(
                    entity: table, detail: "element \(elementUuid) has no subtype row")
            }
        }
        switch payload {
        case .drawingLayer(let p):
            try db.execute(sql: """
                UPDATE diagram_drawing_layer
                SET opacity = ?, visible = ?, locked = ?, updated_at = ?
                WHERE element_uuid = ?
                """, arguments: [p.opacity, p.visible ? 1 : 0, p.locked ? 1 : 0,
                                 now, elementUuid])
            try requireRow("diagram_drawing_layer")
        case .drawingStroke(let p):
            try db.execute(sql: """
                UPDATE diagram_drawing_stroke
                SET tool = ?, stroke_color = ?, stroke_width = ?, updated_at = ?
                WHERE element_uuid = ?
                """, arguments: [p.tool.rawValue, p.strokeColor, p.strokeWidth,
                                 now, elementUuid])
            try requireRow("diagram_drawing_stroke")
            try replaceVertices(db, table: "diagram_stroke_vertex",
                                parentColumn: "stroke_element_uuid",
                                elementUuid: elementUuid, vertices: p.vertices,
                                withPressure: true)
        case .drawingShape(let p):
            try db.execute(sql: """
                UPDATE diagram_drawing_shape
                SET shape_kind = ?, stroke_color = ?, stroke_width = ?,
                    fill_color = ?, corner_radius = ?, updated_at = ?
                WHERE element_uuid = ?
                """, arguments: [p.shapeKind.rawValue, p.strokeColor, p.strokeWidth,
                                 p.fillColor, p.cornerRadius, now, elementUuid])
            try requireRow("diagram_drawing_shape")
            try replaceVertices(db, table: "diagram_shape_vertex",
                                parentColumn: "shape_element_uuid",
                                elementUuid: elementUuid, vertices: p.vertices,
                                withPressure: false)
        case .dopeScope(let p):
            try db.execute(sql: """
                UPDATE diagram_dope_scope SET dope_scope_code = ?, updated_at = ?
                WHERE element_uuid = ?
                """, arguments: [p.dopeScopeCode, now, elementUuid])
            try requireRow("diagram_dope_scope")
        case .dopeEntity(let p):
            try db.execute(sql: """
                UPDATE diagram_dope_entity SET entity_code = ?, updated_at = ?
                WHERE element_uuid = ?
                """, arguments: [p.entityCode, now, elementUuid])
            try requireRow("diagram_dope_entity")
        }
    }

    /// Atomic whole-set vertex replacement: DELETE + ordered re-INSERT by
    /// seq, inside the caller's transaction. Fresh uuids every time — vertex
    /// rows are BaseEntity rows (user decision) but NOT stable identities.
    private func replaceVertices(
        _ db: Database, table: String, parentColumn: String,
        elementUuid: String, vertices: [DiagramVertex], withPressure: Bool
    ) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE \(parentColumn) = ?",
                       arguments: [elementUuid])
        for (seq, vertex) in vertices.enumerated() {
            var extra: [String: (any DatabaseValueConvertible)?] = [
                parentColumn: elementUuid,
                "seq": seq,
                "x": vertex.x,
                "y": vertex.y,
            ]
            if withPressure { extra["pressure"] = vertex.pressure }
            _ = try insertBase(db, table: table, extra: extra)
        }
    }

    // MARK: - Granular verbs (one-mutation batches; there is no second body)

    public func diagramNodeAdd(_ req: DiagramNodeAddRequest) throws -> DiagramNodeResponse {
        let batch = try diagramBatchApply(DiagramBatchApplyRequest(
            diagramUuid: req.diagramUuid, mutations: [.elementAdd(req.add)]))
        let result = batch.results[0]
        return DiagramNodeResponse(uuid: result.uuid ?? "", version: result.version ?? 0,
                                   diagramUuid: batch.diagramUuid, revision: batch.revision)
    }

    public func diagramNodeUpdate(_ req: DiagramNodeUpdateRequest) throws -> DiagramNodeResponse {
        let diagramUuid = try owningDiagramUuid(elementUuid: req.update.elementUuid)
        let batch = try diagramBatchApply(DiagramBatchApplyRequest(
            diagramUuid: diagramUuid, mutations: [.elementUpdate(req.update)]))
        let result = batch.results[0]
        return DiagramNodeResponse(uuid: result.uuid ?? "", version: result.version ?? 0,
                                   diagramUuid: batch.diagramUuid, revision: batch.revision)
    }

    public func diagramNodeDelete(_ req: DiagramNodeDeleteRequest) throws -> DiagramNodeDeleteResponse {
        let diagramUuid = try owningDiagramUuid(elementUuid: req.delete.elementUuid)
        let batch = try diagramBatchApply(DiagramBatchApplyRequest(
            diagramUuid: diagramUuid, mutations: [.elementDelete(req.delete)]))
        let result = batch.results[0]
        return DiagramNodeDeleteResponse(
            deletedUuid: result.uuid ?? "", cascadedElements: result.cascadedElements ?? 1,
            diagramUuid: batch.diagramUuid, revision: batch.revision)
    }

    private func owningDiagramUuid(elementUuid: String) throws -> String {
        try dbQueue.read { db in
            guard let uuid = try String.fetchOne(
                db, sql: "SELECT diagram_uuid FROM diagram_element WHERE uuid = ?",
                arguments: [elementUuid]
            ) else {
                throw StoreError.notFound(entity: "diagram_element", key: elementUuid)
            }
            return uuid
        }
    }
}
