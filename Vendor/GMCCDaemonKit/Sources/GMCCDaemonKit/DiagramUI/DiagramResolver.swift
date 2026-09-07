import CoreGraphics
import Foundation

/// The pure pre-pass that turns (DiagramTree + hydrated dope trees) into a
/// ready-to-draw `ResolvedDiagram`. Transforms, sibling z-order, dope
/// injection, `.absent` ghosts, FK edges, and deterministic colors are all
/// computed exactly ONCE here — views are dumb exhaustive switches, and the
/// binding/ghost/geometry tests target this type in plain XCTest with zero
/// SwiftUI.
///
/// Imports Foundation + CoreGraphics only. This file is deliberately outside
/// the `#if canImport(SwiftUI)` guard the view files carry.

/// Caller-assembled dope context: one hydrated tree per RESOLVED dope_scope
/// binding code (from DIAGRAM_GET's bindings + one DOPE_GET each). Codes the
/// caller could not resolve are simply absent — their elements ghost.
public struct DiagramDopeContext: Sendable {
    public struct Entry: Sendable {
        public let tree: DopeScopeTree
        /// "prompt" | "session_base" — surfaced on the scope card.
        public let resolvedVia: String

        public init(tree: DopeScopeTree, resolvedVia: String) {
            self.tree = tree
            self.resolvedVia = resolvedVia
        }
    }

    /// Keyed by dope scope code.
    public let entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }
}

public struct ResolvedDiagram: Sendable {
    /// Union of every drawn frame + edge, pre-padding — the screenshot
    /// viewport (content-derived, never a window guess).
    public let contentBounds: CGRect
    /// Painter-sorted ((elementZ, code) among siblings; depth-first global).
    public let topLevel: [ResolvedElement]
    /// FK edges between entity cards, computed in their own pass.
    public let edges: [ResolvedEdge]
    public let environment: DiagramRenderEnvironment

    public init(contentBounds: CGRect, topLevel: [ResolvedElement],
                edges: [ResolvedEdge], environment: DiagramRenderEnvironment) {
        self.contentBounds = contentBounds
        self.topLevel = topLevel
        self.edges = edges
        self.environment = environment
    }
}

public struct ResolvedElement: Sendable {
    public let uuid: String
    public let code: String
    public let name: String
    /// Diagram-space frame (transforms already composed).
    public let frame: CGRect
    public let elementZ: Double
    public let kind: ResolvedElementKind
    public let children: [ResolvedElement]

    public init(uuid: String, code: String, name: String, frame: CGRect,
                elementZ: Double, kind: ResolvedElementKind, children: [ResolvedElement]) {
        self.uuid = uuid
        self.code = code
        self.name = name
        self.frame = frame
        self.elementZ = elementZ
        self.kind = kind
        self.children = children
    }
}

/// The exhaustive render-kind switch — the prompt's critical design pattern,
/// compiler-enforced: a new element type (or the ghost state) cannot ship
/// without every render site handling it.
public enum ResolvedElementKind: Sendable {
    case layer(LayerStyle)
    case stroke(ResolvedStroke)
    case shape(ResolvedShape)
    case scopeCard(ResolvedScopeCard)
    case entityCard(EntityCardModel)
    /// The LEGAL dangling-binding state: a dope_scope code matching no scope,
    /// or an entity code matching nothing in the resolved scope. A ghost,
    /// never an error.
    case absentScope(code: String)
    case absentEntity(code: String)
}

public struct LayerStyle: Hashable, Sendable {
    public let opacity: Double
    public let visible: Bool
    public let locked: Bool

    public init(opacity: Double, visible: Bool, locked: Bool) {
        self.opacity = opacity
        self.visible = visible
        self.locked = locked
    }
}

public struct ResolvedStroke: Sendable {
    /// Diagram-space points (element-local vertices transformed).
    public let points: [CGPoint]
    public let color: String
    /// Scales with the accumulated transform.
    public let lineWidth: Double
    public let tool: DiagramStrokeTool

    public init(points: [CGPoint], color: String, lineWidth: Double, tool: DiagramStrokeTool) {
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.tool = tool
    }
}

public struct ResolvedShape: Sendable {
    public let kind: DiagramShapeKind
    public let points: [CGPoint]
    public let strokeColor: String
    public let lineWidth: Double
    public let fillColor: String?
    public let cornerRadius: Double?

    public init(kind: DiagramShapeKind, points: [CGPoint], strokeColor: String,
                lineWidth: Double, fillColor: String?, cornerRadius: Double?) {
        self.kind = kind
        self.points = points
        self.strokeColor = strokeColor
        self.lineWidth = lineWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
    }
}

public struct ResolvedScopeCard: Sendable {
    public let dopeScopeCode: String
    public let scopeName: String
    /// "prompt" | "session_base" — which ladder rung won.
    public let resolvedVia: String

    public init(dopeScopeCode: String, scopeName: String, resolvedVia: String) {
        self.dopeScopeCode = dopeScopeCode
        self.scopeName = scopeName
        self.resolvedVia = resolvedVia
    }
}

/// dbdiagram-style card contents — 100% derived state (authored geometry is
/// the only thing persisted): header colored by the DOMAIN code's stable
/// hue, entity name + code, property rows name-left/type-right, badges.
public struct EntityCardModel: Sendable {
    public struct PropertyRow: Hashable, Sendable {
        public let name: String
        public let typeLabel: String
        /// "NN" (not nullable), "UQ" (unique), "AI" (auto-increment),
        /// "FK" (relationship), "B" (materialized from a composed base).
        public let badges: [String]

        public init(name: String, typeLabel: String, badges: [String]) {
            self.name = name
            self.typeLabel = typeLabel
            self.badges = badges
        }
    }

    /// 2-segment domain.entity binding code.
    public let entityCode: String
    public let entityName: String
    public let domainCode: String
    /// Stable FNV-1a hue in [0, 1).
    public let headerHue: Double
    public let rows: [PropertyRow]

    public init(entityCode: String, entityName: String, domainCode: String,
                headerHue: Double, rows: [PropertyRow]) {
        self.entityCode = entityCode
        self.entityName = entityName
        self.domainCode = domainCode
        self.headerHue = headerHue
        self.rows = rows
    }
}

public struct ResolvedEdge: Sendable {
    /// Diagram-space anchor points on the two card borders. When `routed`,
    /// these are the routed polyline's real endpoints (`points.first/.last`).
    public let from: CGPoint
    public let to: CGPoint
    public let fromElementUuid: String
    public let toElementUuid: String
    /// `domain.entity.property` of the relationship property.
    public let propertyRef: String
    /// Diagram-space orthogonal polyline, >= 2 points — `[from, to]` when
    /// routing declined (`routed == false`) and the view keeps the legacy
    /// cubic. Derived state: never persisted, never on the wire.
    public let points: [CGPoint]
    public let routed: Bool

    public init(from: CGPoint, to: CGPoint, fromElementUuid: String,
                toElementUuid: String, propertyRef: String,
                points: [CGPoint]? = nil, routed: Bool = false) {
        self.from = from
        self.to = to
        self.fromElementUuid = fromElementUuid
        self.toElementUuid = toElementUuid
        self.propertyRef = propertyRef
        self.points = points ?? [from, to]
        self.routed = routed
    }
}

public enum DiagramResolver {

    /// The one entry point. Semantics frozen here:
    ///  - `center_x/y` are PARENT-space; vertices are element-local; `scale`
    ///    composes multiplicatively; stroke width scales with the
    ///    accumulated transform.
    ///  - `element_z` orders SIBLINGS only, tie-broken by code; global paint
    ///    order is depth-first (a child never interleaves between another
    ///    parent's children — deliberate).
    ///  - Ghost injection happens here, once: an unresolved scope code makes
    ///    the scope card `.absentScope` and its entity children
    ///    `.absentEntity`; a resolved scope with a code-matches-nothing
    ///    entity makes just that card `.absentEntity`.
    public static func resolve(
        _ tree: DiagramTree,
        dope: DiagramDopeContext,
        environment: DiagramRenderEnvironment = DiagramRenderEnvironment()
    ) -> ResolvedDiagram {
        var entityFrames: [String: (frame: CGRect, entityCode: String,
                                    scopeCode: String, scale: Double)] = [:]
        var obstacles: [DiagramEdgeRouter.Obstacle] = []

        let sortedTop = tree.elements.sorted(by: siblingOrder)
        let topLevel = sortedTop.map { node in
            resolveElement(node, parentCenter: .zero, parentScale: 1,
                           scope: scopeEntry(for: node, dope: dope),
                           environment: environment, entityFrames: &entityFrames,
                           obstacles: &obstacles)
        }

        let edges = resolveEdges(dope: dope, entityFrames: entityFrames,
                                 environment: environment, obstacles: obstacles)

        var bounds = CGRect.null
        func union(_ element: ResolvedElement) {
            bounds = bounds.union(element.frame)
            for child in element.children { union(child) }
        }
        for element in topLevel { union(element) }
        for edge in edges {
            // Every routed point, not just the endpoints — detours around
            // perimeter cards must never clip out of the screenshot viewport.
            for point in edge.points {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
        }
        if bounds.isNull { bounds = CGRect(x: 0, y: 0, width: 320, height: 200) }

        return ResolvedDiagram(contentBounds: bounds, topLevel: topLevel,
                               edges: edges, environment: environment)
    }

    // MARK: - Internals

    private static func siblingOrder(_ a: DiagramElementNode, _ b: DiagramElementNode) -> Bool {
        if a.base.elementZ != b.base.elementZ { return a.base.elementZ < b.base.elementZ }
        return a.base.code < b.base.code
    }

    private static func scopeEntry(
        for node: DiagramElementNode, dope: DiagramDopeContext
    ) -> DiagramDopeContext.Entry? {
        if case .dopeScope(let payload) = node.payload {
            return dope.entries[payload.dopeScopeCode]
        }
        return nil
    }

    private static func resolveElement(
        _ node: DiagramElementNode, parentCenter: CGPoint, parentScale: Double,
        scope: DiagramDopeContext.Entry?, environment: DiagramRenderEnvironment,
        entityFrames: inout [String: (frame: CGRect, entityCode: String,
                                      scopeCode: String, scale: Double)],
        obstacles: inout [DiagramEdgeRouter.Obstacle]
    ) -> ResolvedElement {
        let scale = parentScale * node.base.scale
        let center = CGPoint(x: parentCenter.x + node.base.centerX * parentScale,
                             y: parentCenter.y + node.base.centerY * parentScale)

        // Children first — container frames derive from child extents.
        let sortedChildren = node.children.sorted(by: siblingOrder)
        var children: [ResolvedElement] = []

        let kind: ResolvedElementKind
        var frame: CGRect

        switch node.payload {
        case .drawingLayer(let payload):
            children = sortedChildren.map {
                resolveElement($0, parentCenter: center, parentScale: scale,
                               scope: nil, environment: environment,
                               entityFrames: &entityFrames, obstacles: &obstacles)
            }
            kind = .layer(LayerStyle(opacity: payload.opacity, visible: payload.visible,
                                     locked: payload.locked))
            frame = children.reduce(CGRect.null) { $0.union($1.frame) }
            if frame.isNull {
                frame = CGRect(x: center.x - 100 * scale, y: center.y - 60 * scale,
                               width: 200 * scale, height: 120 * scale)
            }

        case .drawingStroke(let payload):
            let points = payload.vertices.map {
                CGPoint(x: center.x + $0.x * scale, y: center.y + $0.y * scale)
            }
            kind = .stroke(ResolvedStroke(points: points, color: payload.strokeColor,
                                          lineWidth: payload.strokeWidth * scale,
                                          tool: payload.tool))
            frame = points.isEmpty
                ? CGRect(origin: center, size: .zero)
                : points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) {
                    $0.union(CGRect(origin: $1, size: .zero))
                }.insetBy(dx: -payload.strokeWidth * scale, dy: -payload.strokeWidth * scale)

        case .drawingShape(let payload):
            let points = payload.vertices.map {
                CGPoint(x: center.x + $0.x * scale, y: center.y + $0.y * scale)
            }
            kind = .shape(ResolvedShape(kind: payload.shapeKind, points: points,
                                        strokeColor: payload.strokeColor,
                                        lineWidth: payload.strokeWidth * scale,
                                        fillColor: payload.fillColor,
                                        cornerRadius: payload.cornerRadius.map { $0 * scale }))
            frame = points.isEmpty
                ? CGRect(x: center.x - 40 * scale, y: center.y - 40 * scale,
                         width: 80 * scale, height: 80 * scale)
                : points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) {
                    $0.union(CGRect(origin: $1, size: .zero))
                }.insetBy(dx: -payload.strokeWidth * scale, dy: -payload.strokeWidth * scale)

        case .dopeScope(let payload):
            children = sortedChildren.map {
                resolveElement($0, parentCenter: center, parentScale: scale,
                               scope: scope, environment: environment,
                               entityFrames: &entityFrames, obstacles: &obstacles)
            }
            if let scope {
                kind = .scopeCard(ResolvedScopeCard(
                    dopeScopeCode: payload.dopeScopeCode,
                    scopeName: scope.tree.body.name,
                    resolvedVia: scope.resolvedVia))
            } else {
                kind = .absentScope(code: payload.dopeScopeCode)
            }
            frame = children.reduce(CGRect.null) { $0.union($1.frame) }
            frame = frame.isNull
                ? CGRect(x: center.x - 140 * scale, y: center.y - 90 * scale,
                         width: 280 * scale, height: 180 * scale)
                : frame.insetBy(dx: -24 * scale, dy: -32 * scale)

        case .dopeEntity(let payload):
            if let scope, let model = entityCard(payload.entityCode, in: scope.tree) {
                let rowCount = max(model.rows.count, 1)
                let width = environment.cardWidth * scale
                let height = (environment.cardHeaderHeight
                              + Double(rowCount) * environment.cardRowHeight + 8) * scale
                frame = CGRect(x: center.x - width / 2, y: center.y - height / 2,
                               width: width, height: height)
                kind = .entityCard(model)
                entityFrames[node.identity.uuid] =
                    (frame, payload.entityCode, scope.tree.body.code, scale)
                obstacles.append(DiagramEdgeRouter.Obstacle(frame: frame, scale: scale))
            } else {
                let width = environment.cardWidth * scale
                let height = (environment.cardHeaderHeight + environment.cardRowHeight + 8) * scale
                frame = CGRect(x: center.x - width / 2, y: center.y - height / 2,
                               width: width, height: height)
                kind = .absentEntity(code: payload.entityCode)
                // Ghost cards are obstacles too — edges route around them,
                // they just never produce edges themselves.
                obstacles.append(DiagramEdgeRouter.Obstacle(frame: frame, scale: scale))
            }
        }

        return ResolvedElement(uuid: node.identity.uuid, code: node.base.code,
                               name: node.base.name, frame: frame,
                               elementZ: node.base.elementZ, kind: kind,
                               children: children)
    }

    /// Card contents from the hydrated dope tree: the entity's own
    /// properties plus the composed-base union (walked through the
    /// baseComposableRef chain — bases are never replicated in the db, so
    /// render time is where the union happens).
    static func entityCard(_ entityCode: String, in tree: DopeScopeTree) -> EntityCardModel? {
        let segments = entityCode.split(separator: ".").map(String.init)
        guard segments.count == 2 else { return nil }
        let (domainCode, code) = (segments[0], segments[1])
        guard let domain = tree.domains.first(where: { $0.body.code == domainCode }),
              let entity = domain.entities.first(where: { $0.body.code == code })
        else { return nil }

        func lookupEntity(_ ref: String) -> DopeEntityNode? {
            let parts = ref.split(separator: ".").map(String.init)
            guard parts.count == 2,
                  let d = tree.domains.first(where: { $0.body.code == parts[0] })
            else { return nil }
            return d.entities.first(where: { $0.body.code == parts[1] })
        }

        func rows(for node: DopeEntityNode, fromBase: Bool) -> [EntityCardModel.PropertyRow] {
            node.properties.map { property in
                var badges: [String] = []
                if !property.body.nullable { badges.append("NN") }
                if property.body.isUnique { badges.append("UQ") }
                if property.body.autoIncrement == true { badges.append("AI") }
                if property.body.relatedPropertyRef != nil { badges.append("FK") }
                if fromBase || property.body.baseOriginRef != nil { badges.append("B") }
                let typeLabel: String
                if let enumRef = property.body.enumRef {
                    typeLabel = "enum(\(enumRef.split(separator: ".").last.map(String.init) ?? enumRef))"
                } else if let related = property.body.relatedPropertyRef {
                    typeLabel = "→ \(related)"
                } else {
                    typeLabel = property.body.dataType
                }
                return EntityCardModel.PropertyRow(
                    name: property.body.code, typeLabel: typeLabel, badges: badges)
            }
        }

        var allRows = rows(for: entity, fromBase: false)
        // Composed-base union: chain-walk with a visited set (cycles are
        // refused on write; the set is defensive).
        var seen: Set<String> = [entityCode]
        var baseRef = entity.body.baseComposableRef
        while let ref = baseRef, seen.insert(ref).inserted, let base = lookupEntity(ref) {
            allRows.append(contentsOf: rows(for: base, fromBase: true))
            baseRef = base.body.baseComposableRef
        }

        return EntityCardModel(
            entityCode: entityCode, entityName: entity.body.name,
            domainCode: domainCode,
            headerHue: DiagramPalette.domainHue(domainCode),
            rows: allRows)
    }

    /// The FK edge pass: for every relationship property of every rendered
    /// entity card, if the target property's owning entity also has a card
    /// under the SAME scope element family, draw an edge between the two
    /// card borders.
    /// Base routing padding in points, scaled per-obstacle by accumulated
    /// scale. Coupled to the frozen layout generator's corridors
    /// (diagram_from_dope.py: 50pt gutters, 48pt row gaps) — must stay < 24
    /// or the vertical row-gap corridors close entirely. Deliberately NOT a
    /// DiagramRenderEnvironment knob: it is routing policy, not a render
    /// setting. Internal (not private) so the corridor-arithmetic fixture
    /// pins THIS value against the generator constants — changing it without
    /// updating the fixture breaks loudly.
    static let edgeRoutingPadding: Double = 12

    private static func resolveEdges(
        dope: DiagramDopeContext,
        entityFrames: [String: (frame: CGRect, entityCode: String,
                                scopeCode: String, scale: Double)],
        environment: DiagramRenderEnvironment,
        obstacles: [DiagramEdgeRouter.Obstacle]
    ) -> [ResolvedEdge] {
        // entityCode+scopeCode → (uuid, frame). Built from a SORTED walk with
        // first-wins so duplicate cards binding the same entity always pick
        // the same (lowest-uuid) target — screenshot determinism is a
        // correctness requirement, and dictionary iteration order is not.
        var cardByEntity: [String: (uuid: String, frame: CGRect)] = [:]
        for (uuid, info) in entityFrames.sorted(by: { $0.key < $1.key }) {
            let key = "\(info.scopeCode)|\(info.entityCode)"
            if cardByEntity[key] == nil {
                cardByEntity[key] = (uuid, info.frame)
            }
        }

        // Emission pass: one spec + one legacy fallback pair per FK, in
        // sorted-by-uuid order (which is also the routing order).
        struct EdgeSeed {
            let request: DiagramEdgeRouter.EdgeRequest
            let fallbackFrom: CGPoint
            let fallbackTo: CGPoint
            let fromElementUuid: String
            let toElementUuid: String
            let propertyRef: String
        }
        var seeds: [EdgeSeed] = []
        for (uuid, info) in entityFrames.sorted(by: { $0.key < $1.key }) {
            guard let scope = dope.entries[info.scopeCode] else { continue }
            let segments = info.entityCode.split(separator: ".").map(String.init)
            guard segments.count == 2,
                  let domain = scope.tree.domains.first(where: { $0.body.code == segments[0] }),
                  let entity = domain.entities.first(where: { $0.body.code == segments[1] })
            else { continue }
            for (rowIndex, property) in entity.properties.enumerated() {
                guard let ref = property.body.relatedPropertyRef else { continue }
                let parts = ref.split(separator: ".").map(String.init)
                guard parts.count == 3 else { continue }
                let targetEntityCode = "\(parts[0]).\(parts[1])"
                guard let target = cardByEntity["\(info.scopeCode)|\(targetEntityCode)"],
                      target.uuid != uuid
                else { continue }
                // The edge leaves at the FK property ROW's y. rowIndex maps
                // 1:1 to drawn rows: own properties render first, the
                // composed-base union only appends after them.
                let rowY = info.frame.minY + (environment.cardHeaderHeight
                    + (Double(rowIndex) + 0.5) * environment.cardRowHeight) * info.scale
                let (from, to) = anchorPoints(info.frame, target.frame)
                seeds.append(EdgeSeed(
                    request: DiagramEdgeRouter.EdgeRequest(
                        fromFrame: info.frame, toFrame: target.frame,
                        sourceRowY: rowY,
                        propertyRef: "\(info.entityCode).\(property.body.code)",
                        fromElementUuid: uuid),
                    fallbackFrom: from, fallbackTo: to,
                    fromElementUuid: uuid, toElementUuid: target.uuid,
                    propertyRef: "\(info.entityCode).\(property.body.code)"))
            }
        }

        // Routing pass: one shared-graph call; index i in == index i out.
        let routes = DiagramEdgeRouter.route(edges: seeds.map(\.request),
                                             obstacles: obstacles,
                                             padding: edgeRoutingPadding)
        return zip(seeds, routes).map { seed, route in
            if route.routed, route.points.count >= 2 {
                return ResolvedEdge(
                    from: route.points[0], to: route.points[route.points.count - 1],
                    fromElementUuid: seed.fromElementUuid,
                    toElementUuid: seed.toElementUuid,
                    propertyRef: seed.propertyRef,
                    points: route.points, routed: true)
            }
            return ResolvedEdge(
                from: seed.fallbackFrom, to: seed.fallbackTo,
                fromElementUuid: seed.fromElementUuid,
                toElementUuid: seed.toElementUuid,
                propertyRef: seed.propertyRef)
        }
    }

    /// Side-midpoint anchors: leave from the edge facing the target.
    private static func anchorPoints(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint) {
        if b.midX >= a.midX {
            return (CGPoint(x: a.maxX, y: a.midY), CGPoint(x: b.minX, y: b.midY))
        } else {
            return (CGPoint(x: a.minX, y: a.midY), CGPoint(x: b.maxX, y: b.midY))
        }
    }
}
