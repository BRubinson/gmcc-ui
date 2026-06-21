import Foundation

struct YeetDocument: Equatable {
    var header: YeetHeader
    var sections: [YeetSection]
    var sourceText: String
}

struct YeetHeader: Equatable {
    var name: String?
    var uuid: String?
    var package: String?
    var yeetVersion: String?
    var imports: [String] = []
    var description: String?
}

struct YeetSection: Identifiable, Equatable {
    var name: String
    var description: String?
    var structs: [YeetStructDecl] = []
    var enums: [YeetEnumDecl] = []

    var id: String { name }
}

struct YeetStructDecl: Identifiable, Equatable {
    var name: String
    var description: String?
    var fields: [YeetField] = []

    var id: String { name }
}

struct YeetEnumDecl: Identifiable, Equatable {
    var name: String
    var description: String?
    var cases: [String] = []

    var id: String { name }
}

struct YeetField: Identifiable, Equatable {
    var name: String
    var rawType: String
    var isUnwrap: Bool
    var unwrappedType: String?

    var id: String { name }
}

// MARK: - Search predicates

extension YeetField {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if rawType.localizedStandardContains(query) { return true }
        if let unwrapped = unwrappedType, unwrapped.localizedStandardContains(query) { return true }
        return false
    }
}

extension YeetStructDecl {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if let d = description, d.localizedStandardContains(query) { return true }
        return false
    }

    func anyMatch(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return matches(query: query) || fields.contains { $0.matches(query: query) }
    }
}

extension YeetEnumDecl {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if let d = description, d.localizedStandardContains(query) { return true }
        return false
    }

    func anyMatch(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return matches(query: query) || cases.contains { $0.localizedStandardContains(query) }
    }
}

extension YeetSection {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if let d = description, d.localizedStandardContains(query) { return true }
        return false
    }

    func anyMatch(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return matches(query: query)
            || structs.contains { $0.anyMatch(query: query) }
            || enums.contains { $0.anyMatch(query: query) }
    }
}

extension YeetHeader {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let strings: [String?] = [name, package, yeetVersion, uuid, description]
        if strings.compactMap({ $0 }).contains(where: { $0.localizedStandardContains(query) }) {
            return true
        }
        if imports.contains(where: { $0.localizedStandardContains(query) }) { return true }
        return false
    }
}

enum YeetParseError: LocalizedError, Equatable {
    case readFailed(String)
    case invalidShape(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):
            return "Could not read file: \(msg)"
        case .invalidShape(let line, let reason):
            return "Invalid yeet.yaml at line \(line): \(reason)"
        }
    }
}
