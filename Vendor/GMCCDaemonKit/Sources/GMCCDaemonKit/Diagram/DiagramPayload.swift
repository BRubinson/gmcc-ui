import Foundation

/// The load-bearing tagged union: ONE type drives the wire codec, store
/// persistence, containment validation, and the exhaustive-switch render
/// protocol. `DopeNodeFields`' flat-optional union is deliberately NOT
/// extended, and no clear* flags exist anywhere on this surface — an update
/// carrying a payload REPLACES the subtype row (and vertex set) wholesale,
/// so the typed-nil SET-dictionary idiom (the 6ffbda9 bug class) is
/// structurally impossible here.
///
/// Encoding: `{"kind": "<element_type raw>", "fields": {...}}`. `kind` and
/// `fields` are single-word keys — fixed points of the snake_case strategies
/// (the Envelope.swift hazard); each case struct's own camelCase keys go
/// through the shared strategy normally.
public enum DiagramElementPayload: Codable, Hashable, Sendable {
    case drawingLayer(DrawingLayerPayload)
    case drawingStroke(DrawingStrokePayload)
    case drawingShape(DrawingShapePayload)
    case dopeScope(DopeScopePayload)
    case dopeEntity(DopeEntityPayload)

    /// The tag IS the element type — payload/element_type agreement is
    /// definitional on add and validated on update (type morphing refused).
    public var elementType: DiagramElementType {
        switch self {
        case .drawingLayer: return .drawingLayer
        case .drawingStroke: return .drawingStroke
        case .drawingShape: return .drawingShape
        case .dopeScope: return .dopeScope
        case .dopeEntity: return .dopeEntity
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        guard let type = DiagramElementType(rawValue: kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown diagram element payload kind '\(kind)'")
        }
        switch type {
        case .drawingLayer:
            self = .drawingLayer(try c.decode(DrawingLayerPayload.self, forKey: .fields))
        case .drawingStroke:
            self = .drawingStroke(try c.decode(DrawingStrokePayload.self, forKey: .fields))
        case .drawingShape:
            self = .drawingShape(try c.decode(DrawingShapePayload.self, forKey: .fields))
        case .dopeScope:
            self = .dopeScope(try c.decode(DopeScopePayload.self, forKey: .fields))
        case .dopeEntity:
            self = .dopeEntity(try c.decode(DopeEntityPayload.self, forKey: .fields))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementType.rawValue, forKey: .kind)
        switch self {
        case .drawingLayer(let p): try c.encode(p, forKey: .fields)
        case .drawingStroke(let p): try c.encode(p, forKey: .fields)
        case .drawingShape(let p): try c.encode(p, forKey: .fields)
        case .dopeScope(let p): try c.encode(p, forKey: .fields)
        case .dopeEntity(let p): try c.encode(p, forKey: .fields)
        }
    }
}

/// One stroke/shape vertex as it rides the wire — INSIDE the payload, so the
/// whole element is one value. Persisted as full BaseEntity rows (user
/// decision); written as whole-set replacement, so vertex row uuids are not
/// stable across edits (vertices are not elements).
/// Coordinates are ELEMENT-LOCAL (relative to the element's center).
public struct DiagramVertex: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let pressure: Double?

    public init(x: Double, y: Double, pressure: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    private enum CodingKeys: String, CodingKey { case x, y, pressure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure)
    }
}

/// Missing keys decode to the schema defaults (a hand-authored --content
/// JSON should not have to spell every column), so each payload struct
/// hand-writes its decode with decodeIfPresent + default.

public struct DrawingLayerPayload: Codable, Hashable, Sendable {
    public let opacity: Double
    public let visible: Bool
    public let locked: Bool

    public init(opacity: Double = 1, visible: Bool = true, locked: Bool = false) {
        self.opacity = opacity
        self.visible = visible
        self.locked = locked
    }

    private enum CodingKeys: String, CodingKey { case opacity, visible, locked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

public struct DrawingStrokePayload: Codable, Hashable, Sendable {
    public let tool: DiagramStrokeTool
    public let strokeColor: String
    public let strokeWidth: Double
    public let vertices: [DiagramVertex]

    public init(
        tool: DiagramStrokeTool = .pencil, strokeColor: String = "#1a1a1a",
        strokeWidth: Double = 2, vertices: [DiagramVertex] = []
    ) {
        self.tool = tool
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.vertices = vertices
    }

    private enum CodingKeys: String, CodingKey {
        case tool, strokeColor, strokeWidth, vertices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(DiagramStrokeTool.self, forKey: .tool) ?? .pencil
        strokeColor = try c.decodeIfPresent(String.self, forKey: .strokeColor) ?? "#1a1a1a"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2
        vertices = try c.decodeIfPresent([DiagramVertex].self, forKey: .vertices) ?? []
    }
}

public struct DrawingShapePayload: Codable, Hashable, Sendable {
    public let shapeKind: DiagramShapeKind
    public let strokeColor: String
    public let strokeWidth: Double
    public let fillColor: String?
    public let cornerRadius: Double?
    public let vertices: [DiagramVertex]

    public init(
        shapeKind: DiagramShapeKind, strokeColor: String = "#1a1a1a",
        strokeWidth: Double = 2, fillColor: String? = nil,
        cornerRadius: Double? = nil, vertices: [DiagramVertex] = []
    ) {
        self.shapeKind = shapeKind
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.vertices = vertices
    }

    private enum CodingKeys: String, CodingKey {
        case shapeKind, strokeColor, strokeWidth, fillColor, cornerRadius, vertices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shapeKind = try c.decode(DiagramShapeKind.self, forKey: .shapeKind)
        strokeColor = try c.decodeIfPresent(String.self, forKey: .strokeColor) ?? "#1a1a1a"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2
        fillColor = try c.decodeIfPresent(String.self, forKey: .fillColor)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
        vertices = try c.decodeIfPresent([DiagramVertex].self, forKey: .vertices) ?? []
    }
}

/// fk-by-code binding to a dope scope. Resolution runs at READ time through
/// the diagram row's own session/prompt context (the dopeGet ladder), never
/// at write time — a dangling code is a legal, renderable ghost state.
public struct DopeScopePayload: Codable, Hashable, Sendable {
    public let dopeScopeCode: String

    public init(dopeScopeCode: String) {
        self.dopeScopeCode = dopeScopeCode
    }
}

/// fk-by-code binding to a dope domain entity — 2-segment `domain.entity`
/// (DopeCode.parseEntityRef-validated on write; existence NOT checked).
public struct DopeEntityPayload: Codable, Hashable, Sendable {
    public let entityCode: String

    public init(entityCode: String) {
        self.entityCode = entityCode
    }
}

/// Tri-state field write for nullable columns: absent = leave alone,
/// `{"op": "set", "value": …}` = write, `{"op": "clear"}` = NULL. The typed
/// replacement for dope's clear* flag pairs; one use site this pass
/// (diagram.gmcc_diagram_path), available to future surfaces.
public enum FieldPatch<T: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case set(T)
    case clear

    private enum CodingKeys: String, CodingKey { case op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "set":
            self = .set(try c.decode(T.self, forKey: .value))
        case "clear":
            self = .clear
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c, debugDescription: "unknown field patch op '\(op)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let value):
            try c.encode("set", forKey: .op)
            try c.encode(value, forKey: .value)
        case .clear:
            try c.encode("clear", forKey: .op)
        }
    }
}
