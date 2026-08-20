import Foundation

/// Count and approximate retained-byte limit for one analyzer layer.
public struct AutoChartCacheLimit: Hashable, Codable, Sendable {
    public var maximumEntries: Int

    public init(maximumEntries: Int) {
        self.maximumEntries = max(0, maximumEntries)
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
    public var maximumRetainedCost: Int

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
}

public enum AutoChartCacheTrimTarget: Hashable, Codable, Sendable {
    case minimum
    case configuredLimits
}

public struct AutoChartCacheLayerStatistics: Hashable, Codable, Sendable {
    public var entries: Int
    public var retainedCost: Int
    public var hits: Int
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
    let cost: Int

    init(
        key: AutoChartAnalyzer.TableKey,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        rowIDs: [RowID]
    ) {
        self.key = key
        self.snapshot = snapshot
        self.profiles = profiles
        self.rowIDs = rowIDs
        self.cost = snapshot.estimatedStorageCost + profiles.count * 192
    }
}

/// Immutable mark preparation consumed by ``AutoChartPlot`` and ``AutoChartView``.
public struct AutoChartPreparedChart<RowID: Hashable & Sendable>: Sendable {
    public let recommendation: AutoChartRecommendation
    public let validation: AutoChartValidationResult
    public let marks: [AutoChartPreparedMark<RowID>]
    public var diagnostics: [AutoChartDiagnostic] {
        recommendation.diagnostics + validation.issues.filter { $0.severity == .warning }
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

    public func validate(
        _ specification: AutoChartSpecification
    ) -> AutoChartValidationResult {
        AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: provider.source.snapshot,
            profiles: provider.source.profiles)
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

    private struct ChartKey: Hashable, Sendable {
        var table: TableKey
        var specification: AutoChartSpecification
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

    private let configuration: AutoChartAnalyzerConfiguration
    private var tableEntries: [TableKey: AutoChartAnyCacheBox] = [:]
    private var tableRecency: [TableKey] = []
    private var analysisEntries: [AnalysisKey: AutoChartAnyCacheBox] = [:]
    private var analysisRecency: [AnalysisKey] = []
    private var chartEntries: [ChartKey: AutoChartAnyCacheBox] = [:]
    private var chartRecency: [ChartKey] = []
    private var inFlightAnalyses: [RequestKey: InFlightAnalysis] = [:]
    private var statistics = AutoChartCacheStatistics()
    private var generation: UInt64 = 0

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

    public func analyze<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext = .init(),
        options: AutoChartOptions = .init()
    ) async throws -> AutoChartAnalysis<Table.RowID> {
        statistics.inFlightRequests += 1
        let requestGeneration = generation
        defer {
            if requestGeneration == generation {
                statistics.inFlightRequests = max(0, statistics.inFlightRequests - 1)
            }
        }
        try Task.checkCancellation()
        let rowIDs = table.chartRows.map(\.chartRowID)
        let unkeyedSnapshot: AutoChartSnapshot?
        let unkeyedFingerprint: Int?
        let contentIdentity: String
        if table.chartDataKey == nil {
            let snapshot = try AutoChartSnapshot(validating: table)
            try Task.checkCancellation()
            let fingerprint = try snapshot.contentFingerprintCheckingCancellation()
            unkeyedSnapshot = snapshot
            unkeyedFingerprint = fingerprint
            contentIdentity = "fingerprint:\(fingerprint)"
        } else {
            unkeyedSnapshot = nil
            unkeyedFingerprint = nil
            contentIdentity = table.chartDataKey.map {
                "key:\($0.identity):\($0.revision)"
            } ?? "unreachable"
        }
        let prefix = TableKey(
            rowIDType: String(reflecting: Table.RowID.self),
            tableType: String(reflecting: Table.self),
            contentIdentity: contentIdentity)
        let baseRequestKey = RequestKey(
            table: prefix,
            context: context,
            options: options,
            policyVersion: AutoTableCharts.recommendationPolicyVersion)
        var requestKey = baseRequestKey
        if let snapshot = unkeyedSnapshot {
            var matchingKey: RequestKey?
            for (candidateKey, flight) in inFlightAnalyses where
                candidateKey.context == context
                    && candidateKey.options == options
                    && candidateKey.policyVersion == AutoTableCharts.recommendationPolicyVersion
                    && isCollisionFamily(candidateKey.table, of: prefix)
            {
                if try flight.unkeyedSnapshot?
                    .hasSameContentCheckingCancellation(as: snapshot) == true,
                    flight.unkeyedRowIDs?.matches(rowIDs) == true
                {
                    matchingKey = candidateKey
                    break
                }
            }
            if let matchingKey {
                requestKey = matchingKey
            } else if inFlightAnalyses[baseRequestKey] != nil {
                // A content hash is only a lookup accelerator. Keep unequal
                // snapshots in distinct request-key collision buckets.
                requestKey.table.contentIdentity += ":collision:\(UUID().uuidString)"
            }
        }
        let finalRequestKey = requestKey
        let waiterToken = UUID()
        let flightID: UUID
        let task: Task<AutoChartAnyCacheBox, Error>
        if var existing = inFlightAnalyses[finalRequestKey] {
            existing.waiterTokens.insert(waiterToken)
            inFlightAnalyses[finalRequestKey] = existing
            flightID = existing.id
            task = existing.task
        } else {
            flightID = UUID()
            task = Task {
                [table, context, options, rowIDs, unkeyedSnapshot, unkeyedFingerprint] in
                await Task.yield()
                let analysis = try await self.analyzeUncoalesced(
                    table,
                    context: context,
                    options: options,
                    rowIDs: rowIDs,
                    precomputedSnapshot: unkeyedSnapshot,
                    precomputedFingerprint: unkeyedFingerprint)
                return AutoChartAnyCacheBox(analysis, cost: 0)
            }
            inFlightAnalyses[finalRequestKey] = InFlightAnalysis(
                id: flightID,
                task: task,
                waiterTokens: [waiterToken],
                unkeyedSnapshot: unkeyedSnapshot,
                unkeyedRowIDs: unkeyedSnapshot.map { _ in AutoChartAnyRowIDs(rowIDs) })
        }
        do {
            let box = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task {
                    await self.releaseWaiter(
                        finalRequestKey,
                        flightID: flightID,
                        waiterToken: waiterToken,
                        cancelWhenEmpty: true)
                }
            }
            releaseWaiter(
                finalRequestKey,
                flightID: flightID,
                waiterToken: waiterToken,
                cancelWhenEmpty: false)
            try Task.checkCancellation()
            guard let analysis = box.value as? AutoChartAnalysis<Table.RowID> else {
                preconditionFailure("Coalesced analysis row-ID type mismatch.")
            }
            return analysis
        } catch {
            releaseWaiter(
                finalRequestKey,
                flightID: flightID,
                waiterToken: waiterToken,
                cancelWhenEmpty: false)
            throw error
        }
    }

    private func analyzeUncoalesced<Table: AutoChartTable>(
        _ table: Table,
        context: AutoChartContext,
        options: AutoChartOptions,
        rowIDs: [Table.RowID],
        precomputedSnapshot: AutoChartSnapshot?,
        precomputedFingerprint: Int?
    ) async throws -> AutoChartAnalysis<Table.RowID> {
        let requestGeneration = generation
        let keyPrefix = TableKey(
            rowIDType: String(reflecting: Table.RowID.self),
            tableType: String(reflecting: Table.self),
            contentIdentity: table.chartDataKey.map {
                "key:\($0.identity):\($0.revision)"
            } ?? precomputedFingerprint.map {
                "fingerprint:\($0)"
            } ?? "pending")

        var source: AutoChartPreparedSource<Table.RowID>?
        if table.chartDataKey != nil,
            let cached = tableEntries[keyPrefix]?.value as? AutoChartPreparedSource<Table.RowID>
        {
            statistics.tables.hits += 1
            touch(keyPrefix, in: &tableRecency)
            source = cached
        } else if table.chartDataKey != nil {
            statistics.tables.misses += 1
        }

        if source == nil {
            let snapshot: AutoChartSnapshot
            if let precomputedSnapshot {
                snapshot = precomputedSnapshot
            } else {
                snapshot = try AutoChartSnapshot(validating: table)
            }
            try Task.checkCancellation()
            let tableKey: TableKey
            if table.chartDataKey == nil {
                let fingerprint: Int
                if let precomputedFingerprint {
                    fingerprint = precomputedFingerprint
                } else {
                    fingerprint = try snapshot.contentFingerprintCheckingCancellation()
                }
                let baseTableKey = TableKey(
                    rowIDType: keyPrefix.rowIDType,
                    tableType: keyPrefix.tableType,
                    contentIdentity: "fingerprint:\(fingerprint)")
                var matchingKey: TableKey?
                for candidateKey in Array(tableRecency.reversed())
                    where isCollisionFamily(candidateKey, of: baseTableKey)
                {
                    guard let cached = tableEntries[candidateKey]?.value
                        as? AutoChartPreparedSource<Table.RowID>
                    else { continue }
                    if try cached.snapshot.hasSameContentCheckingCancellation(as: snapshot),
                        cached.rowIDs == rowIDs
                    {
                        matchingKey = candidateKey
                        statistics.tables.hits += 1
                        touch(candidateKey, in: &tableRecency)
                        source = cached
                        break
                    }
                }
                if source == nil {
                    statistics.tables.misses += 1
                    for (candidateKey, box) in analysisEntries
                        where isCollisionFamily(candidateKey.table, of: baseTableKey)
                    {
                        guard let cached = box.value
                            as? AutoChartCachedAnalysis<Table.RowID>
                        else { continue }
                        if try cached.source.snapshot
                            .hasSameContentCheckingCancellation(as: snapshot),
                            cached.source.rowIDs == rowIDs
                        {
                            matchingKey = candidateKey.table
                            source = cached.source
                            break
                        }
                    }
                }
                if source == nil {
                    for (candidateKey, box) in chartEntries
                        where isCollisionFamily(candidateKey.table, of: baseTableKey)
                    {
                        guard let cachedSource = box.sharedObject
                            as? AutoChartPreparedSource<Table.RowID>
                        else { continue }
                        if try cachedSource.snapshot
                            .hasSameContentCheckingCancellation(as: snapshot),
                            cachedSource.rowIDs == rowIDs
                        {
                            matchingKey = candidateKey.table
                            source = cachedSource
                            break
                        }
                    }
                }
                tableKey = matchingKey
                    ?? (isTableKeyRetained(inCollisionFamilyOf: baseTableKey)
                        ? TableKey(
                            rowIDType: baseTableKey.rowIDType,
                            tableType: baseTableKey.tableType,
                            contentIdentity: baseTableKey.contentIdentity
                                + ":collision:\(UUID().uuidString)")
                        : baseTableKey)
                if requestGeneration == generation,
                    tableEntries[tableKey] == nil,
                    let source
                {
                    insertTable(source)
                }
            } else {
                tableKey = keyPrefix
            }
            if source == nil {
                let profiles = try AutoChartProfiler.profileIndexCheckingCancellation(snapshot)
                source = AutoChartPreparedSource(
                    key: tableKey,
                    snapshot: snapshot,
                    profiles: profiles,
                    rowIDs: rowIDs)
                if requestGeneration == generation, let source {
                    insertTable(source)
                }
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
        if let cached = analysisEntries[analysisKey]?.value
            as? AutoChartCachedAnalysis<Table.RowID>
        {
            statistics.analyses.hits += 1
            touch(analysisKey, in: &analysisRecency)
            return makeAnalysis(cached)
        }
        statistics.analyses.misses += 1
        try Task.checkCancellation()

        let set = AutoChartRecommendationEngine.recommendations(
            snapshot: source.snapshot,
            context: context,
            options: options)
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
        try Task.checkCancellation()
        if let first = recommendations.first {
            primary = try await prepare(first, source: source)
        } else {
            primary = nil
        }
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
        if requestGeneration == generation { insertAnalysis(cached, for: analysisKey) }
        return makeAnalysis(cached)
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

    func prepare<RowID: Hashable & Sendable>(
        _ recommendation: AutoChartRecommendation,
        source: AutoChartPreparedSource<RowID>
    ) async throws -> AutoChartPreparedChart<RowID> {
        try Task.checkCancellation()
        let key = ChartKey(table: source.key, specification: recommendation.specification)
        if let cached = chartEntries[key]?.value as? AutoChartPreparedChart<RowID> {
            statistics.preparedCharts.hits += 1
            touch(key, in: &chartRecency)
            return cached
        }
        statistics.preparedCharts.misses += 1
        let core = AutoChartRenderCore.prepare(
            snapshot: source.snapshot,
            profiles: source.profiles,
            recommendation: recommendation)
        guard core.validation.isValid else {
            throw AutoChartPreparationError.invalidSpecification(core.validation)
        }
        try Task.checkCancellation()
        let prepared = AutoChartPreparedChart(
            source: source,
            recommendation: recommendation,
            core: core)
        insertChart(
            prepared,
            key: key,
            cost: estimatedChartCost(core),
            source: source)
        return prepared
    }

    public func trim(to target: AutoChartCacheTrimTarget) {
        switch target {
        case .minimum:
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
        for flight in inFlightAnalyses.values { flight.task.cancel() }
        inFlightAnalyses.removeAll(keepingCapacity: false)
        tableEntries.removeAll(keepingCapacity: false)
        tableRecency.removeAll(keepingCapacity: false)
        analysisEntries.removeAll(keepingCapacity: false)
        analysisRecency.removeAll(keepingCapacity: false)
        chartEntries.removeAll(keepingCapacity: false)
        chartRecency.removeAll(keepingCapacity: false)
        statistics = .init()
    }

    private func makeAnalysis<RowID: Hashable & Sendable>(
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
        guard configuration.analyses.maximumEntries > 0 else { return }
        let cost = 256 + analysis.recommendations.count * 512 + analysis.profiles.count * 32
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
            cost <= configuration.maximumRetainedCost
        else { return }
        chartEntries[key] = AutoChartAnyCacheBox(
            chart,
            cost: cost,
            sharedObject: source,
            sharedObjectCost: source.cost)
        touch(key, in: &chartRecency)
        trimLocked()
    }

    private func estimatedChartCost(_ core: AutoChartRenderCore) -> Int {
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
