import Foundation

// The DIAGRAM tree has exactly two levels (diagram, element), and unlike
// dope they never travel on the wire — the tagged DiagramElementPayload and
// mutation kinds discriminate everything. There is deliberately NO level
// registry: the element-axis registry below (DiagramElementTypeSpec) is the
// single truth for subtype persistence and containment.

/// diagram.tier values — the chain-non-null ownership ladder.
public enum DiagramTier: String, Codable, Hashable, CaseIterable, Sendable {
    case project = "PROJECT"
    case instance = "INSTANCE"
    case session = "SESSION"
    case prompt = "PROMPT"
}

/// diagram_element.element_type values. Raw values are the db discriminators
/// AND the wire payload tags — one string, three layers.
public enum DiagramElementType: String, Codable, Hashable, CaseIterable, Sendable {
    case drawingLayer = "drawing_layer"
    case drawingStroke = "drawing_stroke"
    case drawingShape = "drawing_shape"
    case dopeScope = "dope_scope"
    case dopeEntity = "dope_entity"

    /// Auto-mint prefix for elements added without a code (hand-naming
    /// hundreds of freedraw strokes would be hostile).
    public var codePrefix: String {
        switch self {
        case .drawingLayer: return "layer"
        case .drawingStroke: return "stroke"
        case .drawingShape: return "shape"
        case .dopeScope: return "scope"
        case .dopeEntity: return "entity"
        }
    }

    /// Default display name for elements added without one.
    public var defaultName: String {
        switch self {
        case .drawingLayer: return "Layer 1"
        case .drawingStroke: return "Stroke"
        case .drawingShape: return "Shape"
        case .dopeScope: return "Dope Scope"
        case .dopeEntity: return "Dope Entity"
        }
    }
}

/// diagram_drawing_shape.shape_kind values.
public enum DiagramShapeKind: String, Codable, Hashable, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case polygon
}

/// diagram_drawing_stroke.tool values.
public enum DiagramStrokeTool: String, Codable, Hashable, CaseIterable, Sendable {
    case pencil
    case marker
    case highlighter
}

/// The element-axis registry: subtype table, vertex table, legal parents,
/// binding-ness — the single truth consumed by store dispatch, containment
/// validation, hydration, and the CLI's help text.
public struct DiagramElementTypeSpec: Sendable {
    public let type: DiagramElementType
    public let subtypeTable: String
    /// Non-nil only for vertex-bearing types (stroke/shape).
    public let vertexTable: String?
    /// The subtype-table FK column the vertex table uses.
    public let vertexParentColumn: String?
    /// nil = a top-level type (parent_element_uuid must be NULL — the schema
    /// CHECK is the backstop); non-nil = the set of legal parent types.
    public let allowedParentTypes: Set<DiagramElementType>?
    /// Whether this type binds into the dope tree by code.
    public let isDopeBinding: Bool

    public static let all: [DiagramElementType: DiagramElementTypeSpec] = {
        let specs: [DiagramElementTypeSpec] = [
            DiagramElementTypeSpec(
                type: .drawingLayer, subtypeTable: "diagram_drawing_layer",
                vertexTable: nil, vertexParentColumn: nil,
                allowedParentTypes: nil, isDopeBinding: false),
            DiagramElementTypeSpec(
                type: .drawingStroke, subtypeTable: "diagram_drawing_stroke",
                vertexTable: "diagram_stroke_vertex",
                vertexParentColumn: "stroke_element_uuid",
                allowedParentTypes: [.drawingLayer], isDopeBinding: false),
            DiagramElementTypeSpec(
                type: .drawingShape, subtypeTable: "diagram_drawing_shape",
                vertexTable: "diagram_shape_vertex",
                vertexParentColumn: "shape_element_uuid",
                allowedParentTypes: [.drawingLayer], isDopeBinding: false),
            DiagramElementTypeSpec(
                type: .dopeScope, subtypeTable: "diagram_dope_scope",
                vertexTable: nil, vertexParentColumn: nil,
                allowedParentTypes: nil, isDopeBinding: true),
            DiagramElementTypeSpec(
                type: .dopeEntity, subtypeTable: "diagram_dope_entity",
                vertexTable: nil, vertexParentColumn: nil,
                allowedParentTypes: [.dopeScope], isDopeBinding: true),
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.type, $0) })
    }()

    public static func spec(for type: DiagramElementType) -> DiagramElementTypeSpec {
        // Total over DiagramElementType by construction.
        all[type]!
    }
}
