import Foundation

// Hand-off payload for the Memories explorer route (`Route.promptMemories`).
// Plain value semantics — the old memoryRootURL-only equality existed for
// WindowGroup dedupe, which is gone with the one-window-type collapse.
// `selectedFile` + `expanded` carry the inline tab's state across.
struct PromptMemoriesWindowID: Codable, Hashable, Identifiable {
    let memoryRootURL: URL
    let promptName: String
    let selectedFile: URL?
    let expanded: [URL]

    var id: URL { memoryRootURL }
}
