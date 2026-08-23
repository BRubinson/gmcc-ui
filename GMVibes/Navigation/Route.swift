import Foundation

/// Codable navigation payload for the single window type. `nil`/absence means
/// the landing page. The session screen is a `NavigationSplitView`, which must
/// be a container root — so windows switch routes at the root rather than
/// pushing destinations onto a `NavigationStack`.
enum Route: Codable, Hashable {
    case session(SessionWindowID)
    case instance(instanceUuid: String)
    case projects
    case kbites
    case kbiteFile(URL)
    case promptMemories(PromptMemoriesWindowID)
    case search(SearchSeed)
}

/// Seed for the dedicated SEARCH screen. uuid-only scope (the session name is
/// resolved from CatalogStore at render time, per SessionWindowID's doctrine);
/// `query` carries the ⌘K palette's text across the hand-off so "show all
/// results" doesn't drop the user on an empty page.
struct SearchSeed: Codable, Hashable {
    var sessionUuid: String? = nil
    var query: String = ""
}

/// Window identity. `id` is unique per open, so `WindowGroup(for:)` NEVER
/// dedupes — two windows on one session are legal (SessionScopeCache makes
/// them safe). Decoding always yields a landing seed: restored windows land
/// on the landing page by design.
struct WindowSeed: Codable, Hashable, Identifiable {
    let id: UUID
    let route: Route?

    init(_ route: Route? = nil) {
        self.id = UUID()
        self.route = route
    }

    init(from decoder: Decoder) throws {
        self.init(nil)
    }
}
