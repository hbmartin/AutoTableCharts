import Foundation

/// Stable identity for one entity in a host application's semantic model.
///
/// Entity identifiers describe source-domain grain, not result-column identity.
/// For example, a host might declare `property`, `lease`, and `tenant` entities.
public struct AutoChartEntityID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// A column in a source entity that contributed to one result column.
public struct AutoChartSourceColumn: Hashable, Codable, Sendable {
    public var entity: AutoChartEntityID
    public var name: String

    public init(entity: AutoChartEntityID, name: String) {
        self.entity = entity
        self.name = name
    }
}

/// The ordered set of source entities required to identify one observation.
///
/// Order is retained for stable coding and diagnostics. Duplicate entities are
/// removed while preserving the first occurrence.
public struct AutoChartGrain: Hashable, Codable, Sendable {
    public private(set) var entities: [AutoChartEntityID]

    public init(_ entities: [AutoChartEntityID]) {
        var seen: Set<AutoChartEntityID> = []
        self.entities = entities.filter { seen.insert($0).inserted }
    }

    public init(entity: AutoChartEntityID) {
        self.init([entity])
    }
}

/// Source lineage retained for a result column.
public struct AutoChartColumnProvenance: Hashable, Codable, Sendable {
    public var sourceColumns: [AutoChartSourceColumn]
    public var sourceGrain: AutoChartGrain?

    public init(
        sourceColumns: [AutoChartSourceColumn] = [],
        sourceGrain: AutoChartGrain? = nil
    ) {
        self.sourceColumns = sourceColumns
        self.sourceGrain = sourceGrain
    }
}

/// A declared one-to-many relationship between source entities.
///
/// `one` is the coarser parent grain and `many` is the finer child grain.
public struct AutoChartEntityRelationship: Hashable, Codable, Sendable {
    public var one: AutoChartEntityID
    public var many: AutoChartEntityID

    public init(one: AutoChartEntityID, many: AutoChartEntityID) {
        self.one = one
        self.many = many
    }
}

/// The source-entity relationships used for grain-aware safety checks.
public struct AutoChartSemanticModel: Hashable, Codable, Sendable {
    public var relationships: [AutoChartEntityRelationship]

    public init(relationships: [AutoChartEntityRelationship] = []) {
        self.relationships = relationships
    }

    /// Whether `candidate` identifies observations strictly finer than `reference`.
    ///
    /// A composite grain is finer when it adds an entity key, or when every
    /// reference entity is the same as or an ancestor of a candidate entity and
    /// at least one relationship traversal is required.
    public func isStrictlyFiner(
        _ candidate: AutoChartGrain,
        than reference: AutoChartGrain
    ) -> Bool {
        guard !candidate.entities.isEmpty, !reference.entities.isEmpty,
            candidate != reference
        else { return false }

        let candidateSet = Set(candidate.entities)
        let referenceSet = Set(reference.entities)
        if referenceSet.isSubset(of: candidateSet) { return true }

        var traversedRelationship = false
        for entity in reference.entities {
            var matched = false
            for candidateEntity in candidate.entities {
                if entity == candidateEntity {
                    matched = true
                    break
                }
                if isAncestor(entity, of: candidateEntity) {
                    matched = true
                    traversedRelationship = true
                    break
                }
            }
            if !matched { return false }
        }
        return traversedRelationship
    }

    private func isAncestor(
        _ possibleAncestor: AutoChartEntityID,
        of entity: AutoChartEntityID
    ) -> Bool {
        var frontier = [possibleAncestor]
        var visited: Set<AutoChartEntityID> = []
        while let current = frontier.popLast() {
            guard visited.insert(current).inserted else { continue }
            for relationship in relationships where relationship.one == current {
                if relationship.many == entity { return true }
                frontier.append(relationship.many)
            }
        }
        return false
    }
}
