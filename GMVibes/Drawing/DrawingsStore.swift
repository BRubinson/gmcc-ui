import Foundation
import Observation

/// One session's drawings. Two levels (store → book) so the pane holds a
/// reference to ITS book and a drawing created in session B can never
/// invalidate session A's sidebar — the same reason SessionScopeCache memoizes
/// per-session scopes.
@Observable @MainActor
final class DrawingBook {
    private(set) var drawings: [Drawing] = []

    /// Append-and-return: the sidebar `+` selects the result immediately — no
    /// sheet, because unlike a prompt there is no daemon round trip and nothing
    /// to ask.
    @discardableResult
    func create() -> Drawing {
        let drawing = Drawing()
        drawings.append(drawing)
        return drawing
    }

    func drawing(id: UUID?) -> Drawing? {
        guard let id else { return nil }
        return drawings.first { $0.id == id }
    }
}

/// Window-lifetime drawing state, keyed by session uuid. Held as `@State` on
/// `GMVibesWindow` ABOVE the `.id(nav.route)` boundary and injected with
/// `.environment` beside `WindowNav` — the established per-window seam, NOT the
/// app-lifetime `GMVibesServices` singletons. Consequences, both intended:
/// drawings survive in-window navigation (including the sidebar's "Search
/// Session" round trip) and die with the window.
///
/// Deliberately NOT `SessionScopeCache`: its grace list (cap 4) revives retired
/// scopes, which would resurrect a closed window's drawings and contradict the
/// clear-on-close contract. SessionScope becomes the right home only when the
/// daemon, not a cache lifetime, decides what survives.
@Observable @MainActor
final class DrawingsStore {
    /// @ObservationIgnored is what makes create-or-get from a view body legal:
    /// with a TRACKED dictionary the first render's read registers a dependency
    /// and the write then fires the registrar inside the same tracking scope —
    /// mutate-during-view-update. (SessionScopeCache gets this for free by not
    /// being @Observable at all; this class must stay @Observable for
    /// `.environment` resolution, so the registry opts out per-property.)
    /// Nothing should ever observe `books` — each DrawingBook is the real
    /// observable unit.
    @ObservationIgnored private var books: [String: DrawingBook] = [:]

    /// Create-or-get, side-effect-safe from a view body.
    func book(for sessionUuid: String) -> DrawingBook {
        if let existing = books[sessionUuid] { return existing }
        let fresh = DrawingBook()
        books[sessionUuid] = fresh
        return fresh
    }
}
