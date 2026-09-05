import SwiftUI

/// The drawing surface: two Canvas layers plus the gesture set.
///
/// Split rendering, not one Canvas: an in-progress pencil stroke re-creates the
/// enclosing body on every drag sample, and with a single Canvas that would
/// re-rasterize every committed element per sample. `CommittedCanvas` compares
/// equal during a stroke (nothing committed changed) and is skipped;
/// `DraftCanvas` alone redraws. The `Color.clear` layer above both is the seam
/// where ewwies mounts real SwiftUI node views later — empty in v0 by decision
/// (no v0 element needs focus, text input, or accessibility), not by omission.
struct DrawingCanvasView: View {
    let drawing: Drawing
    let tool: DrawingTool
    let strokeColor: RGBAColor
    let strokeWidth: CGFloat

    /// In-progress gesture state. @State, NOT @GestureState: @GestureState is
    /// reset BEFORE `onEnded` runs, so an accumulating stroke would arrive
    /// empty at commit time. Cleared in `onEnded` AND on new-gesture detection
    /// in `onChanged` — SwiftUI skips `onEnded` for CANCELLED drags (a sheet
    /// appears, the window resigns key), so the next drag must not inherit the
    /// last one's intent.
    @State private var strokePoints: [CGPoint] = []      // CANVAS space
    @State private var rectDraft: CGRect?                // CANVAS space
    @State private var moveDraft: MoveDraft?
    /// Decided ONCE at gesture start. Re-deciding per frame would let an
    /// element slide out from under the cursor and flip a move into a pan
    /// mid-drag.
    @State private var dragIntent: DragIntent?
    /// The screen startLocation of the drag currently being tracked — a fresh
    /// value here means a NEW gesture, whatever happened to the last one.
    @State private var dragStartLocation: CGPoint?
    @State private var zoomBase: CGFloat?
    @State private var lastPan: CGSize = .zero
    @State private var sink = CanvasScrollBridge.Sink()

    /// Anchors are CANVAS-space snapshots taken at gesture start: simultaneous
    /// pinch/scroll can move the viewport mid-drag, and re-deriving a screen
    /// anchor through the CURRENT viewport would slide the geometry across the
    /// paper (the pencil path converts at capture for the same reason).
    private enum DragIntent {
        case pan
        /// `pendingRemove`: a shift-press on an ALREADY-selected element. The
        /// meaning is decided at release — a click (no real movement) toggles
        /// it out of the selection; a drag moves the whole group. Toggling on
        /// mouse-down would dissolve the group the instant the user starts a
        /// shift-drag, which is how they got the group one gesture ago.
        case move(ids: Set<UUID>, grabPoint: CGPoint, pendingRemove: UUID?)
        case stroke
        case rect(anchor: CGPoint)
    }
    private struct MoveDraft { var ids: Set<UUID>; var delta: CGSize }

    var body: some View {
        // Reading revision/viewport HERE is deliberate: it declares this body's
        // observation dependency on element commits and viewport writes (the
        // Canvas renderer closure and an Equatable's == are NOT tracked
        // scopes), and it captures the value snapshots CommittedCanvas's
        // equality needs — comparing live properties of one shared class
        // reference would be vacuously true forever.
        let revision = drawing.revision
        let viewport = drawing.viewport

        ZStack {
            CommittedCanvas(
                drawing: drawing,
                revision: revision,
                viewport: viewport,
                hiddenElementIDs: moveDraft?.ids ?? []
            )
            .equatable()
            DraftCanvas(
                viewport: viewport,
                strokePoints: strokePoints,
                rectDraft: rectDraft,
                movingElements: moveDraft.map { draft in
                    drawing.elements.filter { draft.ids.contains($0.id) }
                } ?? [],
                moveDelta: moveDraft?.delta ?? .zero,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth
            )
            // Hybrid seam: interactive per-element views (ewwies nodes) land
            // here, already inside the transform/z-order the canvases agree on.
            Color.clear.allowsHitTesting(false)
        }
        // Load-bearing: a Canvas with no drawn content is not hit-testable, so
        // drags on blank space would otherwise do nothing at all.
        .contentShape(Rectangle())
        .background { CanvasScrollBridge(sink: sink) }
        .gesture(toolGesture)
        // simultaneous, not `.gesture`: a pan in flight must never block a pinch.
        .simultaneousGesture(magnify)
        .onAppear {
            sink.onPan = { drawing.pan(by: CGSize(width: $0.width, height: $0.height)) }
            sink.onZoom = { factor, anchor in
                drawing.setZoom(drawing.viewport.zoom * factor, anchor: anchor)
            }
        }
    }

    // MARK: - Gestures

    private var toolGesture: some Gesture {
        // minimumDistance MUST be 0: the default (10) silently kills
        // click-to-select and single-dot pencil strokes.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A different startLocation means a NEW drag: reset whatever a
                // cancelled predecessor left behind (its onEnded never ran).
                if dragStartLocation != value.startLocation {
                    resetDrafts()
                    dragStartLocation = value.startLocation
                }
                // Convert AT CAPTURE, not at commit: a trackpad pan mid-stroke
                // changes the viewport; canvas-space points stay welded to the
                // paper, screen points would smear the stroke sideways.
                let p = drawing.viewport.canvasPoint(value.location)
                let intent = dragIntent ?? begin(at: p)
                switch intent {
                case .stroke:
                    strokePoints.append(p)
                case .rect(let anchor):
                    rectDraft = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                       width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
                case .move(let ids, let grabPoint, _):
                    // Delta between two canvas-space cursor positions — welded
                    // to the paper at any zoom, immune to mid-drag viewport
                    // changes. Rendered in the draft layer; committed ONCE on
                    // gesture end so the committed layer stays equal (and the
                    // mutation funnel stays a real undo boundary).
                    moveDraft = MoveDraft(ids: ids, delta: CGSize(width: p.x - grabPoint.x,
                                                                  height: p.y - grabPoint.y))
                case .pan:
                    drawing.pan(by: CGSize(width: value.translation.width - lastPan.width,
                                           height: value.translation.height - lastPan.height))
                    lastPan = value.translation
                }
            }
            .onEnded { _ in
                switch dragIntent {
                case .stroke:
                    if let element = Geometry.normalizeStroke(
                        strokePoints, strokeColor: strokeColor, strokeWidth: strokeWidth
                    ) {
                        drawing.commit(element)
                    }
                case .rect:
                    // Degenerate rects are discarded, not committed as
                    // invisible elements that could still be hit-tested.
                    if let r = rectDraft, r.width >= 1, r.height >= 1 {
                        drawing.commit(DrawingElement(id: UUID(), kind: .rectangle,
                                                      origin: r.origin, size: r.size,
                                                      strokeColor: strokeColor,
                                                      strokeWidth: strokeWidth))
                    }
                case .move(_, _, let pendingRemove):
                    // A "click" is a drag whose total movement stayed inside a
                    // few SCREEN points at the current zoom.
                    let delta = moveDraft?.delta ?? .zero
                    let screenDistance = hypot(delta.width, delta.height) * drawing.viewport.zoom
                    if screenDistance < 3, let pendingRemove {
                        drawing.toggle(pendingRemove)     // shift-click: separate it
                    } else if let draft = moveDraft {
                        drawing.move(ids: draft.ids, by: draft.delta)
                    }
                case .pan, nil:
                    break
                }
                resetDrafts()
            }
    }

    private func resetDrafts() {
        strokePoints = []
        rectDraft = nil
        moveDraft = nil
        dragIntent = nil
        lastPan = .zero
    }

    private func begin(at p: CGPoint) -> DragIntent {
        let intent: DragIntent
        switch tool {
        case .pencil:
            intent = .stroke
        case .rectangle:
            intent = .rect(anchor: p)
        case .select:
            // DragGesture carries no modifier info; polling AppKit's current
            // flags at intent-decision time is the house-blessed drop-down.
            let shift = NSEvent.modifierFlags.contains(.shift)
            if let hit = drawing.element(at: p) {
                if shift, drawing.selection.contains(hit.id) {
                    // Deferred: click removes it, drag moves the whole group.
                    intent = .move(ids: drawing.selection, grabPoint: p,
                                   pendingRemove: hit.id)
                } else if shift {
                    // Shift on a NEW element adds it immediately, and the same
                    // gesture can already drag the enlarged group.
                    drawing.toggle(hit.id)
                    intent = .move(ids: drawing.selection, grabPoint: p,
                                   pendingRemove: nil)
                } else if drawing.selection.contains(hit.id) {
                    // Dragging an already-selected element moves the WHOLE
                    // selection, preserving it.
                    intent = .move(ids: drawing.selection, grabPoint: p,
                                   pendingRemove: nil)
                } else {
                    drawing.select(hit.id)
                    intent = .move(ids: [hit.id], grabPoint: p, pendingRemove: nil)
                }
            } else {
                // Shift-click on empty space keeps the selection (the user is
                // building one); a plain click clears it.
                if !shift { drawing.select(nil) }
                intent = .pan
            }
        }
        dragIntent = intent
        return intent
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // value.magnification is CUMULATIVE from gesture start:
                // multiply the gesture-start baseline, never compound per
                // change (a clamped compounded value sticks at the bound and
                // never comes back when the pinch reverses). The anchor is the
                // gesture's own startLocation — no cursor mirror needed.
                let base: CGFloat
                if let zoomBase {
                    base = zoomBase
                } else {
                    base = drawing.viewport.zoom
                    zoomBase = base
                }
                drawing.setZoom(base * value.magnification, anchor: value.startLocation)
            }
            .onEnded { _ in zoomBase = nil }
    }
}

// MARK: - Layers

/// Committed elements + selection ring. Equatable over VALUE snapshots captured
/// at construction (`revision`, `viewport`, `hiddenElementID`) — never over
/// live reads of the shared `Drawing` reference, which would compare one
/// object's fields to themselves and gate the layer shut forever.
private struct CommittedCanvas: View, Equatable {
    let drawing: Drawing
    let revision: Int
    let viewport: Viewport
    /// The elements mid-move, rendered by the draft layer instead. Stable for
    /// the whole drag, so equality holds while the delta changes.
    let hiddenElementIDs: Set<UUID>

    static func == (a: Self, b: Self) -> Bool {
        a.drawing === b.drawing
            && a.revision == b.revision
            && a.viewport == b.viewport
            && a.hiddenElementIDs == b.hiddenElementIDs
    }

    var body: some View {
        Canvas(opaque: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(nsColor: .textBackgroundColor)))

            // GraphicsContext is a VALUE type: the copy carries the world
            // transform while `context` stays in SCREEN space — that is how the
            // selection ring keeps a constant weight at every zoom with no
            // 1/zoom fudge factors.
            var world = context
            world.concatenate(viewport.toScreen)

            // Culling is what makes "infinite" true: a pan 50,000 units away
            // must not walk and rasterize every path in the drawing.
            let visible = viewport
                .canvasRect(CGRect(origin: .zero, size: size))
                .insetBy(dx: -64, dy: -64)

            for element in drawing.elements {
                if hiddenElementIDs.contains(element.id) { continue }
                // Inflate before the intersection test: CGRect.intersects is
                // false for EMPTY rects, and dots / axis-aligned strokes have a
                // zero-area frame — they'd commit and hit-test but never draw.
                let inflated = element.frame.insetBy(
                    dx: -max(element.strokeWidth, 0.5),
                    dy: -max(element.strokeWidth, 0.5)
                )
                guard inflated.intersects(visible) else { continue }

                if let fill = element.fillColor {
                    world.fill(element.path(), with: .color(fill.color))
                }
                world.stroke(element.path(),
                             with: .color(element.strokeColor.color),
                             style: StrokeStyle(lineWidth: element.strokeWidth,
                                                lineCap: .round, lineJoin: .round))
                if drawing.selection.contains(element.id) {
                    // Screen-space pass from the untransformed context.
                    let onScreen = element.frame.applying(viewport.toScreen)
                    context.stroke(
                        Path(roundedRect: onScreen.insetBy(dx: -4, dy: -4), cornerRadius: 4),
                        with: .color(.accentColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                }
            }
        }
    }
}

/// The in-progress stroke/rect preview plus the element mid-move. Reads ONLY
/// draft values and the viewport, so a 400-point stroke redraws 400 times
/// without the committed layer re-running once. Deliberately not Equatable.
private struct DraftCanvas: View {
    let viewport: Viewport
    let strokePoints: [CGPoint]
    let rectDraft: CGRect?
    let movingElements: [DrawingElement]
    let moveDelta: CGSize
    let strokeColor: RGBAColor
    let strokeWidth: CGFloat

    var body: some View {
        Canvas(opaque: false) { context, _ in
            var world = context
            world.concatenate(viewport.toScreen)
            let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)

            if let first = strokePoints.first {
                var path = Path()
                path.move(to: first)
                // A zero-length segment under the round cap previews the dot a
                // single-click stroke will commit.
                if strokePoints.count == 1 { path.addLine(to: first) }
                for p in strokePoints.dropFirst() { path.addLine(to: p) }
                world.stroke(path, with: .color(strokeColor.color), style: style)
            }
            if let rect = rectDraft {
                world.stroke(Path(rect), with: .color(strokeColor.color), style: style)
            }
            if !movingElements.isEmpty {
                var ghost = world
                ghost.translateBy(x: moveDelta.width, y: moveDelta.height)
                for element in movingElements {
                    if let fill = element.fillColor {
                        ghost.fill(element.path(), with: .color(fill.color))
                    }
                    ghost.stroke(element.path(),
                                 with: .color(element.strokeColor.color),
                                 style: StrokeStyle(lineWidth: element.strokeWidth,
                                                    lineCap: .round, lineJoin: .round))
                    // Keep the selection visible mid-drag — rings vanishing
                    // while the group moves reads as "the selection is gone".
                    let moved = element.frame
                        .offsetBy(dx: moveDelta.width, dy: moveDelta.height)
                        .applying(viewport.toScreen)
                    context.stroke(
                        Path(roundedRect: moved.insetBy(dx: -4, dy: -4), cornerRadius: 4),
                        with: .color(.accentColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
