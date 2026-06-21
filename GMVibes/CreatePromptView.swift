import SwiftUI

// Authoring sheet: create a new prompt folder inside an existing session.
// Captures name + backstory/goal/detail + a kbite multi-select (pre-seeded from
// the parent session's kbite list; options scanned from $GMCC_KBITE_DIGESTED).
struct CreatePromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GMCCFileSystemEmulation.self) private var fs
    @Environment(GMCCEnvironment.self) private var gmcc

    // Context supplied by SessionPromptsView.
    let sessionDirURL: URL
    let sessionRelPath: String
    let sessionDataURL: URL
    let promptsDirURL: URL
    let nextID: Int
    let preselectedKbites: [String]
    // Parent session's backstory, inherited into the new prompt at sheet-open
    // (pre-filled, editable — the prompt's backstory may then diverge).
    let sessionBackstory: String

    @State private var name: String = ""
    @State private var backstory: String = ""
    @State private var didSeedBackstory = false
    @State private var goal: String = ""
    @State private var detail: String = ""
    @State private var availableKbites: [String] = []
    @State private var selectedKbites: Set<String> = []
    @State private var isSaving = false
    @State private var errorText: String?

    private var segment: String { Self.previewSegment(name) }
    private var canSave: Bool { !segment.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("Name", text: $name)
                    if !segment.isEmpty {
                        LabeledContent("Folder", value: "prompts/\(nextID)_\(segment)")
                    }
                }
                Section("Backstory") {
                    TextEditor(text: $backstory).frame(minHeight: 60).font(.body)
                }
                Section("Goal") {
                    TextEditor(text: $goal).frame(minHeight: 80).font(.body)
                }
                Section("Detail") {
                    TextEditor(text: $detail).frame(minHeight: 100).font(.body)
                }
                Section("KBites") {
                    if availableKbites.isEmpty {
                        Text("No kbites found in $GMCC_KBITE_DIGESTED.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(availableKbites, id: \.self) { kbite in
                            Toggle(kbite, isOn: Binding(
                                get: { selectedKbites.contains(kbite) },
                                set: { on in
                                    if on { selectedKbites.insert(kbite) } else { selectedKbites.remove(kbite) }
                                }
                            ))
                        }
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .task {
            loadKbites()
            // Inherit the session backstory once; never clobber user edits on re-entry.
            if !didSeedBackstory { backstory = sessionBackstory; didSeedBackstory = true }
        }
    }

    // MARK: - KBite options

    private func loadKbites() {
        let preselected = Set(preselectedKbites)
        var names: [String] = []
        if let digested = gmcc[.kbiteDigested] {
            let dir = URL(fileURLWithPath: digested, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            names = contents.compactMap { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir ? url.lastPathComponent : nil
            }.sorted()
        }
        // Always surface inherited kbites even if the digested dir scan misses them.
        let merged = Set(names).union(preselected)
        availableKbites = merged.sorted()
        selectedKbites = preselected.intersection(merged)
    }

    // Mirror of the encoder's segment rule, for the live folder preview.
    private static func previewSegment(_ name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastWasSep = false
        for ch in lower {
            if ch == "/" { out += "__"; lastWasSep = false }
            else if ch.isLetter || ch.isNumber || ch == "-" { out.append(ch); lastWasSep = false }
            else { if !lastWasSep && !out.isEmpty { out.append("_") }; lastWasSep = true }
        }
        while out.hasSuffix("_") { out.removeLast() }
        while out.hasPrefix("_") { out.removeFirst() }
        return out
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorText = nil
        let dirURL = sessionDirURL
        let relPath = sessionRelPath
        let id = nextID
        let nm = name.trimmingCharacters(in: .whitespaces)
        let bs = backstory, gl = goal, dt = detail
        let kbites = availableKbites.filter { selectedKbites.contains($0) }   // stable order

        let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let url = try GMCCRuntimeEncoder.writePromptFolder(
                    sessionDirURL: dirURL,
                    sessionRelPath: relPath,
                    nextID: id,
                    name: nm,
                    backstory: bs,
                    goal: gl,
                    detail: dt,
                    kbites: kbites
                )
                return .success(url)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            await fs.refreshSessionData(at: sessionDataURL)
            await fs.refreshSessionPrompts(at: promptsDirURL)
            isSaving = false
            dismiss()
        case .failure(let err):
            errorText = err.localizedDescription
            isSaving = false
        }
    }
}
