import Foundation

/// The `.doped.json` document types — the SAME `*Body` structs as the wire
/// tree, minus `DopeNodeIdentity`. Uuid-freedom is by construction: these
/// types have nowhere to put one.
///
/// Layout on disk, under `{instance_root}/.gmcc/dope/`:
///
///     main.doped.json              DopeMainDocument
///     drawing_config.doped.json    {} (future; written only when absent)
///     domains/{code}.doped.json    DopeDomainFileDocument
///
/// `version` appears in main AND in every domain file and must match
/// everywhere — a mismatch means a hand-edit and read-repo reports it.
/// It IS `dope_scope.revision`.

public struct DopeMainDocument: Codable, Hashable, Sendable {
    public let version: Int64
    public let scopeType: String
    public let scope: DopeScopeBody
    /// domain_code → repo-relative file path ("domains/{code}.doped.json").
    /// Read as DATA, never followed: the reader re-derives each value from
    /// its key and refuses a mismatched, absolute, or `..`-bearing entry.
    public let domains: [String: String]

    public init(version: Int64, scopeType: String, scope: DopeScopeBody, domains: [String: String]) {
        self.version = version
        self.scopeType = scopeType
        self.scope = scope
        self.domains = domains
    }

    public static func expectedFile(forDomainCode code: String) -> String {
        "domains/\(code).doped.json"
    }
}

public struct DopeOptionDocument: Codable, Hashable, Sendable {
    public let body: DopeOptionBody

    public init(body: DopeOptionBody) { self.body = body }
    public init(from decoder: Decoder) throws { body = try DopeOptionBody(from: decoder) }
    public func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
}

public struct DopeEnumDocument: Codable, Hashable, Sendable {
    public let body: DopeEnumBody
    public let options: [DopeOptionDocument]

    private enum CodingKeys: String, CodingKey { case options }

    public init(body: DopeEnumBody, options: [DopeOptionDocument]) {
        self.body = body
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        body = try DopeEnumBody(from: decoder)
        options = try decoder.container(keyedBy: CodingKeys.self)
            .decode([DopeOptionDocument].self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(options, forKey: .options)
    }
}

public struct DopePropertyDocument: Codable, Hashable, Sendable {
    public let body: DopePropertyBody

    public init(body: DopePropertyBody) { self.body = body }
    public init(from decoder: Decoder) throws { body = try DopePropertyBody(from: decoder) }
    public func encode(to encoder: Encoder) throws { try body.encode(to: encoder) }
}

public struct DopeEntityDocument: Codable, Hashable, Sendable {
    public let body: DopeEntityBody
    public let properties: [DopePropertyDocument]

    private enum CodingKeys: String, CodingKey { case properties }

    public init(body: DopeEntityBody, properties: [DopePropertyDocument]) {
        self.body = body
        self.properties = properties
    }

    public init(from decoder: Decoder) throws {
        body = try DopeEntityBody(from: decoder)
        properties = try decoder.container(keyedBy: CodingKeys.self)
            .decode([DopePropertyDocument].self, forKey: .properties)
    }

    public func encode(to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(properties, forKey: .properties)
    }
}

/// One `domains/{code}.doped.json` file: the domain at top level per the
/// spec, plus the tree-wide version stamp.
public struct DopeDomainFileDocument: Codable, Hashable, Sendable {
    public let version: Int64
    public let body: DopeDomainBody
    public let entities: [DopeEntityDocument]
    public let enums: [DopeEnumDocument]

    private enum CodingKeys: String, CodingKey { case version, entities, enums }

    public init(
        version: Int64, body: DopeDomainBody,
        entities: [DopeEntityDocument], enums: [DopeEnumDocument]
    ) {
        self.version = version
        self.body = body
        self.entities = entities
        self.enums = enums
    }

    public init(from decoder: Decoder) throws {
        body = try DopeDomainBody(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int64.self, forKey: .version)
        entities = try c.decode([DopeEntityDocument].self, forKey: .entities)
        enums = try c.decode([DopeEnumDocument].self, forKey: .enums)
    }

    public func encode(to encoder: Encoder) throws {
        try body.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entities, forKey: .entities)
        try c.encode(enums, forKey: .enums)
    }
}

/// The complete parsed on-disk representation of one scope.
public struct DopeDocumentBundle: Codable, Hashable, Sendable {
    public let main: DopeMainDocument
    public let domainFiles: [DopeDomainFileDocument]

    public init(main: DopeMainDocument, domainFiles: [DopeDomainFileDocument]) {
        self.main = main
        self.domainFiles = domainFiles
    }
}

/// The single coder pair for `.doped.json` files. Deliberately separate from
/// WireCodec — the file format and the socket format must be free to diverge.
/// `.sortedKeys` + `.prettyPrinted` make the writer byte-deterministic, so an
/// unchanged tree re-written by write-repo leaves `git status` clean.
public enum DopeDocumentCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public static let mainFileName = "main.doped.json"
    public static let drawingConfigFileName = "drawing_config.doped.json"
    public static let domainsDirectoryName = "domains"
    public static let domainFileSuffix = ".doped.json"
}
