import Foundation

// Identity + hand-off payload for a popped-out Memories explorer window. `Codable`
// so SwiftUI can restore open popouts across launches. Equality / hash are keyed on
// `memoryRootURL` ALONE, so CMD-clicking the same prompt's Memories tab focuses the
// existing popout instead of spawning a duplicate (the SessionWindowID precedent).
// `selectedFile` + `expanded` carry the inline tab's state into the new window.
struct PromptMemoriesWindowID: Codable, Hashable, Identifiable {
    let memoryRootURL: URL
    let promptName: String
    let selectedFile: URL?
    let expanded: [URL]

    var id: URL { memoryRootURL }

    static func == (lhs: PromptMemoriesWindowID, rhs: PromptMemoriesWindowID) -> Bool {
        lhs.memoryRootURL == rhs.memoryRootURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(memoryRootURL)
    }
}
