import Foundation

// Runtime DTO for $GMCC_PROJECTS/project_index.gmcc.yaml.
// Conforms to gmcc.gmcc_project_index_file (see $GMCC_PLUGIN_ROOT/gmcc.yeet.yaml).

struct GMCCProjectIndexFile: Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let kbite: [String]            // has_kbite_list
    let projects: [GMCCProjectEntry]
}

struct GMCCProjectEntry: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths

    var id: UUID { base.uuid }
    var projectDataURL: URL { paths.absoluteURL.appendingPathComponent("project_data.gmcc.yaml") }

    func matches(query: String) -> Bool { base.matches(query: query) }
}
