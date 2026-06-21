import Foundation

// Runtime DTO for {project}/project_data.gmcc.yaml.
// Conforms to gmcc.gmcc_project_data_file.

struct GMCCProjectDataFile: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let kbite: [String]            // has_kbite_list
    let repositoryName: String?
    let httpURI: String?
    let sshURI: String?
    let instances: [GMCCInstanceEntry]

    var id: UUID { base.uuid }
}

struct GMCCInstanceEntry: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let systemPath: String?

    var id: UUID { base.uuid }
    var instanceDataURL: URL { paths.absoluteURL.appendingPathComponent("instance_data.gmcc.yaml") }

    func matches(query: String) -> Bool { base.matches(query: query) }
}
