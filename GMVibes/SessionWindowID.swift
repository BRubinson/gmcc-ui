import Foundation

/// Identity + payload for a per-session window opened from the landing screen or
/// the Projects window. `Codable` so SwiftUI can restore open session windows
/// across launches. Equality / hash are keyed on `sessionUUID` ALONE, so reopening
/// the same session focuses its existing window instead of spawning a duplicate
/// (WindowGroup(for:) dedupes on the value's identity).
///
/// uuid-only payload: all filesystem locations are derived at render time from
/// daemon rows via CkfsPathResolver. (Dropping the old `promptsDirURL` field is
/// decode-compatible — synthesized Codable ignores unknown keys in persisted
/// window-restoration state.)
struct SessionWindowID: Codable, Hashable, Identifiable {
    let sessionUUID: UUID
    let instanceUUID: UUID
    let sessionName: String

    var id: UUID { sessionUUID }

    static func == (lhs: SessionWindowID, rhs: SessionWindowID) -> Bool {
        lhs.sessionUUID == rhs.sessionUUID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sessionUUID)
    }
}
