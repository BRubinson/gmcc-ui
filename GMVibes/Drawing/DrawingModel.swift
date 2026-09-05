import SwiftUI

// Session-local drawing value types. Field names deliberately mirror the
// proposed m0005 `drawing_element` columns so a later persistence pass is a
// straight column map — but NOTHING here is persisted, versioned, or
// tombstoned, and none of that machinery (fractional indices, version nonces,
// deltas) exists yet on purpose.

enum DrawingTool: String, CaseIterable, Identifiable, Hashable {
    case select, pencil, rectangle

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pencil: "pencil.tip"
        case .rectangle: "rectangle"
        }
    }
    var help: String {
        switch self {
        case .select: "Click to select, drag to move — drag empty space to pan"
        case .pencil: "Draw a freehand stroke"
        case .rectangle: "Drag out a rectangle"
        }
    }
}

/// RGBA as four doubles, not `Color`: honestly Equatable/Hashable, and it maps
/// to the m0005 hex-string column when persistence lands.
struct RGBAColor: Hashable, Codable {
    var r, g, b, a: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Brand orange (the Glass.swift gradient midpoint) — the default ink.
    /// Legible on both light and dark canvas backgrounds, unlike near-black.
    static let brandOrange = RGBAColor(r: 0.9, g: 0.45, b: 0.15, a: 1)
    static let ink = RGBAColor(r: 0.10, g: 0.10, b: 0.12, a: 1)

    /// The stroke palette the tool strip offers.
    static let palette: [RGBAColor] = [
        .brandOrange,
        RGBAColor(r: 0.95, g: 0.26, b: 0.21, a: 1),   // red
        RGBAColor(r: 0.25, g: 0.55, b: 0.95, a: 1),   // blue
        RGBAColor(r: 0.22, g: 0.72, b: 0.38, a: 1),   // green
        RGBAColor(r: 0.65, g: 0.40, b: 0.90, a: 1),   // purple
        RGBAColor(r: 0.55, g: 0.55, b: 0.58, a: 1),   // gray
    ]
}

/// Stored as `{offset, zoom}` (the m0005 shape); USED as a `CGAffineTransform`,
/// so anchored zoom is transform composition instead of hand-rolled algebra.
/// This is the ONLY place screen↔canvas coordinate math lives.
struct Viewport: Equatable {
    /// Screen-space translation of the canvas origin.
    var offset: CGSize = .zero
    var zoom: CGFloat = 1

    static let zoomRange: ClosedRange<CGFloat> = 0.05...20

    /// canvas → screen. Composition order is fixed here, once, forever.
    var toScreen: CGAffineTransform {
        CGAffineTransform(scaleX: zoom, y: zoom)
            .concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
    var toCanvas: CGAffineTransform { toScreen.inverted() }

    func canvasPoint(_ p: CGPoint) -> CGPoint { p.applying(toCanvas) }
    func screenPoint(_ p: CGPoint) -> CGPoint { p.applying(toScreen) }
    func canvasRect(_ r: CGRect) -> CGRect { r.applying(toCanvas) }

    /// Zoom keeping `anchor` (a SCREEN point — pinch centroid or cursor)
    /// pinned to the same canvas point.
    mutating func zoom(to newZoom: CGFloat, anchor: CGPoint) {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard clamped != zoom else { return }
        let before = canvasPoint(anchor)
        zoom = clamped
        let after = canvasPoint(anchor)
        offset.width += (after.x - before.x) * zoom
        offset.height += (after.y - before.y) * zoom
    }
}

enum ElementKind: Equatable {
    /// Points are ELEMENT-LOCAL (relative to `origin`) — a move rewrites
    /// `origin` only, never the point array.
    case freedraw(points: [CGPoint])
    case rectangle
}

struct DrawingElement: Identifiable, Equatable {
    let id: UUID
    var kind: ElementKind
    var origin: CGPoint          // canvas space
    var size: CGSize             // non-negative (rects standardized at commit)
    var strokeColor: RGBAColor = .brandOrange
    var strokeWidth: CGFloat = 4
    var fillColor: RGBAColor?    // nil in v0

    /// Authored bounds — recomputed, never cached (a cached box is a second
    /// source of truth and the first thing to go stale).
    var frame: CGRect { CGRect(origin: origin, size: size) }

    /// World-space path, built per draw.
    func path() -> Path {
        switch kind {
        case .rectangle:
            return Path(frame)
        case .freedraw(let pts):
            guard let first = pts.first else { return Path() }
            var p = Path()
            let start = CGPoint(x: origin.x + first.x, y: origin.y + first.y)
            p.move(to: start)
            // A bare move(to:) strokes NOTHING — a single-click "dot" needs a
            // zero-length segment so the round line cap rasterizes it as a
            // strokeWidth-diameter disc instead of an invisible, hit-testable
            // ghost.
            if pts.count == 1 { p.addLine(to: start) }
            for pt in pts.dropFirst() {
                p.addLine(to: CGPoint(x: origin.x + pt.x, y: origin.y + pt.y))
            }
            return p
        }
    }

    /// `tolerance` arrives in CANVAS units (already divided by zoom by the
    /// caller), so the grab radius is constant in SCREEN points at any zoom.
    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .rectangle:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .freedraw(let pts):
            guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
            let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            if pts.count == 1 { return hypot(local.x - pts[0].x, local.y - pts[0].y) <= tolerance }
            for i in 1..<pts.count
            where Geometry.distance(local, segment: pts[i - 1], pts[i]) <= tolerance {
                return true
            }
            return false
        }
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Commit-time normalization: bbox becomes origin+size, world points become
    /// element-local. A single point commits as a dot; an empty buffer as nil.
    static func normalizeStroke(
        _ world: [CGPoint], strokeColor: RGBAColor, strokeWidth: CGFloat
    ) -> DrawingElement? {
        guard let first = world.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in world.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let origin = CGPoint(x: minX, y: minY)
        return DrawingElement(
            id: UUID(),
            kind: .freedraw(points: world.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }),
            origin: origin,
            size: CGSize(width: maxX - minX, height: maxY - minY),
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
    }
}
