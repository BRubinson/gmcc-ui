import Foundation

// Runtime DTO for {instance}/instance_data.gmcc.yaml.
// Conforms to gmcc.gmcc_instance_data_file.

struct GMCCInstanceDataFile: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let kbite: [String]            // has_kbite_list
    let systemPath: String?
    let projectUUID: UUID?
    let sessions: [GMCCSessionEntry]

    var id: UUID { base.uuid }
}

struct GMCCSessionEntry: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let branch: String?

    var id: UUID { base.uuid }
    var sessionDataURL: URL { paths.absoluteURL.appendingPathComponent("session_data.gmcc.yaml") }
    var promptsDirectoryURL: URL { paths.absoluteURL.appendingPathComponent("prompts", isDirectory: true) }

    func matches(query: String) -> Bool { base.matches(query: query) }
}
