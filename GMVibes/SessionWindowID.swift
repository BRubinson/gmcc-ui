import Foundation

/// Identity + payload for a per-session window opened from the landing screen or
/// the Projects window. `Codable` so SwiftUI can restore open session windows
/// across launches. Equality / hash are keyed on `sessionUUID` ALONE, so reopening
/// the same session focuses its existing window instead of spawning a duplicate
/// (WindowGroup(for:) dedupes on the value's identity).
struct SessionWindowID: Codable, Hashable, Identifiable {
    let sessionUUID: UUID
    let instanceUUID: UUID
    let sessionName: String
    let promptsDirURL: URL

    var id: UUID { sessionUUID }

    static func == (lhs: SessionWindowID, rhs: SessionWindowID) -> Bool {
        lhs.sessionUUID == rhs.sessionUUID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sessionUUID)
    }
}
