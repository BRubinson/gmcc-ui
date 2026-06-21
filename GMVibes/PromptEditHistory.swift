import Foundation
import SwiftData
import Observation

// SwiftData-backed undo/redo history for the prompt editor. One linear stack of
// full (backstory/goal/detail) snapshots PER PROMPT, capped at `cap`, persisted
// across launches. A snapshot is recorded on each autosave commit; undo/redo walk
// the stack with an in-memory cursor and re-apply the stored state.

@Model
final class PromptEditSnapshot {
    // "<sessionUUID>/<promptID>" — scopes a stack to one prompt.
    var promptKey: String
    // Monotonic per-prompt ordering. Newer = larger.
    var seq: Int
    var backstory: String
    var goal: String
    var detail: String
    var createdAt: Date

    init(promptKey: String, seq: Int, backstory: String, goal: String, detail: String, createdAt: Date) {
        self.promptKey = promptKey
        self.seq = seq
        self.backstory = backstory
        self.goal = goal
        self.detail = detail
        self.createdAt = createdAt
    }
}

/// Shared, app-wide SwiftData container for the edit history. One store across all
/// session windows. Falls back to in-memory if the on-disk store can't be opened,
/// so a corrupt/locked store never blocks the app from launching.
enum PromptHistoryStore {
    static let container: ModelContainer = {
        let schema = Schema([PromptEditSnapshot.self])
        let onDisk = ModelConfiguration("PromptEditHistory", schema: schema, isStoredInMemoryOnly: false)
        if let c = try? ModelContainer(for: schema, configurations: onDisk) { return c }
        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // If even an in-memory container fails the SwiftData install is broken; crashing
        // here surfaces that immediately rather than limping on with no history.
        return try! ModelContainer(for: schema, configurations: inMemory)
    }()
}

/// View-local controller wrapping a ModelContext over the shared container.
/// Holds the loaded snapshot list + an in-memory cursor; mutating ops persist
/// immediately. Not thread-safe by design — confined to the main actor.
@Observable
@MainActor
final class PromptEditHistory {
    struct EditState: Equatable {
        var backstory: String
        var goal: String
        var detail: String
    }

    static let cap = 100

    private let context: ModelContext
    private(set) var promptKey: String = ""
    private var snapshots: [PromptEditSnapshot] = []   // seq-ascending
    private var cursor: Int = -1                        // index into `snapshots`

    init(container: ModelContainer = PromptHistoryStore.container) {
        context = ModelContext(container)
    }

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor >= 0 && cursor < snapshots.count - 1 }

    /// Point the controller at a prompt. Loads its persisted stack; if none exists,
    /// seeds snapshot 0 from the on-disk state so the very first edit is undoable.
    func load(promptKey: String, current: EditState) {
        self.promptKey = promptKey
        fetch()
        if snapshots.isEmpty { appendSnapshot(current) }
        cursor = snapshots.count - 1
    }

    /// Record a new state if it differs from the cursor's. Truncates any redo
    /// branch (states after the cursor) before appending, then trims to `cap`.
    func record(_ s: EditState) {
        guard !promptKey.isEmpty else { return }
        if snapshots.isEmpty { appendSnapshot(s); cursor = snapshots.count - 1; return }
        if state(at: cursor) == s { return }
        if cursor < snapshots.count - 1 {
            for stale in snapshots[(cursor + 1)...] { context.delete(stale) }
            snapshots.removeSubrange((cursor + 1)...)
        }
        appendSnapshot(s)
        cursor = snapshots.count - 1
        try? context.save()
    }

    func undo() -> EditState? {
        guard canUndo else { return nil }
        cursor -= 1
        return state(at: cursor)
    }

    func redo() -> EditState? {
        guard canRedo else { return nil }
        cursor += 1
        return state(at: cursor)
    }

    // MARK: - Private

    private func fetch() {
        let key = promptKey
        var descriptor = FetchDescriptor<PromptEditSnapshot>(
            predicate: #Predicate { $0.promptKey == key },
            sortBy: [SortDescriptor(\.seq, order: .forward)]
        )
        descriptor.fetchLimit = nil
        snapshots = (try? context.fetch(descriptor)) ?? []
    }

    private func appendSnapshot(_ s: EditState) {
        let seq = (snapshots.last?.seq ?? -1) + 1
        let snap = PromptEditSnapshot(promptKey: promptKey, seq: seq,
                                      backstory: s.backstory, goal: s.goal, detail: s.detail,
                                      createdAt: Date())
        context.insert(snap)
        snapshots.append(snap)
        trim()
        try? context.save()
    }

    private func trim() {
        while snapshots.count > Self.cap {
            let oldest = snapshots.removeFirst()
            context.delete(oldest)
            if cursor >= 0 { cursor -= 1 }
        }
    }

    private func state(at i: Int) -> EditState {
        let s = snapshots[i]
        return EditState(backstory: s.backstory, goal: s.goal, detail: s.detail)
    }
}
