import SwiftUI

// Authoring sheet: stamp a new session (= git branch) inside an existing
// instance. Content authoring only — GMCCRuntimeEncoder owns the byte format and
// detect_repo.sh owns identity/path resolution on the next boot.
struct CreateSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GMCCFileSystemEmulation.self) private var fs

    // Identity + path context, supplied by InstanceDetailView from its decoded
    // GMCCInstanceDataFile.
    let instanceDirURL: URL
    let instanceRelPath: String
    let instanceDataURL: URL
    let instanceUUID: UUID
    let projectUUID: UUID
    let parentKbite: [String]

    @State private var branch: String = ""
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var isSaving = false
    @State private var errorText: String?

    private var slug: String { branch.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "__") }
    private var canSave: Bool { !slug.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Branch") {
                    TextField("git branch (e.g. feature/foo)", text: $branch)
                    if !slug.isEmpty {
                        LabeledContent("Folder", value: "sessions/\(slug)")
                    }
                }
                Section("Display") {
                    TextField("Name (defaults to branch)", text: $name)
                    TextField("Description", text: $description)
                }
                if !parentKbite.isEmpty {
                    Section("Inherited kbites") {
                        Text(parentKbite.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    private func save() async {
        isSaving = true
        errorText = nil
        let dirURL = instanceDirURL
        let relPath = instanceRelPath
        let proj = projectUUID
        let inst = instanceUUID
        let br = branch.trimmingCharacters(in: .whitespaces)
        let nm = name.trimmingCharacters(in: .whitespaces)
        let desc = description
        let kbite = parentKbite

        let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let url = try GMCCRuntimeEncoder.writeSession(
                    instanceDirURL: dirURL,
                    instanceRelPath: relPath,
                    projectUUID: proj,
                    instanceUUID: inst,
                    branch: br,
                    name: nm,
                    description: desc,
                    parentKbite: kbite
                )
                return .success(url)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            await fs.refreshInstanceData(uuid: inst, at: instanceDataURL)
            isSaving = false
            dismiss()
        case .failure(let err):
            errorText = err.localizedDescription
            isSaving = false
        }
    }
}
