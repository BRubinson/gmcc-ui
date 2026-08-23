import Foundation
import Observation

/// The ONLY per-window navigation state: current route, a shallow back stack,
/// and the global-rail / command-palette flags. Created as `@State` at the
/// window root (`GMVibesWindow`) and injected down with `.environment(_:)` —
/// NEVER stored in the process-wide `GMVibesServices` (the LandingWindows
/// per-window-store trap, generalized).
@Observable
@MainActor
final class WindowNav {
    /// `nil` = landing page.
    private(set) var route: Route?
    private var back: [Route?] = []

    /// Global navigation rail; collapsed by default and after a click.
    var railOpen = false
    /// cmd+K action popup.
    var paletteOpen = false
    /// One-shot prompt deep-link, set by `openSession` and consumed (cleared)
    /// by the session screen. Lives OUTSIDE Route identity so a repeat
    /// deep-link into the already-open session — where `go`'s equality guard
    /// short-circuits and the screen is never recreated — still reaches the
    /// live screen's selection.
    var pendingPromptTarget: UUID?

    init(initial: Route? = nil) {
        self.route = initial
    }

    var canGoBack: Bool { !back.isEmpty }

    /// Session navigation with deep-link delivery: the target rides both the
    /// route payload (fresh screens seed from it in init) and the one-shot
    /// pending channel (already-open screens retarget via onChange).
    func openSession(_ windowID: SessionWindowID) {
        pendingPromptTarget = windowID.targetPromptUUID
        go(.session(windowID))
    }

    func go(_ newRoute: Route) {
        guard newRoute != route else { railOpen = false; return }
        back.append(route)
        route = newRoute
        railOpen = false
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        route = previous
    }

    func home() {
        // Landing is the root: going home clears the trail rather than
        // growing a stack nothing will ever unwind.
        back.removeAll()
        route = nil
        railOpen = false
    }
}
