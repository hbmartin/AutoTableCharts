import Foundation

private enum AutoChartRequestDataIdentity: Hashable, @unchecked Sendable {
    case trusted(
        tableType: String,
        rowIDType: String,
        key: AutoChartDataKey,
        debugColumns: [AutoChartColumn]?,
        debugRowCount: Int?,
        debugRowIDs: [AutoChartErasedRowID]?)
    case contentAddressed(
        tableType: String,
        rowIDType: String,
        logicalIdentity: String?,
        columns: [AutoChartColumn],
        metadata: AutoChartTableMetadata,
        rowIDs: [AutoChartErasedRowID],
        values: [AutoChartValue])
    case legacyHash(Int)
}

private struct AutoChartRequestIdentityMaterial: Hashable, @unchecked Sendable {
    let data: AutoChartRequestDataIdentity
    let context: AutoChartContext
    let options: AutoChartOptions
    let constraints: AutoChartRecommendationConstraints
    let policyVersion: Int
}

private final class AutoChartRequestIDStorage: @unchecked Sendable {
    let material: AutoChartRequestIdentityMaterial
    let digest: Int

    init(material: AutoChartRequestIdentityMaterial) {
        self.material = material
        var hasher = Hasher()
        hasher.combine(material)
        self.digest = hasher.finalize()
    }
}

/// Opaque, collision-checked identity for a recommendation request in this process.
public struct AutoChartRequestID: Hashable, Sendable {
    private let storage: AutoChartRequestIDStorage

    fileprivate init(material: AutoChartRequestIdentityMaterial) {
        storage = AutoChartRequestIDStorage(material: material)
    }

    init(value: Int) {
        self.init(
            material: AutoChartRequestIdentityMaterial(
                data: .legacyHash(value),
                context: .init(),
                options: .init(),
                constraints: .init(),
                policyVersion: AutoTableCharts.recommendationPolicyVersion))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage
            || (lhs.storage.digest == rhs.storage.digest
                && lhs.storage.material == rhs.storage.material)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.digest)
    }
}

/// Opaque identity for one completed analysis in the current process.
public struct AutoChartAnalysisID: Hashable, Sendable {
    private let value: UUID
    init() { self.value = UUID() }
    init(value: UUID) { self.value = value }
}

/// Opaque identity for one prepared chart in the current process.
public struct AutoChartPreparedChartID: Hashable, Sendable {
    private let value: UUID
    init() { self.value = UUID() }
    init(value: UUID) { self.value = value }
}

/// Filters recommendation candidates before data-dependent validation.
public struct AutoChartRecommendationConstraints: Hashable, Codable, Sendable {
    public var includedFamilies: Set<AutoChartFamily>?
    public var excludedFamilies: Set<AutoChartFamily>
    public var requiredColumns: Set<AutoChartColumnID>
    public var excludedColumns: Set<AutoChartColumnID>

    public init(
        includedFamilies: Set<AutoChartFamily>? = nil,
        excludedFamilies: Set<AutoChartFamily> = [],
        requiredColumns: Set<AutoChartColumnID> = [],
        excludedColumns: Set<AutoChartColumnID> = []
    ) {
        self.includedFamilies = includedFamilies
        self.excludedFamilies = excludedFamilies
        self.requiredColumns = requiredColumns
        self.excludedColumns = excludedColumns
    }

    func allows(_ specification: AutoChartSpecification) -> Bool {
        if let includedFamilies, !includedFamilies.contains(specification.family) { return false }
        if excludedFamilies.contains(specification.family) { return false }
        let columns = Set(specification.encoding.columnIDs)
        return requiredColumns.isSubset(of: columns)
            && columns.isDisjoint(with: excludedColumns)
    }
}

/// A persisted host preference. It is deliberately independent of request identity.
public enum AutoChartPreference: Hashable, Codable, Sendable {
    public enum Chart: Hashable, Codable, Sendable {
        case recommended
        case specific(AutoChartRecommendationID)
    }

    case automatic
    case table
    case chart(Chart)
}

/// Controls eager chart preparation after recommendation analysis completes.
public enum AutoChartPreparationStrategy: String, Hashable, Codable, Sendable {
    case none
    case primary
    case preferredOrPrimary
    case allCataloged
}

/// Typed explanation for the recommendation selected from a preference.
public enum AutoChartPreferenceDefaultReason: Hashable, Codable, Sendable {
    case automatic
    case recommended
    case policyVersionChanged(previous: Int, current: Int)
    case specificationUnavailable
    case noSafeChart
}

/// The effective recommendation and any preference repair the host may persist.
public struct AutoChartPreferenceResolution: Sendable {
    public let recommendation: AutoChartRecommendation?
    public let defaultReason: AutoChartPreferenceDefaultReason?
    public let replacementPreference: AutoChartPreference?
    public let usesTable: Bool

    public init(
        recommendation: AutoChartRecommendation?,
        defaultReason: AutoChartPreferenceDefaultReason? = nil,
        replacementPreference: AutoChartPreference? = nil,
        usesTable: Bool = false
    ) {
        self.recommendation = recommendation
        self.defaultReason = defaultReason
        self.replacementPreference = replacementPreference
        self.usesTable = usesTable
    }
}

/// Localized option presented by a chart picker.
public struct AutoChartPickerOption: Identifiable, Hashable, Sendable {
    public let id: AutoChartRecommendationID
    public let family: AutoChartFamily
    public let label: String
}

/// Ranked safe recommendations, separated into compact featured and full catalog lists.
public struct AutoChartRecommendationCatalog: Hashable, Codable, Sendable,
    RandomAccessCollection
{
    /// Maximum number of recommendations exposed by the collection view.
    public static let maximumFeaturedCount = 5
    /// Maximum number of validated recommendations retained for explicit selection.
    public static let maximumCatalogedCount = 50

    public typealias Index = Int
    public typealias Element = AutoChartRecommendation

    public let featured: [AutoChartRecommendation]
    public let cataloged: [AutoChartRecommendation]
    public let preferred: AutoChartRecommendation?

    public init(
        featured: [AutoChartRecommendation],
        cataloged: [AutoChartRecommendation],
        preferred: AutoChartRecommendation? = nil
    ) {
        let safe = Array(cataloged.prefix(Self.maximumCatalogedCount))
        self.cataloged = safe
        self.featured = Array(
            featured
                .filter { item in safe.contains { $0.id == item.id } }
                .prefix(Self.maximumFeaturedCount))
        self.preferred = preferred.flatMap { item in
            safe.contains(where: { $0.id == item.id }) ? nil : item
        }
    }

    public var startIndex: Int { featured.startIndex }
    public var endIndex: Int { featured.endIndex }
    public subscript(position: Int) -> AutoChartRecommendation { featured[position] }

    public var primary: AutoChartRecommendation? { featured.first ?? cataloged.first ?? preferred }

    public func recommendation(
        for id: AutoChartRecommendationID
    ) -> AutoChartRecommendation? {
        cataloged.first { $0.id == id } ?? (preferred?.id == id ? preferred : nil)
    }

    public func pickerOptions(
        resolver: AutoChartTextResolver = .default
    ) -> [AutoChartPickerOption] {
        cataloged.map { recommendation in
            AutoChartPickerOption(
                id: recommendation.id,
                family: recommendation.specification.family,
                label: resolver(recommendation.specification.family.localizationMessage))
        }
    }
}

extension AutoChartFamily {
    /// Typed localization message for family names shown in package UI.
    public var localizationMessage: AutoChartMessage {
        AutoChartMessage(
            category: .interface,
            code: .init(rawValue: "chartFamily.\(rawValue)"),
            arguments: ["family": .family(self)],
            defaultText: displayName)
    }
}

/// Observable phases shared by coalesced analysis and preparation waiters.
public enum AutoChartProgressPhase: String, Hashable, Codable, Sendable {
    case materialization
    case profiling
    case recommendation
    case chartPreparation
    case presentationPreparation
}

public struct AutoChartProgress: Hashable, Codable, Sendable {
    public let phase: AutoChartProgressPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int?

    public init(
        phase: AutoChartProgressPhase,
        completedUnitCount: Int = 0,
        totalUnitCount: Int? = nil
    ) {
        self.phase = phase
        self.completedUnitCount = max(0, completedUnitCount)
        self.totalUnitCount = totalUnitCount.map { max(0, $0) }
    }
}

public enum AutoChartFailureStage: String, Hashable, Codable, Sendable {
    case materialization
    case profiling
    case recommendation
    case chartPreparation
    case presentationPreparation
}

public enum AutoChartFailureKind: String, Hashable, Codable, Sendable {
    case invalidData
    case invalidSpecification
    case unavailableRecommendation
    case resourceLimit
    case transient
    case internalFailure
}

/// Stable failure classification plus a unique ID for one attempt episode.
public struct AutoChartFailure: LocalizedError, Hashable, Codable, Sendable {
    public let stage: AutoChartFailureStage
    public let kind: AutoChartFailureKind
    public let isRetryable: Bool
    public let diagnosticID: String
    public let episodeID: UUID
    public let message: String

    public var errorDescription: String? { message }

    public init(
        stage: AutoChartFailureStage,
        kind: AutoChartFailureKind,
        isRetryable: Bool,
        diagnosticID: String,
        episodeID: UUID = UUID(),
        message: String
    ) {
        self.stage = stage
        self.kind = kind
        self.isRetryable = isRetryable
        self.diagnosticID = diagnosticID
        self.episodeID = episodeID
        self.message = message
    }

    static func wrapping(_ error: any Error, stage: AutoChartFailureStage) -> Self {
        if let failure = error as? AutoChartFailure { return failure }
        let kind: AutoChartFailureKind
        let retryable: Bool
        switch error {
        case is AutoChartDatasetError:
            kind = .invalidData
            retryable = false
        case AutoChartPreparationError.invalidSpecification:
            kind = .invalidSpecification
            retryable = false
        case AutoChartPreparationError.recommendationUnavailable:
            kind = .unavailableRecommendation
            retryable = false
        default:
            kind = .internalFailure
            retryable = true
        }
        let diagnosticID = "ATC.\(stage.rawValue).\(kind.rawValue)"
        return Self(
            stage: stage,
            kind: kind,
            isRetryable: retryable,
            diagnosticID: diagnosticID,
            message: (error as? LocalizedError)?.errorDescription
                ?? String(describing: error))
    }
}

/// Type-erased, identity-bearing input to an analyzer or session.
public struct AutoChartRequest<RowID: Hashable & Sendable>: Sendable {
    public let id: AutoChartRequestID
    public let dataKey: AutoChartDataKey
    public let context: AutoChartContext
    public let options: AutoChartOptions
    public let constraints: AutoChartRecommendationConstraints
    public let policyVersion: Int

    let materialize: @Sendable () throws -> AutoChartDataset<RowID>

    public init<Table: AutoChartTable>(
        table: Table,
        context: AutoChartContext = .init(),
        options: AutoChartOptions = .init(),
        constraints: AutoChartRecommendationConstraints = .init(),
        policyVersion: Int = AutoTableCharts.recommendationPolicyVersion
    ) throws where Table.RowID == RowID {
        let key = table.chartDataKey
        let columns = table.chartColumns
        let copy: @Sendable (AutoChartDataKey) throws -> AutoChartDataset<RowID> = {
            materializedKey in
            try Task.checkCancellation()
            if let dataset = table as? AutoChartDataset<RowID> {
                return dataset.replacingDataKey(with: materializedKey)
            }
            let rows = Array(table.chartRows)
            var matrix: [[AutoChartValue]] = []
            matrix.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                if offset.isMultiple(of: 256) { try Task.checkCancellation() }
                matrix.append(columns.map { row.chartValue(for: $0.id) })
            }
            return try AutoChartDataset(
                columns: columns,
                rows: matrix,
                rowIDs: rows.map(\.chartRowID),
                metadata: table.chartMetadata,
                key: materializedKey)
        }

        let dataIdentity: AutoChartRequestDataIdentity
        let materializer: @Sendable () throws -> AutoChartDataset<RowID>
        switch key {
        case .trusted:
            let debugColumns: [AutoChartColumn]?
            let debugRowCount: Int?
            let debugRowIDs: [AutoChartErasedRowID]?
            #if DEBUG
            // Trusted revisions deliberately avoid cell reads. Debug builds add
            // inexpensive structural verification when the row collection is a
            // practical size; callers remain responsible for value revisions.
            let debugRows = table.chartRows
            debugColumns = columns
            debugRowCount = debugRows.count
            if debugRows.count <= 10_000 {
                debugRowIDs = debugRows.map { AutoChartErasedRowID($0.chartRowID) }
            } else {
                debugRowIDs = nil
            }
            #else
            debugColumns = nil
            debugRowCount = nil
            debugRowIDs = nil
            #endif
            dataIdentity = .trusted(
                tableType: String(reflecting: Table.self),
                rowIDType: String(reflecting: RowID.self),
                key: key,
                debugColumns: debugColumns,
                debugRowCount: debugRowCount,
                debugRowIDs: debugRowIDs)
            // The public completed-analysis index supplies trusted warm hits
            // without reading cells. A cold/mismatched request enters the
            // engine through its collision-checked content path so an old
            // trusted revision can never mask a debug structural mismatch.
            materializer = { try copy(.contentAddressed(identity: key.identity)) }
        case .contentAddressed(let logicalIdentity):
            let dataset = try copy(key)
            dataIdentity = .contentAddressed(
                tableType: String(reflecting: Table.self),
                rowIDType: String(reflecting: RowID.self),
                logicalIdentity: logicalIdentity,
                columns: dataset.chartColumns,
                metadata: dataset.chartMetadata,
                rowIDs: dataset._autoChartErasedRowIDs,
                values: dataset._autoChartMatrixStorage.values)
            materializer = { dataset }
        }

        self.id = AutoChartRequestID(
            material: AutoChartRequestIdentityMaterial(
                data: dataIdentity,
                context: context,
                options: options,
                constraints: constraints,
                policyVersion: policyVersion))
        self.dataKey = key
        self.context = context
        self.options = options
        self.constraints = constraints
        self.policyVersion = policyVersion
        self.materialize = materializer
    }
}
