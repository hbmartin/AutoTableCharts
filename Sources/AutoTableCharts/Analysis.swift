import Foundation

/// Count and approximate retained-byte limit for one analyzer layer.
public struct AutoChartCacheLimit: Hashable, Codable, Sendable {
    public var maximumEntries: Int {
        didSet { maximumEntries = max(0, maximumEntries) }
    }

    private enum CodingKeys: String, CodingKey { case maximumEntries }

    public init(maximumEntries: Int) {
        self.maximumEntries = max(0, maximumEntries)
    }

    /// Decodes a limit and applies the same safe minimum as the initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maximumEntries: try container.decode(Int.self, forKey: .maximumEntries))
    }
}

/// Scoped analyzer retention policy.
public struct AutoChartAnalyzerConfiguration: Hashable, Codable, Sendable {
    public static let standard = AutoChartAnalyzerConfiguration()
    public static let uncached = AutoChartAnalyzerConfiguration(
        tables: .init(maximumEntries: 0),
        analyses: .init(maximumEntries: 0),
        preparedCharts: .init(maximumEntries: 0),
        maximumRetainedCost: 0)

    public var tables: AutoChartCacheLimit
    public var analyses: AutoChartCacheLimit
    public var preparedCharts: AutoChartCacheLimit
    public var maximumRetainedCost: Int {
        didSet { maximumRetainedCost = max(0, maximumRetainedCost) }
    }

    private enum CodingKeys: String, CodingKey {
        case tables, analyses, preparedCharts, maximumRetainedCost
    }

    public init(
        tables: AutoChartCacheLimit = .init(maximumEntries: 8),
        analyses: AutoChartCacheLimit = .init(maximumEntries: 16),
        preparedCharts: AutoChartCacheLimit = .init(maximumEntries: 16),
        maximumRetainedCost: Int = 64 * 1_024 * 1_024
    ) {
        self.tables = tables
        self.analyses = analyses
        self.preparedCharts = preparedCharts
        self.maximumRetainedCost = max(0, maximumRetainedCost)
    }

    /// Decodes a configuration and applies the same safe minimums as the initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tables: try container.decode(AutoChartCacheLimit.self, forKey: .tables),
            analyses: try container.decode(AutoChartCacheLimit.self, forKey: .analyses),
            preparedCharts: try container.decode(
                AutoChartCacheLimit.self, forKey: .preparedCharts),
            maximumRetainedCost: try container.decode(
                Int.self, forKey: .maximumRetainedCost))
    }
}

public enum AutoChartCacheTrimTarget: Hashable, Codable, Sendable {
    case minimum
    case configuredLimits
}

public struct AutoChartCacheLayerStatistics: Hashable, Codable, Sendable {
    public var entries: Int
    public var retainedCost: Int
    /// Lookups satisfied by a completed retained entry.
    ///
    /// A request that joins matching work already in flight increments neither
    /// `hits` nor ``misses`` because it neither reuses a retained entry nor
    /// starts new work.
    public var hits: Int
    /// Lookups that started new work because no completed retained entry or
    /// matching in-flight work was available.
    public var misses: Int
    public var evictions: Int

    public init(
        entries: Int = 0,
        retainedCost: Int = 0,
        hits: Int = 0,
        misses: Int = 0,
        evictions: Int = 0
    ) {
        self.entries = entries
        self.retainedCost = retainedCost
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
    }
}

public struct AutoChartCacheStatistics: Hashable, Codable, Sendable {
    public var tables: AutoChartCacheLayerStatistics
    public var analyses: AutoChartCacheLayerStatistics
    public var preparedCharts: AutoChartCacheLayerStatistics
    public var inFlightRequests: Int

    public init(
        tables: AutoChartCacheLayerStatistics = .init(),
        analyses: AutoChartCacheLayerStatistics = .init(),
        preparedCharts: AutoChartCacheLayerStatistics = .init(),
        inFlightRequests: Int = 0
    ) {
        self.tables = tables
        self.analyses = analyses
        self.preparedCharts = preparedCharts
        self.inFlightRequests = inFlightRequests
    }
}

public enum AutoChartPreparationError: Error, Sendable {
    case recommendationUnavailable(AutoChartRecommendationID)
    case invalidSpecification(AutoChartValidationResult)
}

/// A prepared mark with caller-defined source lineage.
public struct AutoChartPreparedMark<RowID: Hashable & Sendable>: Hashable, Sendable {
    public let identity: String
    public let sourceRowIDs: Set<RowID>

    public init(identity: String, sourceRowIDs: Set<RowID>) {
        self.identity = identity
        self.sourceRowIDs = sourceRowIDs
    }
}

extension AutoChartPreparedMark: Codable where RowID: Codable {}

final class AutoChartPreparedSource<RowID: Hashable & Sendable>: Sendable {
    let key: AutoChartAnalyzer.TableKey
    let snapshot: AutoChartSnapshot
    let profiles: [AutoChartColumnID: AutoChartColumnProfile]
    let rowIDs: [RowID]
    let contentFingerprint: Int
    let estimatedStorageCost: Int
    let cost: Int

    init(
        key: AutoChartAnalyzer.TableKey,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        rowIDs: [RowID],
        contentFingerprint: Int,
        estimatedStorageCost: Int
    ) {
        self.key = key
        self.snapshot = snapshot
        self.profiles = profiles
        self.rowIDs = rowIDs
        self.contentFingerprint = contentFingerprint
        self.estimatedStorageCost = estimatedStorageCost
        self.cost =
            estimatedStorageCost
            + profiles.values.reduce(0) { $0 + $1.estimatedRetainedCost }
    }
}

/// Immutable mark preparation consumed by ``AutoChartPlot`` and ``AutoChartView``.
public struct AutoChartPreparedChart<RowID: Hashable & Sendable>: Sendable {
    public let recommendation: AutoChartRecommendation
    public let validation: AutoChartValidationResult
    public let marks: [AutoChartPreparedMark<RowID>]
    public var diagnostics: [AutoChartDiagnostic] {
        var result = recommendation.diagnostics
        for issue in validation.issues
        where issue.severity == .warning && !result.contains(issue) {
            result.append(issue)
        }
        return result
    }

    let sourceRowIDs: [RowID]
    let core: AutoChartRenderCore

    init(
        source: AutoChartPreparedSource<RowID>,
        recommendation: AutoChartRecommendation,
        core: AutoChartRenderCore
    ) {
        self.recommendation = recommendation
        self.validation = core.validation
        self.sourceRowIDs = source.rowIDs
        self.core = core
        self.marks = core.data.map { datum in
            AutoChartPreparedMark(
                identity: datum.id,
                sourceRowIDs: Set(
                    datum.sourceRowIDs.compactMap { offset in
                        source.rowIDs.indices.contains(offset) ? source.rowIDs[offset] : nil
                    }))
        }
    }

    func rowIDs(for offsets: Set<Int>) -> Set<RowID> {
        Set(offsets.compactMap { sourceRowIDs.indices.contains($0) ? sourceRowIDs[$0] : nil })
    }
}

final class AutoChartAnalysisPreparationProvider<RowID: Hashable & Sendable>: Sendable {
    let analyzer: AutoChartAnalyzer
    let source: AutoChartPreparedSource<RowID>
    let recommendations: [AutoChartRecommendation]

    init(
        analyzer: AutoChartAnalyzer,
        source: AutoChartPreparedSource<RowID>,
        recommendations: [AutoChartRecommendation]
    ) {
        self.analyzer = analyzer
        self.source = source
        self.recommendations = recommendations
    }

    func prepare(_ recommendationID: AutoChartRecommendationID) async throws
        -> AutoChartPreparedChart<RowID>
    {
        guard let recommendation = recommendations.first(where: { $0.id == recommendationID })
        else { throw AutoChartPreparationError.recommendationUnavailable(recommendationID) }
        return try await analyzer.prepare(recommendation, source: source)
    }

    func prepare(_ specification: AutoChartSpecification) async throws
        -> AutoChartPreparedChart<RowID>
    {
        let recommendation = AutoChartRecommendation(
            specification: specification,
            score: 0,
            rationale: [
                AutoChartMessage(
                    category: .rationale,
                    code: .recommendationRationale,
                    defaultText: "Caller-provided specification.")
            ])
        return try await analyzer.prepare(recommendation, source: source)
    }
}

/// Retainable result of one analyzer request.
public struct AutoChartAnalysis<RowID: Hashable & Sendable>: Sendable {
    public let outcome: AutoChartRecommendationOutcome
    public let columnProfiles: [AutoChartColumnProfile]
    public let diagnostics: [AutoChartDiagnostic]
    public let decisionTrace: AutoChartDecisionTrace?
    public let primaryChart: AutoChartPreparedChart<RowID>?

    private let provider: AutoChartAnalysisPreparationProvider<RowID>

    init(
        outcome: AutoChartRecommendationOutcome,
        profiles: [AutoChartColumnProfile],
        diagnostics: [AutoChartDiagnostic],
        decisionTrace: AutoChartDecisionTrace?,
        primaryChart: AutoChartPreparedChart<RowID>?,
        provider: AutoChartAnalysisPreparationProvider<RowID>
    ) {
        self.outcome = outcome
        self.columnProfiles = profiles
        self.diagnostics = diagnostics
        self.decisionTrace = decisionTrace
        self.primaryChart = primaryChart
        self.provider = provider
    }

    public func resolve(
        _ persistedID: AutoChartRecommendationID?
    ) -> AutoChartRecommendationResolution {
        switch outcome {
        case .tableFallback(let fallback):
            return .unavailable(fallback)
        case .charts(let recommendations):
            guard let primary = recommendations.first else {
                let fallback = AutoChartFallback(
                    message: AutoChartMessage(
                        category: .fallback,
                        code: .noSafeChart,
                        defaultText: "No safe chart is available."))
                return .unavailable(fallback)
            }
            guard let persistedID else {
                return .defaulted(primary, reason: .noPersistedPreference)
            }
            guard persistedID.policyVersion == AutoTableCharts.recommendationPolicyVersion else {
                return .defaulted(
                    primary,
                    reason: .policyVersionChanged(
                        previous: persistedID.policyVersion,
                        current: AutoTableCharts.recommendationPolicyVersion))
            }
            if let exact = recommendations.first(where: { $0.id == persistedID }) {
                return .exact(exact)
            }
            return .defaulted(primary, reason: .specificationUnavailable)
        }
    }

    /// Validates `specification` against this analysis.
    ///
    /// - Important: This runs on the calling thread, and for an aggregated,
    ///   stacked, normalized, or composition specification it prepares every
    ///   mark to check the aggregated numeric domain — work proportional to the
    ///   row count. Calling it from a SwiftUI `body` or a main-actor action on
    ///   a large table will hitch. Prefer ``validation(for:)``, which does the
    ///   same work off the caller's thread and shares the analyzer's
    ///   prepared-chart cache with ``prepare(_:)-(AutoChartSpecification)``.
    public func validate(
        _ specification: AutoChartSpecification
    ) -> AutoChartValidationResult {
        AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: provider.source.snapshot,
            profiles: provider.source.profiles)
    }

    /// Validates `specification` against the marks ``prepare(_:)-(AutoChartSpecification)``
    /// would produce, reusing the analyzer's prepared-chart cache.
    ///
    /// Preferred over ``validate(_:)`` whenever the result is used to decide
    /// whether to offer a chart: the mark preparation happens once and is
    /// shared with the subsequent `prepare(_:)` call rather than being redone.
    ///
    /// - Important: A specification that validates is left in the analyzer's
    ///   prepared-chart cache — that is what makes the following `prepare(_:)`
    ///   free. Validating many candidate specifications to choose one will
    ///   therefore admit all of them, and the cache evicts by recency within
    ///   ``AutoChartAnalyzerConfiguration/maximumRetainedCost``, so a wide
    ///   sweep can push out entries the host still wants. Validate the few
    ///   specifications actually under consideration, or call
    ///   ``AutoChartAnalyzer/trim(to:)`` afterwards. An invalid specification
    ///   is never cached.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled. An
    ///   invalid specification is reported through the returned result, not by
    ///   throwing.
    public func validation(
        for specification: AutoChartSpecification
    ) async throws -> AutoChartValidationResult {
        do {
            return try await provider.prepare(specification).validation
        } catch AutoChartPreparationError.invalidSpecification(let validation) {
            try Task.checkCancellation()
            return validation
        }
    }

    public func prepare(
        _ recommendationID: AutoChartRecommendationID
    ) async throws -> AutoChartPreparedChart<RowID> {
        try await provider.prepare(recommendationID)
    }

    public func prepare(
        _ specification: AutoChartSpecification
    ) async throws -> AutoChartPreparedChart<RowID> {
        try await provider.prepare(specification)
    }
}

private final class AutoChartAnyCacheBox: @unchecked Sendable {
    let value: Any
    let cost: Int
    let sharedObject: AnyObject?
    let sharedObjectIdentifier: ObjectIdentifier?
    let sharedObjectCost: Int

    init(
        _ value: Any,
        cost: Int,
        sharedObject: AnyObject? = nil,
        sharedObjectCost: Int = 0
    ) {
        self.value = value
        self.cost = max(0, cost)
        self.sharedObject = sharedObject
        self.sharedObjectIdentifier = sharedObject.map(ObjectIdentifier.init)
        self.sharedObjectCost = max(0, sharedObjectCost)
    }
}

private final class AutoChartAnyRowIDs: @unchecked Sendable {
    private let value: Any

    init<RowID: Hashable & Sendable>(_ rowIDs: [RowID]) {
        self.value = rowIDs
    }

    func matches<RowID: Hashable & Sendable>(_ rowIDs: [RowID]) -> Bool {
        (value as? [RowID]) == rowIDs
    }
}

private struct AutoChartCachedAnalysis<RowID: Hashable & Sendable>: Sendable {
    let source: AutoChartPreparedSource<RowID>
    let outcome: AutoChartRecommendationOutcome
    let profiles: [AutoChartColumnProfile]
    let diagnostics: [AutoChartDiagnostic]
    let trace: AutoChartDecisionTrace?
    let primary: AutoChartPreparedChart<RowID>?
    let recommendations: [AutoChartRecommendation]
}

/// Instance-owned analysis, preparation, and cache lifecycle service.
public actor AutoChartAnalyzer {
    private struct GenerationInvalidatedError: Error {}

    /// The cache state a request observed when it began. `generation` decides
    /// whether the request is still valid; `cacheEpoch` decides whether its
    /// results may still be cached.
    struct RequestToken: Hashable, Sendable {
        var generation: UInt64
        var cacheEpoch: UInt64
    }
    private static let maximumGenerationRetries = 3

    struct TableKey: Hashable, Sendable {
        var rowIDType: String
        var tableType: String
        var contentIdentity: String
    }

    private struct AnalysisKey: Hashable, Sendable {
        var table: TableKey
        var context: AutoChartContext
        var options: AutoChartOptions
        var policyVersion: Int
    }

    /// Keyed by structural specification identity rather than by the whole
    /// specification: `AutoChartSpecification.id` deliberately excludes the
    /// title, so two identically shaped charts with different titles share one
    /// preparation and `adapted(_:to:source:)` swaps in the caller's title.
    private struct ChartKey: Hashable, Sendable {
        var table: TableKey
        var specificationID: AutoChartSpecificationID
    }

    private struct RequestKey: Hashable, Sendable {
        var table: TableKey
        var context: AutoChartContext
        var options: AutoChartOptions
        var policyVersion: Int
    }

    private struct InFlightAnalysis: Sendable {
        var id: UUID
        var task: Task<AutoChartAnyCacheBox, Error>
        var waiterTokens: Set<UUID>
        var unkeyedSnapshot: AutoChartSnapshot?
        var unkeyedRowIDs: AutoChartAnyRowIDs?
    }

    private enum RequestContent: Sendable {
        case keyed(AutoChartDataKey)
        case fingerprinted(snapshot: AutoChartSnapshot, contentFingerprint: Int)
    }

    private struct RequestPreparation<RowID: Hashable & Sendable>: Sendable {
        var rowIDs: [RowID]
        var content: RequestContent
    }

    private struct InFlightIdentity: Hashable, Sendable {
        var key: RequestKey
        var id: UUID
    }

    private struct InFlightCandidate: Sendable {
        var identity: InFlightIdentity
        var snapshot: AutoChartSnapshot?
        var rowIDs: AutoChartAnyRowIDs?
    }

    private struct InFlightRegistration: Sendable {
        var identity: InFlightIdentity
        var waiterToken: UUID
        var task: Task<AutoChartAnyCacheBox, Error>
    }

    private struct InFlightChart: Sendable {
        var id: UUID
        var task: Task<AutoChartAnyCacheBox, Error>
    }

    private enum ChartPreparationRegistration: Sendable {
        case cached(AutoChartAnyCacheBox)
        case inFlight(Task<AutoChartAnyCacheBox, Error>)
    }

    private enum SourceCandidateOrigin: Hashable, Sendable {
        case table
        case analysis(AnalysisKey)
        case chart(ChartKey)
    }

    private struct SourceCandidateIdentity: Hashable, Sendable {
        var key: TableKey
        var source: ObjectIdentifier
        var origin: SourceCandidateOrigin
    }

    private struct SourceCandidate<RowID: Hashable & Sendable>: Sendable {
        var identity: SourceCandidateIdentity
        var source: AutoChartPreparedSource<RowID>
    }

    private struct SourceResolution<RowID: Hashable & Sendable>: Sendable {
        var source: AutoChartPreparedSource<RowID>?
        var tableKey: TableKey
    }

    private let configuration: AutoChartAnalyzerConfiguration
    private var tableEntries: [TableKey: AutoChartAnyCacheBox] = [:]
    private var tableRecency: [TableKey] = []
    private var analysisEntries: [AnalysisKey: AutoChartAnyCacheBox] = [:]
    private var analysisRecency: [AnalysisKey] = []
    private var chartEntries: [ChartKey: AutoChartAnyCacheBox] = [:]
    private var chartRecency: [ChartKey] = []
    private var inFlightAnalyses: [RequestKey: InFlightAnalysis] = [:]
    private var inFlightCharts: [ChartKey: InFlightChart] = [:]
    private var statistics = AutoChartCacheStatistics()
    private var generation: UInt64 = 0
    /// Bumped whenever cached entries are purged wholesale. Work that began
    /// before a purge must not repopulate the cache it was asked to release,
    /// so cache insertion is gated on this rather than on `generation`, which
    /// invalidates the requests themselves.
    private var cacheEpoch: UInt64 = 0

    public init(configuration: AutoChartAnalyzerConfiguration = .standard) {
        self.configuration = configuration
    }

    public var cacheStatistics: AutoChartCacheStatistics {
        var value = statistics
        value.tables.entries = tableEntries.count
        value.analyses.entries = analysisEntries.count
        value.preparedCharts.entries = chartEntries.count
        value.tables.retainedCost = layerCost(tableEntries.values)
        value.analyses.retainedCost = layerCost(analysisEntries.values)
        value.preparedCharts.retainedCost = layerCost(chartEntries.values)
        return value
    }

    public nonisolated func analyze<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext = .init(),
        options: AutoChartOptions = .init()
    ) async throws -> AutoChartAnalysis<Table.RowID> {
        var generationRetries = 0
        while true {
            do {
                return try await analyzeOnce(table, context: context, options: options)
            } catch is GenerationInvalidatedError {
                try Task.checkCancellation()
                guard generationRetries < Self.maximumGenerationRetries else {
                    throw CancellationError()
                }
                generationRetries += 1
                await Task.yield()
            }
        }
    }

    private nonisolated func analyzeOnce<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext,
        options: AutoChartOptions
    ) async throws -> AutoChartAnalysis<Table.RowID> {
        let requestToken = await beginRequest()
        do {
            let preparation = try Self.prepareRequest(table)
            try Task.checkCancellation()
            guard await isCurrentGeneration(requestToken) else {
                throw GenerationInvalidatedError()
            }
            let contentIdentity: String
            switch preparation.content {
            case .keyed(let dataKey):
                contentIdentity =
                    "key:\(dataKey.identity.utf8.count):\(dataKey.identity)|"
                    + "\(dataKey.revision.utf8.count):\(dataKey.revision)"
            case .fingerprinted(_, let contentFingerprint):
                contentIdentity = "fingerprint:\(contentFingerprint)"
            }
            let baseRequestKey = RequestKey(
                table: TableKey(
                    rowIDType: String(reflecting: Table.RowID.self),
                    tableType: String(reflecting: Table.self),
                    contentIdentity: contentIdentity),
                context: context,
                options: options,
                policyVersion: AutoTableCharts.recommendationPolicyVersion)
            let registration = try await registerRequest(
                table,
                context: context,
                options: options,
                preparation: preparation,
                baseRequestKey: baseRequestKey,
                requestToken: requestToken)
            do {
                let box = try await withTaskCancellationHandler {
                    try await registration.task.value
                } onCancel: {
                    Task {
                        await self.releaseWaiter(
                            registration.identity.key,
                            flightID: registration.identity.id,
                            waiterToken: registration.waiterToken,
                            cancelWhenEmpty: true)
                    }
                }
                await releaseWaiter(
                    registration.identity.key,
                    flightID: registration.identity.id,
                    waiterToken: registration.waiterToken,
                    cancelWhenEmpty: false)
                try Task.checkCancellation()
                guard let analysis = box.value as? AutoChartAnalysis<Table.RowID> else {
                    preconditionFailure("Coalesced analysis row-ID type mismatch.")
                }
                guard await finishRequestIfCurrent(requestToken) else {
                    throw GenerationInvalidatedError()
                }
                return analysis
            } catch {
                await releaseWaiter(
                    registration.identity.key,
                    flightID: registration.identity.id,
                    waiterToken: registration.waiterToken,
                    cancelWhenEmpty: error is CancellationError)
                throw error
            }
        } catch {
            await finishRequest(requestToken)
            let requestIsCurrent = await isCurrentGeneration(requestToken)
            if error is CancellationError,
                !Task.isCancelled,
                !requestIsCurrent
            {
                throw GenerationInvalidatedError()
            }
            throw error
        }
    }

    private nonisolated static func prepareRequest<Table: AutoChartTable>(
        _ table: Table
    ) throws -> RequestPreparation<Table.RowID> {
        try Task.checkCancellation()
        let rowIDs = table.chartRows.map(\.chartRowID)
        if let dataKey = table.chartDataKey {
            return RequestPreparation(rowIDs: rowIDs, content: .keyed(dataKey))
        }
        let snapshot = try AutoChartSnapshot(validating: table)
        let fingerprint = try snapshot.contentFingerprintCheckingCancellation()
        try Task.checkCancellation()
        return RequestPreparation(
            rowIDs: rowIDs,
            content: .fingerprinted(
                snapshot: snapshot,
                contentFingerprint: fingerprint))
    }

    private nonisolated func registerRequest<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext,
        options: AutoChartOptions,
        preparation: RequestPreparation<Table.RowID>,
        baseRequestKey: RequestKey,
        requestToken: RequestToken
    ) async throws -> InFlightRegistration {
        while true {
            try Task.checkCancellation()
            guard await isCurrentGeneration(requestToken) else {
                throw CancellationError()
            }
            let candidates = await inFlightCandidates(for: baseRequestKey)
            let matchingIdentity: InFlightIdentity?
            switch preparation.content {
            case .fingerprinted(let snapshot, _):
                matchingIdentity = try candidates.first { candidate in
                    try candidate.snapshot?
                        .hasSameContentCheckingCancellation(as: snapshot) == true
                        && candidate.rowIDs?.matches(preparation.rowIDs) == true
                }?.identity
            case .keyed:
                matchingIdentity = candidates.first?.identity
            }
            if let registration = await registerInFlight(
                table,
                context: context,
                options: options,
                preparation: preparation,
                baseRequestKey: baseRequestKey,
                observed: Set(candidates.map(\.identity)),
                matching: matchingIdentity,
                requestToken: requestToken)
            {
                return registration
            }
        }
    }

    private nonisolated func analyzeUncoalesced<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext,
        options: AutoChartOptions,
        preparation: RequestPreparation<Table.RowID>,
        requestTableKey: TableKey,
        requestToken: RequestToken
    ) async throws -> AutoChartAnalysis<Table.RowID> {
        try Task.checkCancellation()
        var source: AutoChartPreparedSource<Table.RowID>?
        switch preparation.content {
        case .keyed:
            source = await cachedKeyedSource(for: requestTableKey)
        case .fingerprinted:
            source = nil
        }

        if source == nil {
            let snapshot: AutoChartSnapshot
            let fingerprint: Int
            switch preparation.content {
            case .keyed:
                snapshot = try AutoChartSnapshot(validating: table)
                fingerprint = try snapshot.contentFingerprintCheckingCancellation()
            case .fingerprinted(let preparedSnapshot, let preparedFingerprint):
                snapshot = preparedSnapshot
                fingerprint = preparedFingerprint
            }
            try Task.checkCancellation()

            let tableKey: TableKey
            switch preparation.content {
            case .fingerprinted:
                let collisionBase = TableKey(
                    rowIDType: requestTableKey.rowIDType,
                    tableType: requestTableKey.tableType,
                    contentIdentity: "fingerprint:\(fingerprint)")
                let resolution = try await resolveUnkeyedSource(
                    snapshot: snapshot,
                    rowIDs: preparation.rowIDs,
                    collisionBase: collisionBase,
                    preferredKey: requestTableKey,
                    requestToken: requestToken)
                source = resolution.source
                tableKey = resolution.tableKey
            case .keyed:
                tableKey = requestTableKey
            }

            if source == nil {
                let profiles = try AutoChartProfiler.profileIndexCheckingCancellation(snapshot)
                try Task.checkCancellation()
                let estimatedStorageCost = snapshot.estimatedStorageCost
                try Task.checkCancellation()
                let preparedSource = AutoChartPreparedSource(
                    key: tableKey,
                    snapshot: snapshot,
                    profiles: profiles,
                    rowIDs: preparation.rowIDs,
                    contentFingerprint: fingerprint,
                    estimatedStorageCost: estimatedStorageCost)
                source = preparedSource
                await insertTableIfCurrent(
                    preparedSource,
                    requestToken: requestToken)
            }
        }

        guard let source else { preconditionFailure("Prepared source must exist.") }
        await Task.yield()
        try Task.checkCancellation()
        let analysisKey = AnalysisKey(
            table: source.key,
            context: context,
            options: options,
            policyVersion: AutoTableCharts.recommendationPolicyVersion)
        if let cached: AutoChartCachedAnalysis<Table.RowID> = await cachedAnalysis(
            for: analysisKey)
        {
            return makeAnalysis(cached)
        }

        try Task.checkCancellation()
        let set = AutoChartRecommendationEngine.recommendations(
            snapshot: source.snapshot,
            context: context,
            options: options)
        try Task.checkCancellation()
        let recommendations = set.chartRecommendations
        let outcome: AutoChartRecommendationOutcome
        if recommendations.isEmpty {
            let reason = set.fallbackReason ?? "No safe chart can represent this result."
            let code: AutoChartMessage.Code = source.snapshot.rows.isEmpty
                ? .noChartableRows : .noSafeChart
            outcome = .tableFallback(
                AutoChartFallback(
                    message: AutoChartMessage(
                        category: .fallback,
                        code: code,
                        defaultText: reason)))
        } else {
            outcome = .charts(recommendations)
        }
        let primary: AutoChartPreparedChart<Table.RowID>?
        if let first = recommendations.first {
            primary = try await prepare(first, source: source, requestToken: requestToken)
        } else {
            primary = nil
        }
        try Task.checkCancellation()
        let diagnostics = recommendations.flatMap(\.diagnostics)
        let trace = options.includesDecisionTrace
            ? AutoChartDecisionTrace(
                inferredSemantics: source.snapshot.columns.compactMap { column in
                    source.profiles[column.id].map { profile in
                        AutoChartInferredColumnSemantics(
                            columnID: column.id,
                            semanticType: profile.semanticType,
                            role: column.hints.role,
                            measureSemantics: column.hints.measureSemantics)
                    }
                },
                candidates: set.decisions)
            : nil
        let cached = AutoChartCachedAnalysis(
            source: source,
            outcome: outcome,
            profiles: source.snapshot.columns.compactMap { source.profiles[$0.id] },
            diagnostics: diagnostics,
            trace: trace,
            primary: primary,
            recommendations: recommendations)
        await insertAnalysisIfCurrent(
            cached,
            for: analysisKey,
            requestToken: requestToken)
        return makeAnalysis(cached)
    }

    private nonisolated func resolveUnkeyedSource<RowID: Hashable & Sendable>(
        snapshot: AutoChartSnapshot,
        rowIDs: [RowID],
        collisionBase: TableKey,
        preferredKey: TableKey,
        requestToken: RequestToken
    ) async throws -> SourceResolution<RowID> {
        while true {
            try Task.checkCancellation()
            let candidates: [SourceCandidate<RowID>] = await sourceCandidates(
                inCollisionFamilyOf: collisionBase)
            let matching = try candidates.first { candidate in
                try candidate.source.snapshot.hasSameContentCheckingCancellation(as: snapshot)
                    && candidate.source.rowIDs == rowIDs
            }
            if let resolution = await finishUnkeyedSourceLookup(
                observed: Set(candidates.map(\.identity)),
                matching: matching,
                collisionBase: collisionBase,
                preferredKey: preferredKey,
                requestToken: requestToken)
            {
                return resolution
            }
        }
    }

    private func beginRequest() -> RequestToken {
        statistics.inFlightRequests += 1
        return RequestToken(generation: generation, cacheEpoch: cacheEpoch)
    }

    private func finishRequest(_ token: RequestToken) {
        guard token.generation == generation else { return }
        statistics.inFlightRequests = max(0, statistics.inFlightRequests - 1)
    }

    private func finishRequestIfCurrent(_ token: RequestToken) -> Bool {
        guard token.generation == generation else { return false }
        statistics.inFlightRequests = max(0, statistics.inFlightRequests - 1)
        return true
    }

    private func isCurrentGeneration(_ token: RequestToken) -> Bool {
        token.generation == generation
    }

    private func isCurrentCacheEpoch(_ token: RequestToken) -> Bool {
        token.cacheEpoch == cacheEpoch
    }

    private func inFlightCandidates(for base: RequestKey) -> [InFlightCandidate] {
        inFlightAnalyses.compactMap { key, flight in
            guard key.context == base.context,
                key.options == base.options,
                key.policyVersion == base.policyVersion,
                isCollisionFamily(key.table, of: base.table)
            else { return nil }
            return InFlightCandidate(
                identity: InFlightIdentity(key: key, id: flight.id),
                snapshot: flight.unkeyedSnapshot,
                rowIDs: flight.unkeyedRowIDs)
        }
    }

    private func registerInFlight<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext,
        options: AutoChartOptions,
        preparation: RequestPreparation<Table.RowID>,
        baseRequestKey: RequestKey,
        observed: Set<InFlightIdentity>,
        matching: InFlightIdentity?,
        requestToken: RequestToken
    ) -> InFlightRegistration? {
        guard isCurrentGeneration(requestToken),
            Set(inFlightCandidates(for: baseRequestKey).map(\.identity)) == observed
        else { return nil }
        let waiterToken = UUID()
        if let matching,
            var existing = inFlightAnalyses[matching.key],
            existing.id == matching.id
        {
            existing.waiterTokens.insert(waiterToken)
            inFlightAnalyses[matching.key] = existing
            return InFlightRegistration(
                identity: matching,
                waiterToken: waiterToken,
                task: existing.task)
        }

        var requestKey = baseRequestKey
        if inFlightAnalyses[requestKey] != nil {
            requestKey.table.contentIdentity += ":collision:\(UUID().uuidString)"
        }
        let identity = InFlightIdentity(key: requestKey, id: UUID())
        let task = Task {
            [table, context, options, preparation, requestKey, requestToken] in
            await Task.yield()
            let analysis = try await self.analyzeUncoalesced(
                table,
                context: context,
                options: options,
                preparation: preparation,
                requestTableKey: requestKey.table,
                requestToken: requestToken)
            return AutoChartAnyCacheBox(analysis, cost: 0)
        }
        inFlightAnalyses[requestKey] = InFlightAnalysis(
            id: identity.id,
            task: task,
            waiterTokens: [waiterToken],
            unkeyedSnapshot: {
                guard case .fingerprinted(let snapshot, _) = preparation.content
                else { return nil }
                return snapshot
            }(),
            unkeyedRowIDs: {
                guard case .fingerprinted = preparation.content else { return nil }
                return AutoChartAnyRowIDs(preparation.rowIDs)
            }())
        return InFlightRegistration(
            identity: identity,
            waiterToken: waiterToken,
            task: task)
    }

    private func cachedKeyedSource<RowID: Hashable & Sendable>(
        for key: TableKey
    ) -> AutoChartPreparedSource<RowID>? {
        if let cached = tableEntries[key]?.value as? AutoChartPreparedSource<RowID> {
            statistics.tables.hits += 1
            touch(key, in: &tableRecency)
            return cached
        }
        statistics.tables.misses += 1
        return nil
    }

    private func sourceCandidates<RowID: Hashable & Sendable>(
        inCollisionFamilyOf base: TableKey
    ) -> [SourceCandidate<RowID>] {
        var candidates: [SourceCandidate<RowID>] = []
        for key in tableRecency.reversed() where isCollisionFamily(key, of: base) {
            guard let source = tableEntries[key]?.value as? AutoChartPreparedSource<RowID>
            else { continue }
            candidates.append(
                SourceCandidate(
                    identity: SourceCandidateIdentity(
                        key: key,
                        source: ObjectIdentifier(source),
                        origin: .table),
                    source: source))
        }
        for (key, box) in analysisEntries where isCollisionFamily(key.table, of: base) {
            guard let analysis = box.value as? AutoChartCachedAnalysis<RowID> else { continue }
            candidates.append(
                SourceCandidate(
                    identity: SourceCandidateIdentity(
                        key: key.table,
                        source: ObjectIdentifier(analysis.source),
                        origin: .analysis(key)),
                    source: analysis.source))
        }
        for (key, box) in chartEntries where isCollisionFamily(key.table, of: base) {
            guard let source = box.sharedObject as? AutoChartPreparedSource<RowID> else {
                continue
            }
            candidates.append(
                SourceCandidate(
                    identity: SourceCandidateIdentity(
                        key: key.table,
                        source: ObjectIdentifier(source),
                        origin: .chart(key)),
                    source: source))
        }
        return candidates
    }

    private func finishUnkeyedSourceLookup<RowID: Hashable & Sendable>(
        observed: Set<SourceCandidateIdentity>,
        matching: SourceCandidate<RowID>?,
        collisionBase: TableKey,
        preferredKey: TableKey,
        requestToken: RequestToken
    ) -> SourceResolution<RowID>? {
        let current: [SourceCandidate<RowID>] = sourceCandidates(
            inCollisionFamilyOf: collisionBase)
        guard Set(current.map(\.identity)) == observed else { return nil }

        if let matching {
            switch matching.identity.origin {
            case .table:
                statistics.tables.hits += 1
                touch(matching.identity.key, in: &tableRecency)
            case .analysis(let key):
                statistics.analyses.hits += 1
                touch(key, in: &analysisRecency)
            case .chart(let key):
                statistics.preparedCharts.hits += 1
                touch(key, in: &chartRecency)
            }
            if isCurrentCacheEpoch(requestToken),
                tableEntries[matching.source.key] == nil
            {
                insertTable(matching.source)
            }
            return SourceResolution(
                source: matching.source,
                tableKey: matching.source.key)
        }

        statistics.tables.misses += 1
        let tableKey = isTableKeyRetained(inCollisionFamilyOf: preferredKey)
            ? TableKey(
                rowIDType: preferredKey.rowIDType,
                tableType: preferredKey.tableType,
                contentIdentity: preferredKey.contentIdentity
                    + ":collision:\(UUID().uuidString)")
            : preferredKey
        return SourceResolution(source: nil, tableKey: tableKey)
    }

    private func insertTableIfCurrent<RowID: Hashable & Sendable>(
        _ source: AutoChartPreparedSource<RowID>,
        requestToken: RequestToken
    ) {
        guard isCurrentCacheEpoch(requestToken) else { return }
        insertTable(source)
    }

    private func cachedAnalysis<RowID: Hashable & Sendable>(
        for key: AnalysisKey
    ) -> AutoChartCachedAnalysis<RowID>? {
        if let cached = analysisEntries[key]?.value as? AutoChartCachedAnalysis<RowID> {
            statistics.analyses.hits += 1
            touch(key, in: &analysisRecency)
            return cached
        }
        statistics.analyses.misses += 1
        return nil
    }

    private func insertAnalysisIfCurrent<RowID: Hashable & Sendable>(
        _ analysis: AutoChartCachedAnalysis<RowID>,
        for key: AnalysisKey,
        requestToken: RequestToken
    ) {
        guard isCurrentCacheEpoch(requestToken) else { return }
        insertAnalysis(analysis, for: key)
    }

    private func releaseWaiter(
        _ key: RequestKey,
        flightID: UUID,
        waiterToken: UUID,
        cancelWhenEmpty: Bool
    ) {
        guard var flight = inFlightAnalyses[key], flight.id == flightID else { return }
        guard flight.waiterTokens.remove(waiterToken) != nil else { return }
        if flight.waiterTokens.isEmpty {
            if cancelWhenEmpty { flight.task.cancel() }
            inFlightAnalyses.removeValue(forKey: key)
        } else {
            inFlightAnalyses[key] = flight
        }
    }

    private func isCollisionFamily(_ candidate: TableKey, of base: TableKey) -> Bool {
        candidate.rowIDType == base.rowIDType
            && candidate.tableType == base.tableType
            && (candidate.contentIdentity == base.contentIdentity
                || candidate.contentIdentity.hasPrefix(base.contentIdentity + ":collision:"))
    }

    private func isTableKeyRetained(inCollisionFamilyOf base: TableKey) -> Bool {
        tableEntries.keys.contains { isCollisionFamily($0, of: base) }
            || analysisEntries.keys.contains { isCollisionFamily($0.table, of: base) }
            || chartEntries.keys.contains { isCollisionFamily($0.table, of: base) }
    }

    /// - Parameter requestToken: The token of an enclosing analyze request,
    ///   when this preparation is part of one. Preparation started on its own
    ///   observes the cache state at the moment it begins; preparation folded
    ///   into an analyze inherits that request's, so a trim mid-analyze also
    ///   stops the analysis's primary chart from repopulating the cache.
    nonisolated func prepare<RowID: Hashable & Sendable>(
        _ recommendation: AutoChartRecommendation,
        source: AutoChartPreparedSource<RowID>,
        requestToken: RequestToken? = nil
    ) async throws -> AutoChartPreparedChart<RowID> {
        try Task.checkCancellation()
        let key = ChartKey(table: source.key, specificationID: recommendation.specification.id)
        let registration = await registerChartPreparation(
            recommendation,
            source: source,
            key: key,
            requestToken: requestToken)
        let box: AutoChartAnyCacheBox
        switch registration {
        case .cached(let cached):
            box = cached
        case .inFlight(let task):
            box = try await task.value
        }
        try Task.checkCancellation()
        guard let prepared = box.value as? AutoChartPreparedChart<RowID> else {
            preconditionFailure("Coalesced chart preparation row-ID type mismatch.")
        }
        return adapted(prepared, to: recommendation, source: source)
    }

    private func registerChartPreparation<RowID: Hashable & Sendable>(
        _ recommendation: AutoChartRecommendation,
        source: AutoChartPreparedSource<RowID>,
        key: ChartKey,
        requestToken: RequestToken?
    ) -> ChartPreparationRegistration {
        if let cached = chartEntries[key]?.value as? AutoChartPreparedChart<RowID> {
            statistics.preparedCharts.hits += 1
            touch(key, in: &chartRecency)
            return .cached(AutoChartAnyCacheBox(cached, cost: 0))
        }
        if let existing = inFlightCharts[key] {
            return .inFlight(existing.task)
        }
        statistics.preparedCharts.misses += 1
        let flightID = UUID()
        let preparedEpoch = requestToken?.cacheEpoch ?? cacheEpoch
        let task = Task.detached {
            [recommendation, source, key, flightID, preparedEpoch] in
            do {
                try Task.checkCancellation()
        let core = AutoChartRenderCore.prepare(
            snapshot: source.snapshot,
            profiles: source.profiles,
            contentFingerprint: source.contentFingerprint,
            estimatedStorageCost: source.estimatedStorageCost,
            recommendation: recommendation)
        guard core.validation.isValid else {
            throw AutoChartPreparationError.invalidSpecification(core.validation)
        }
        try Task.checkCancellation()
        let prepared = AutoChartPreparedChart(
            source: source,
            recommendation: recommendation,
            core: core)
                let stored = await self.storePreparedChart(
            prepared,
            key: key,
                    cost: self.estimatedChartCost(core),
            source: source,
                    cacheEpoch: preparedEpoch)
                await self.finishChartPreparation(key: key, flightID: flightID)
                return AutoChartAnyCacheBox(stored, cost: 0)
            } catch {
                await self.finishChartPreparation(key: key, flightID: flightID)
                throw error
    }
        }
        inFlightCharts[key] = InFlightChart(id: flightID, task: task)
        return .inFlight(task)
    }

    private func finishChartPreparation(key: ChartKey, flightID: UUID) {
        guard inFlightCharts[key]?.id == flightID else { return }
        inFlightCharts.removeValue(forKey: key)
    }

    private func storePreparedChart<RowID: Hashable & Sendable>(
        _ prepared: AutoChartPreparedChart<RowID>,
        key: ChartKey,
        cost: Int,
        source: AutoChartPreparedSource<RowID>,
        cacheEpoch preparedEpoch: UInt64
    ) -> AutoChartPreparedChart<RowID> {
        if let cached = chartEntries[key]?.value as? AutoChartPreparedChart<RowID> {
            touch(key, in: &chartRecency)
            return adapted(cached, to: prepared.recommendation, source: source)
        }
        if preparedEpoch == cacheEpoch {
            insertChart(prepared, key: key, cost: cost, source: source)
        }
        return prepared
    }

    /// Rebuilds a cached chart around the requesting recommendation when the
    /// cached one differs. The chart cache is keyed by table and specification
    /// only, so a caller-provided specification and an engine recommendation
    /// share prepared data but must keep their own score, rationale, and
    /// diagnostics.
    private nonisolated func adapted<RowID: Hashable & Sendable>(
        _ cached: AutoChartPreparedChart<RowID>,
        to recommendation: AutoChartRecommendation,
        source: AutoChartPreparedSource<RowID>
    ) -> AutoChartPreparedChart<RowID> {
        guard cached.recommendation != recommendation else { return cached }
        return AutoChartPreparedChart(
            source: source,
            recommendation: recommendation,
            core: cached.core)
    }

    public func trim(to target: AutoChartCacheTrimTarget) {
        switch target {
        case .minimum:
            cacheEpoch &+= 1
            statistics.tables.evictions += tableEntries.count
            statistics.analyses.evictions += analysisEntries.count
            statistics.preparedCharts.evictions += chartEntries.count
            tableEntries.removeAll(keepingCapacity: false)
            tableRecency.removeAll(keepingCapacity: false)
            analysisEntries.removeAll(keepingCapacity: false)
            analysisRecency.removeAll(keepingCapacity: false)
            chartEntries.removeAll(keepingCapacity: false)
            chartRecency.removeAll(keepingCapacity: false)
        case .configuredLimits:
            trimLocked()
        }
    }

    public func removeAll() {
        generation &+= 1
        cacheEpoch &+= 1
        for flight in inFlightAnalyses.values { flight.task.cancel() }
        for flight in inFlightCharts.values { flight.task.cancel() }
        inFlightAnalyses.removeAll(keepingCapacity: false)
        inFlightCharts.removeAll(keepingCapacity: false)
        tableEntries.removeAll(keepingCapacity: false)
        tableRecency.removeAll(keepingCapacity: false)
        analysisEntries.removeAll(keepingCapacity: false)
        analysisRecency.removeAll(keepingCapacity: false)
        chartEntries.removeAll(keepingCapacity: false)
        chartRecency.removeAll(keepingCapacity: false)
        statistics = .init()
    }

    private nonisolated func makeAnalysis<RowID: Hashable & Sendable>(
        _ cached: AutoChartCachedAnalysis<RowID>
    ) -> AutoChartAnalysis<RowID> {
        AutoChartAnalysis(
            outcome: cached.outcome,
            profiles: cached.profiles,
            diagnostics: cached.diagnostics,
            decisionTrace: cached.trace,
            primaryChart: cached.primary,
            provider: AutoChartAnalysisPreparationProvider(
                analyzer: self,
                source: cached.source,
                recommendations: cached.recommendations))
    }

    private func insertTable<RowID>(_ source: AutoChartPreparedSource<RowID>) {
        guard configuration.tables.maximumEntries > 0,
            configuration.maximumRetainedCost > 0,
            source.cost <= configuration.maximumRetainedCost
        else { return }
        tableEntries[source.key] = AutoChartAnyCacheBox(
            source,
            cost: 0,
            sharedObject: source,
            sharedObjectCost: source.cost)
        touch(source.key, in: &tableRecency)
        trimLocked()
    }

    private func insertAnalysis<RowID>(
        _ analysis: AutoChartCachedAnalysis<RowID>,
        for key: AnalysisKey
    ) {
        let cost = 256 + analysis.recommendations.count * 512
            + analysis.profiles.count * 32
            + (analysis.primary.map { estimatedChartCost($0.core) } ?? 0)
        // Admitting an entry that cannot coexist with its shared source would
        // make the cost trim evict every other resident entry before finally
        // evicting this one, draining the cache on every oversized analysis.
        guard configuration.analyses.maximumEntries > 0,
            configuration.maximumRetainedCost > 0,
            adding(cost, to: analysis.source.cost) <= configuration.maximumRetainedCost
        else { return }
        analysisEntries[key] = AutoChartAnyCacheBox(
            analysis,
            cost: cost,
            sharedObject: analysis.source,
            sharedObjectCost: analysis.source.cost)
        touch(key, in: &analysisRecency)
        trimLocked()
    }

    private func insertChart<RowID>(
        _ chart: AutoChartPreparedChart<RowID>,
        key: ChartKey,
        cost: Int,
        source: AutoChartPreparedSource<RowID>
    ) {
        guard configuration.preparedCharts.maximumEntries > 0,
            configuration.maximumRetainedCost > 0,
            adding(cost, to: source.cost) <= configuration.maximumRetainedCost
        else { return }
        chartEntries[key] = AutoChartAnyCacheBox(
            chart,
            cost: cost,
            sharedObject: source,
            sharedObjectCost: source.cost)
        touch(key, in: &chartRecency)
        trimLocked()
    }

    private nonisolated func estimatedChartCost(_ core: AutoChartRenderCore) -> Int {
        512 + core.data.count * 320
    }

    private func totalCost() -> Int {
        var result = 0
        var sharedObjects: Set<ObjectIdentifier> = []
        let boxes = Array(tableEntries.values)
            + Array(analysisEntries.values)
            + Array(chartEntries.values)
        for box in boxes {
            result = adding(box.cost, to: result)
            if let identifier = box.sharedObjectIdentifier,
                sharedObjects.insert(identifier).inserted
            {
                result = adding(box.sharedObjectCost, to: result)
            }
        }
        return result
    }

    private func layerCost<Boxes: Sequence>(_ boxes: Boxes) -> Int
    where Boxes.Element == AutoChartAnyCacheBox {
        var result = 0
        var sharedObjects: Set<ObjectIdentifier> = []
        for box in boxes {
            result = adding(box.cost, to: result)
            if let identifier = box.sharedObjectIdentifier,
                sharedObjects.insert(identifier).inserted
            {
                result = adding(box.sharedObjectCost, to: result)
            }
        }
        return result
    }

    private func adding(_ amount: Int, to current: Int) -> Int {
        let (result, overflow) = current.addingReportingOverflow(amount)
        return overflow ? Int.max : result
    }

    private func trimLocked() {
        while tableRecency.count > configuration.tables.maximumEntries {
            evictTable(tableRecency[0])
        }
        while analysisRecency.count > configuration.analyses.maximumEntries {
            evictAnalysis(analysisRecency[0])
        }
        while chartRecency.count > configuration.preparedCharts.maximumEntries {
            evictChart(chartRecency[0])
        }
        while totalCost() > configuration.maximumRetainedCost {
            if let chart = chartRecency.first { evictChart(chart) }
            else if let analysis = analysisRecency.first { evictAnalysis(analysis) }
            else if let table = tableRecency.first { evictTable(table) }
            else { break }
        }
    }

    private func evictTable(_ key: TableKey) {
        guard tableEntries.removeValue(forKey: key) != nil else { return }
        tableRecency.removeAll { $0 == key }
        statistics.tables.evictions += 1
        for analysis in analysisRecency.filter({ $0.table == key }) { evictAnalysis(analysis) }
        for chart in chartRecency.filter({ $0.table == key }) { evictChart(chart) }
    }

    private func evictAnalysis(_ key: AnalysisKey) {
        guard analysisEntries.removeValue(forKey: key) != nil else { return }
        analysisRecency.removeAll { $0 == key }
        statistics.analyses.evictions += 1
    }

    private func evictChart(_ key: ChartKey) {
        guard chartEntries.removeValue(forKey: key) != nil else { return }
        chartRecency.removeAll { $0 == key }
        statistics.preparedCharts.evictions += 1
    }

    private func touch<Key: Hashable>(_ key: Key, in recency: inout [Key]) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
