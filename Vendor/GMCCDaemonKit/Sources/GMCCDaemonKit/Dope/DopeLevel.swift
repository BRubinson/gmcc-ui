import Foundation

/// The six DOPED tree levels. `enumeration`'s raw-value rename is wire-safe:
/// the CodingKeys hazard documented in Envelope.swift applies to property
/// keys under the snake_case strategies, not to enum raw values.
public enum DopeLevel: String, Codable, Hashable, CaseIterable, Sendable {
    case scope
    case domain
    case entity
    case property
    case enumeration = "enum"
    case option
}

/// Field identifiers a granular node mutation may carry. Which subset is
/// legal at which level is the registry's `ownedFields` — stated once, so a
/// misdirected field is a precise BAD_REQUEST instead of a silent no-op.
public enum DopeField: String, Codable, Hashable, CaseIterable, Sendable {
    case code, name, description, sortOrder
    case entityType, repoRepresentativeFile, baseComposableUuid
    case dataType, nullable, isUnique, autoIncrement, textCharLimit
    case enumUuid, relatedPropertyUuid, baseOriginPropertyUuid
}

/// One level's registration: table name, parent linkage, legal field set.
/// The registry is the single truth consumed by the generic store mutations,
/// the tree fetch, the projection, and the validator — adding a level later
/// is one entry here plus one CLI verb triple.
public struct DopeLevelSpec: Sendable {
    public let level: DopeLevel
    public let table: String
    public let parentLevel: DopeLevel?
    public let parentColumn: String?
    public let ownedFields: Set<DopeField>

    public static let all: [DopeLevel: DopeLevelSpec] = {
        let common: Set<DopeField> = [.code, .name, .description, .sortOrder]
        let specs: [DopeLevelSpec] = [
            DopeLevelSpec(level: .scope, table: "dope_scope",
                          parentLevel: nil, parentColumn: nil,
                          ownedFields: [.code, .name, .description]),
            DopeLevelSpec(level: .domain, table: "dope_domain",
                          parentLevel: .scope, parentColumn: "dope_scope_uuid",
                          ownedFields: common),
            DopeLevelSpec(level: .entity, table: "dope_domain_entity",
                          parentLevel: .domain, parentColumn: "dope_domain_uuid",
                          ownedFields: common.union([.entityType, .repoRepresentativeFile,
                                                     .baseComposableUuid])),
            DopeLevelSpec(level: .property, table: "dope_domain_entity_property",
                          parentLevel: .entity, parentColumn: "dope_domain_entity_uuid",
                          ownedFields: common.union([.dataType, .nullable, .isUnique,
                                                     .autoIncrement, .textCharLimit,
                                                     .enumUuid, .relatedPropertyUuid,
                                                     .baseOriginPropertyUuid])),
            DopeLevelSpec(level: .enumeration, table: "dope_domain_enum",
                          parentLevel: .domain, parentColumn: "dope_domain_uuid",
                          ownedFields: common.union([.repoRepresentativeFile])),
            DopeLevelSpec(level: .option, table: "dope_domain_enum_option",
                          parentLevel: .enumeration, parentColumn: "dope_domain_enum_uuid",
                          ownedFields: common),
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.level, $0) })
    }()

    public static func spec(for level: DopeLevel) -> DopeLevelSpec {
        // The registry is total over DopeLevel by construction.
        all[level]!
    }
}

/// DopeScope.scope_type values.
public enum DopeScopeType: String, Codable, Hashable, CaseIterable, Sendable {
    case sessionBase = "SESSION_BASE"
    case prompt = "PROMPT"
}

/// DopeDomainEntity.entity_type values.
public enum DopeEntityType: String, Codable, Hashable, CaseIterable, Sendable {
    case model = "MODEL"
    case junction = "JUNCTION"
    /// Not persisted on its own — a shared column block other entities
    /// compose in via base_composable_uuid. Only a BASE_COMPOSABLE may be a
    /// base_composable_uuid target.
    case baseComposable = "BASE_COMPOSABLE"
}

/// DopeDomainEntityProperty.data_type values — the prompt's enum verbatim.
public enum DopePropertyDataType: String, Codable, Hashable, CaseIterable, Sendable {
    case enumeration = "enum"
    case relationship
    case boolean
    case uuid
    case int
    case long
    case decimal
    case text
    case datetime
}
