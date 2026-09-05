import SwiftUI
import Observation

/// One drawing. A reference cell on purpose: with @Observable, writing
/// `viewport` invalidates only the views that READ `viewport` — that
/// per-property tracking is the entire mechanism keeping pan/zoom out of the
/// elements' observation scope (the sidebar never redraws because someone
/// pinched). Every gesture writes through the mutators below, so undo and the
/// eventual m0005 daemon writes attach at five functions, not N gesture
/// closures.
@Observable @MainActor
final class Drawing: Identifiable {
    let id = UUID()
    /// Plain `var`: user-typed text with no invariant to guard, so the pane
    /// binds a TextField straight at it via @Bindable.
    var title: String = ""

    private(set) var elements: [DrawingElement] = []
    private(set) var viewport = Viewport()
    private(set) var selection: Set<UUID> = []

    /// Cheap render key for the committed layer's Equatable conformance —
    /// comparing a multi-thousand-point array per body pass would cost more
    /// than the redraw it saves.
    private(set) var revision: Int = 0

    /// Sidebar rows and the search filter match on this so an untitled drawing
    /// can never vanish mid-search.
    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// Deliberately does NOT select the new element: drawing tools draw — the
    /// selection ring appearing on every fresh shape reads as a "selectable
    /// area" instead of ink. The mouse tool selects.
    func commit(_ element: DrawingElement) {
        elements.append(element)
        revision &+= 1
    }

    /// O(1) per element: freedraw points are element-local, so a move is an
    /// origin write, never an N-point rewrite.
    func move(ids: Set<UUID>, by delta: CGSize) {
        guard delta != .zero, !ids.isEmpty else { return }
        for i in elements.indices where ids.contains(elements[i].id) {
            elements[i].origin.x += delta.width
            elements[i].origin.y += delta.height
        }
        revision &+= 1
    }

    func select(_ id: UUID?) {
        let new: Set<UUID> = id.map { [$0] } ?? []
        guard new != selection else { return }
        selection = new
        revision &+= 1          // selection is drawn, so it participates in the key
    }

    /// Shift-click semantics: flip one element's membership, leaving the rest
    /// of the selection alone.
    func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        revision &+= 1
    }

    func pan(by delta: CGSize) {
        guard delta != .zero else { return }
        viewport.offset.width += delta.width
        viewport.offset.height += delta.height
    }

    func setZoom(_ z: CGFloat, anchor: CGPoint) {
        viewport.zoom(to: z, anchor: anchor)
    }

    func resetViewport() {
        guard viewport != Viewport() else { return }
        viewport = Viewport()
    }

    /// Center the union of authored bounds in `size`, clamped to the zoom range.
    func fit(in size: CGSize, padding: CGFloat = 40) {
        guard let first = elements.first else { return resetViewport() }
        let bounds = elements.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard bounds.width > 0 || bounds.height > 0 else { return resetViewport() }
        let sx = (size.width - 2 * padding) / max(bounds.width, 1)
        let sy = (size.height - 2 * padding) / max(bounds.height, 1)
        var v = Viewport()
        v.zoom = min(max(min(sx, sy), Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
        v.offset = CGSize(width: size.width / 2 - bounds.midX * v.zoom,
                          height: size.height / 2 - bounds.midY * v.zoom)
        if v != viewport { viewport = v }
    }

    /// Topmost-first hit test — last drawn wins, matching paint order.
    /// `screenTolerance` is screen points; converted to canvas units here, once.
    func element(at canvasPoint: CGPoint, screenTolerance: CGFloat = 6) -> DrawingElement? {
        let tol = screenTolerance / viewport.zoom
        return elements.last { $0.hitTest(canvasPoint, tolerance: max(tol, $0.strokeWidth / 2)) }
    }
}
