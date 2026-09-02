import Dispatch
import Foundation
import Testing

@testable import AutoTableCharts

private let v2Category = AutoChartColumn(
    id: "category",
    name: "Category",
    hints: .init(semanticType: .nominal, role: .dimension))
private let v2Measure = AutoChartColumn(
    id: "measure",
    name: "Value",
    hints: .init(
        semanticType: .quantitative,
        role: .measure,
        unit: .currency(code: "USD"),
        measureSemantics: .init(source: .rowLevel, rollup: .additive)))

private let v2Date = AutoChartColumn(
    id: "date",
    name: "Observed",
    hints: .init(semanticType: .temporal, role: .dimension))

private struct DuplicateIDRow: AutoChartRow {
    let chartRowID: Int
    let value: Double

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        columnID == v2Measure.id ? .double(value) : .null
    }
}

private struct DuplicateIDTable: AutoChartTable {
    let chartColumns = [v2Measure]
    let chartRows: [DuplicateIDRow]
    let chartMetadata = AutoChartTableMetadata()
}

private enum PreparationGateError: Error {
    case timedOutWaitingForPreparation
}

private actor OneShotPreparationGate {
    private struct EnteredWaiter {
        var continuation: CheckedContinuation<Void, any Error>
        var timeoutTask: Task<Void, Never>
    }

    private let timeout: Duration
    private var armed = false
    private var blocked = false
    private var releaseToken: UUID?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseTimeoutTask: Task<Void, Never>?
    private var enteredWaiters: [UUID: EnteredWaiter] = [:]
    private var cancelledWaitAttemptCount = 0

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    func arm() -> Bool {
        guard !blocked && releaseToken == nil && releaseContinuation == nil
            && releaseTimeoutTask == nil
        else {
            Issue.record("The one-shot preparation gate cannot be re-armed while blocked.")
            releaseAfterInvariantFailure()
            return false
        }
        armed = true
        return true
    }

    func waitWhenArmed() async {
        guard armed else { return }
        guard !Task.isCancelled else {
            cancelledWaitAttemptCount += 1
            cancelEnteredWaiters()
            return
        }
        armed = false
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    armed = true
                    cancelledWaitAttemptCount += 1
                    cancelEnteredWaiters()
                    continuation.resume()
                    return
                }
                guard releaseToken == nil && releaseContinuation == nil
                    && releaseTimeoutTask == nil
                else {
                    Issue.record("A preparation release is already pending.")
                    releaseAfterInvariantFailure()
                    continuation.resume()
                    return
                }
                releaseToken = token
                releaseContinuation = continuation
                releaseTimeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self.releasePreparation(token: token)
                }
                blocked = true
                let waiters = Array(enteredWaiters.values)
                enteredWaiters.removeAll()
                waiters.forEach {
                    $0.timeoutTask.cancel()
                    $0.continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.releasePreparation(token: token) }
        }
    }

    func waitUntilBlocked(
        timeout waiterTimeout: Duration? = nil,
        onWaiting: (@Sendable () -> Void)? = nil
    ) async throws {
        guard !blocked else { return }
        let token = UUID()
        let effectiveTimeout = waiterTimeout ?? timeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !blocked else {
                    continuation.resume()
                    return
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: effectiveTimeout)
                    } catch {
                        return
                    }
                    self.failEnteredWaiter(token: token)
                }
                enteredWaiters[token] = EnteredWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask)
                onWaiting?()
            }
        } onCancel: {
            Task { await self.cancelEnteredWaiter(token: token) }
        }
    }

    func resume() {
        guard let releaseToken else { return }
        releasePreparation(token: releaseToken)
    }

    private func releasePreparation(token: UUID) {
        guard releaseToken == token else { return }
        blocked = false
        releaseToken = nil
        releaseTimeoutTask?.cancel()
        releaseTimeoutTask = nil
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    private func releaseAfterInvariantFailure() {
        armed = false
        blocked = false
        releaseToken = nil
        releaseTimeoutTask?.cancel()
        releaseTimeoutTask = nil
        let continuation = releaseContinuation
        releaseContinuation = nil
        cancelEnteredWaiters()
        continuation?.resume()
    }

    private func failEnteredWaiter(token: UUID) {
        guard enteredWaiters[token] != nil else { return }
        armed = false
        let waiters = Array(enteredWaiters.values)
        enteredWaiters.removeAll()
        waiters.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(
                throwing: PreparationGateError.timedOutWaitingForPreparation)
        }
    }

    private func cancelEnteredWaiter(token: UUID) {
        guard let waiter = enteredWaiters.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelEnteredWaiters() {
        let tokens = Array(enteredWaiters.keys)
        tokens.forEach {
            cancelEnteredWaiter(token: $0)
        }
    }

    var activeTimeoutTaskCount: Int {
        (releaseTimeoutTask == nil ? 0 : 1) + enteredWaiters.count
    }

    var isArmed: Bool { armed }

    var cancelledAttemptCount: Int { cancelledWaitAttemptCount }
}

private actor InvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func blockingWaitFinishesPromptly(
    _ wait: @escaping @Sendable (DispatchTime) -> Bool
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: wait(.now() + 5))
        }
    }
}

private func receivesSignalPromptly(_ semaphore: DispatchSemaphore) async -> Bool {
    await blockingWaitFinishesPromptly { deadline in
        semaphore.wait(timeout: deadline) == .success
    }
}

private func receivesSignalsPromptly(
    _ semaphore: DispatchSemaphore,
    count: Int
) async -> Bool {
    guard count > 0 else { return true }
    return await blockingWaitFinishesPromptly { deadline in
        for _ in 0..<count {
            guard semaphore.wait(timeout: deadline) == .success else {
                return false
            }
        }
        return true
    }
}

private func finishesPromptly(_ group: DispatchGroup) async -> Bool {
    await blockingWaitFinishesPromptly { deadline in
        group.wait(timeout: deadline) == .success
    }
}

private final class ChartRowsReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func read<Row>(_ rows: [Row]) -> [Row] {
        lock.lock()
        value += 1
        lock.unlock()
        return rows
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct CountingChartRowsTable: AutoChartTable {
    let rows: [DuplicateIDRow]
    let counter: ChartRowsReadCounter
    let chartColumns = [v2Measure]
    let chartMetadata = AutoChartTableMetadata()
    var chartDataKey: AutoChartDataKey? = nil

    var chartRows: [DuplicateIDRow] { counter.read(rows) }
}

@Suite struct V2DatasetTests {
    @Test func datasetsRejectEveryStructuralMismatch() {
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartDataset<Int>(
                columns: [v2Category, v2Measure],
                rows: [[.text("A")]])
        }
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartDataset<String>(
                columns: [v2Category],
                rows: [[.text("A")]],
                rowIDs: [])
        }
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartDataset<Int>(
                columns: [v2Category, v2Category],
                rows: [[.text("A"), .text("A")]])
        }
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartDataset<Int>(
                columns: [v2Category],
                rows: [[.text("A")], [.text("B")]],
                rowIDs: [7, 7])
        }
    }

    @Test func arbitraryTablesRejectDuplicateTypedRowIDs() {
        let input = DuplicateIDTable(chartRows: [
            .init(chartRowID: 4, value: 1),
            .init(chartRowID: 4, value: 2),
        ])
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartSnapshot(validating: input)
        }
    }

    @Test func analyzerReadsChartRowsOncePerAttempt() async throws {
        let counter = ChartRowsReadCounter()
        let input = CountingChartRowsTable(
            rows: [
                .init(chartRowID: 1, value: 10),
                .init(chartRowID: 2, value: 20),
            ],
            counter: counter)

        let analysis = try await AutoChartAnalyzer().analyze(input)

        #expect(analysis.primaryChart != nil)
        #expect(counter.count == 1)
    }

    @Test func integerAndUUIDLineageReachPreparedMarks() async throws {
        let integers = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let integerAnalysis = try await AutoChartAnalyzer().analyze(integers)
        let integerIDs = Set(integerAnalysis.primaryChart?.marks.flatMap(\.sourceRowIDs) ?? [])
        #expect(integerIDs == [0, 1])

        let first = UUID()
        let second = UUID()
        let uuids = try AutoChartDataset<UUID>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]],
            rowIDs: [first, second])
        let uuidAnalysis = try await AutoChartAnalyzer().analyze(uuids)
        let uuidIDs = Set(uuidAnalysis.primaryChart?.marks.flatMap(\.sourceRowIDs) ?? [])
        #expect(uuidIDs == [first, second])
    }

    @Test func codableDatasetPreservesIDsValuesMetadataAndKey() throws {
        let original = try AutoChartDataset<UUID>(
            columns: [v2Category, v2Measure],
            rows: [[.text("Office"), .double(42)]],
            rowIDs: [UUID()],
            metadata: .init(grain: "asset", provenance: "test"),
            key: .init(identity: "result", revision: "2"))
        let decoded = try JSONDecoder().decode(
            AutoChartDataset<UUID>.self,
            from: JSONEncoder().encode(original))

        #expect(decoded.chartRows.map(\.chartRowID) == original.chartRows.map(\.chartRowID))
        #expect(decoded.chartRows[0].chartValue(for: v2Measure.id) == .double(42))
        #expect(decoded.chartMetadata == original.chartMetadata)
        #expect(decoded.chartDataKey == original.chartDataKey)
    }
}

@Suite struct V2IdentityAndOutcomeTests {
    @Test func specificationIdentityIsStructuralAndTitleIndependent() {
        let first = AutoChartSpecification.bar(
            category: v2Category.id, measure: v2Measure.id, title: "First")
        let second = AutoChartSpecification.bar(
            category: v2Category.id, measure: v2Measure.id, title: "Second")
        #expect(first.id == second.id)
    }

    @Test func recommendationIDUsesTypedEncodingAndDecodesLegacyStrings() throws {
        let specification = AutoChartSpecification.bar(
            category: v2Category.id, measure: v2Measure.id)
        let expected = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: specification.id)
        let typed = try JSONDecoder().decode(
            AutoChartRecommendationID.self,
            from: JSONEncoder().encode(expected))
        #expect(typed == expected)

        let legacy =
            "1:8|3:bar|14:value:category|13:value:measure|3:nil|3:nil|3:nil|3:nil|3:nil|4:none|3:nil|8:vertical|4:none|3:nil|6:source"
        let legacySpecificationID = AutoChartSpecificationID(
            rawValue:
                "3:bar|14:value:category|13:value:measure|3:nil|3:nil|3:nil|3:nil|3:nil|4:none|3:nil|8:vertical|4:none|3:nil|6:source")
        let legacyExpected = AutoChartRecommendationID(
            policyVersion: 8,
            specificationID: legacySpecificationID)
        let decodedLegacy = try JSONDecoder().decode(
            AutoChartRecommendationID.self,
            from: JSONEncoder().encode(legacy))
        #expect(decodedLegacy == legacyExpected)

        let unicodeLegacy = "1:9|5:café"
        let unicodeExpected = AutoChartRecommendationID(
            policyVersion: 9,
            specificationID: AutoChartSpecificationID(rawValue: "5:café"))
        #expect(
            try JSONDecoder().decode(
                AutoChartRecommendationID.self,
                from: JSONEncoder().encode(unicodeLegacy)) == unicodeExpected)
    }

    @Test func resolutionReportsExactAndPolicyDefaulting() async throws {
        #expect(AutoTableCharts.recommendationPolicyVersion == 11)
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let analysis = try await AutoChartAnalyzer().analyze(dataset)
        let primary = try #require(analysis.primaryChart?.recommendation)

        guard case .defaulted(let noPreference, reason: .noPersistedPreference) =
            analysis.resolve(nil)
        else {
            Issue.record("Expected no-preference default")
            return
        }
        #expect(noPreference.id == primary.id)

        guard case .exact(let exact) = analysis.resolve(primary.id) else {
            Issue.record("Expected exact resolution")
            return
        }
        #expect(exact.id == primary.id)

        let stale = AutoChartRecommendationID(
            policyVersion: 10,
            specificationID: primary.specification.id)
        guard case .defaulted(
            let defaulted,
            reason: .policyVersionChanged(let previous, let current)) =
            analysis.resolve(stale)
        else {
            Issue.record("Expected policy-version default")
            return
        }
        #expect(defaulted.id == primary.id)
        #expect(previous == 10)
        #expect(current == 11)

        let absent = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: AutoChartSpecificationID(rawValue: "absent-specification"))
        guard case .defaulted(let unavailable, reason: .specificationUnavailable) =
            analysis.resolve(absent)
        else {
            Issue.record("Expected unavailable-specification default")
            return
        }
        #expect(unavailable.id == primary.id)

        let empty = try AutoChartDataset<Int>(columns: [v2Category], rows: [])
        let fallbackAnalysis = try await AutoChartAnalyzer().analyze(empty)
        guard case .unavailable(let fallback) = fallbackAnalysis.resolve(nil) else {
            Issue.record("Expected unavailable fallback resolution")
            return
        }
        #expect(fallback.message.code == .noChartableRows)
    }

    @Test func emptyDataProducesTypedTableFallback() async throws {
        let dataset = try AutoChartDataset<Int>(columns: [v2Category], rows: [])
        let analysis = try await AutoChartAnalyzer().analyze(dataset)
        guard case .tableFallback(let fallback) = analysis.outcome else {
            Issue.record("Expected table fallback")
            return
        }
        #expect(fallback.message.code == .noChartableRows)
        #expect(analysis.primaryChart == nil)
    }
}

@Suite struct V2InspectionAndFactoryTests {
    @Test func everyRenderableFamilyHasAFactory() {
        let specificationsByFamily: [AutoChartFamily: AutoChartSpecification] = [
            .kpi: .kpi(measure: "m"),
            .bar: .bar(category: "c", measure: "m"),
            .rankedDot: .rankedDot(category: "c", measure: "m"),
            .groupedBar: .groupedBar(category: "c", measure: "m", series: "s"),
            .stackedBar: .stackedBar(category: "c", measure: "m", series: "s"),
            .normalizedBar: .normalizedBar(category: "c", measure: "m", series: "s"),
            .line: .line(x: "x", measure: "m"),
            .pointLine: .pointLine(x: "x", measure: "m"),
            .area: .area(x: "x", measure: "m"),
            .scatter: .scatter(x: "x", y: "y"),
            .bubble: .bubble(x: "x", y: "y", size: "size"),
            .histogram: .histogram(value: "m"),
            .boxPlot: .boxPlot(measure: "m", category: "c"),
            .heatmap: .heatmap(x: "x", y: "y"),
            .donut: .donut(category: "c", measure: "m"),
            .range: .range(label: "c", start: "start", end: "end"),
            .faceted: .faceted(baseFamily: .bar, x: "c", y: "m", facet: "f"),
        ]
        #expect(Set(specificationsByFamily.keys) == Set(AutoChartFamily.allCases))
        #expect(specificationsByFamily[.stackedBar]?.stacking == .standard)
        #expect(specificationsByFamily[.normalizedBar]?.stacking == .normalized)
        #expect(specificationsByFamily[.histogram]?.aggregation == .count)
        #expect(specificationsByFamily[.heatmap]?.aggregation == .count)
    }

    @Test func fullTraceIncludesInferredSemanticsRanksAndExclusions() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let analysis = try await AutoChartAnalyzer().analyze(
            dataset,
            options: .init(maximumRecommendations: 1, includesDecisionTrace: true))
        let trace = try #require(analysis.decisionTrace)
        #expect(trace.inferredSemantics.map(\.columnID) == [v2Category.id, v2Measure.id])
        #expect(trace.candidates.contains {
            if case .recommended = $0.disposition { true } else { false }
        })
        #expect(trace.candidates.contains {
            if case .pruned = $0.disposition { true } else { false }
        })
    }

    @Test func columnProfilesExposeSummariesWithoutRetainedValues() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Measure],
            rows: [[.double(3)], [.double(8)], [.null]])
        let profile = try #require(
            try await AutoChartAnalyzer().analyze(dataset).columnProfiles.first)
        #expect(profile.semanticType == .quantitative)
        #expect(profile.nonNullCount == 2)
        #expect(profile.numericMinimum == 3)
        #expect(profile.numericMaximum == 8)
    }

    /// A temporal profile carries a count and bounds, never the dates: nothing
    /// row-proportional is retained, so the analyzer's flat per-profile cost
    /// charge tells the truth however long the column is.
    @Test func temporalProfilesRetainCountsRatherThanDates() async throws {
        let start = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Date, v2Measure],
            rows: (0..<500).map {
                [.date(start.addingTimeInterval(Double($0) * 86_400)), .double(Double($0))]
            })
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        let profile = try #require(
            analysis.columnProfiles.first { $0.column.id == v2Date.id })
        #expect(profile.isTemporal)
        #expect(profile.temporalValueCount == 500)
        #expect(profile.nonFiniteDateCount == 0)
        #expect(profile.temporalMinimum == start)
        #expect(profile.hasFiniteTemporalSpan)
    }

    /// `AutoChartColumnProfile` is public, so a host can build one — for a test
    /// double, or from a profile it computed elsewhere.
    @Test func columnProfilesAreConstructibleByHosts() {
        let profile = AutoChartColumnProfile(
            column: v2Measure,
            semanticType: .quantitative,
            nonNullCount: 2,
            numericTypeCount: 2,
            numericValueCount: 2,
            renderableValueCount: 2,
            renderableDistinctCount: 2,
            distinctCount: 2,
            numericMinimum: 3,
            numericMaximum: 8,
            allNumericValuesPositive: true)
        #expect(profile.isQuantitative)
        #expect(profile.isUniqueAtRowGrain)
        #expect(profile.hasFiniteNumericSpan)
        #expect(!profile.hasNonFiniteNumericValues)
        #expect(profile.temporalValueCount == 0)
    }
}

@Suite struct V2FormattingAndPresentationTests {
    @Test func formattingContextsRetainRawValuesAndExhaustiveCases() throws {
        func label(_ context: AutoChartFormattingContext) -> String {
            switch context {
            case .axisTick: "axis"
            case .legend: "legend"
            case .facetHeader: "facet"
            case .markAccessibility: "accessibility"
            case .selectionSummary: "selection"
            case .kpi: "kpi"
            case .detail: "detail"
            }
        }

        #expect(
            AutoChartFormattingContext.allCases.map {
                "\($0.rawValue):\(label($0))"
            } == [
                "axisTick:axis",
                "legend:legend",
                "facetHeader:facet",
                "markAccessibility:accessibility",
                "selectionSummary:selection",
                "kpi:kpi",
                "detail:detail",
            ])
        #expect(AutoChartFormattingContext(rawValue: "legend") == .legend)
        #expect(AutoChartFormattingContext(rawValue: "facetHeader") == .facetHeader)
        #expect(
            try JSONDecoder().decode(
                AutoChartFormattingContext.self,
                from: Data("\"legend\"".utf8)) == .legend)
    }

    @Test func formatterOverridesReceiveEveryContext() {
        let formatter = AutoChartFormatters(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            value: { _, _, context, _, _ in "context:\(context.rawValue)" })
        for context in AutoChartFormattingContext.allCases {
            #expect(
                formatter.format(column: v2Measure, value: .double(1), context: context)
                    == "context:\(context.rawValue)")
        }
    }

    @Test func appliedAggregationsBridgeEveryTransformExhaustively() throws {
        #expect(AutoChartAppliedAggregation(.none) == nil)
        for aggregation in AutoChartAggregation.allCases where aggregation != .none {
            let applied = try #require(AutoChartAppliedAggregation(aggregation))
            #expect(applied.aggregation == aggregation)
            #expect(applied.rawValue == aggregation.rawValue)
        }
    }

    @Test func semanticFormatterOverridesReceiveAggregationAndNormalization() {
        let formatter = AutoChartFormatters { request, _, _ in
            let column = request.column?.id.rawValue ?? "nil"
            switch request.purpose {
            case .value:
                return "value:\(column)"
            case .aggregatedMeasure(let aggregation):
                return "measure:\(aggregation.rawValue):\(column)"
            case .normalizedFraction(let aggregation):
                return "normalized:\(aggregation.rawValue):\(column)"
            }
        }

        #expect(
            formatter.format(
                column: v2Measure,
                aggregation: .countDistinct,
                value: .double(2),
                context: .selectionSummary)
                == "measure:countDistinct:\(v2Measure.id.rawValue)")
        #expect(
            formatter.format(
                column: v2Measure,
                aggregation: .none,
                value: .double(2),
                context: .selectionSummary)
                == "value:\(v2Measure.id.rawValue)")
        #expect(
            formatter.formatNormalizedFraction(
                0.42,
                column: v2Measure,
                aggregation: .sum,
                context: .axisTick)
                == "normalized:sum:\(v2Measure.id.rawValue)")
        #expect(
            formatter.formatNormalizedFraction(
                0.42,
                column: v2Measure,
                context: .axisTick)
                == "normalized:none:\(v2Measure.id.rawValue)")
    }

    @Test func distinctCountFormattingPreservesLineageWhileDefaultsRemainUnitless() {
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: v2Category.id, y: v2Measure.id),
            aggregation: .countDistinct)
        let selection = AutoChartSelection(
            sourceRowIDs: Set([1]),
            measure: AutoChartSelectedMeasure(
                columnID: v2Measure.id,
                aggregation: .countDistinct,
                value: .scalar(.double(2))),
            family: .bar,
            specificationID: specification.id,
            markID: "distinct")
        let formatter = AutoChartFormatters { request, _, _ in
            guard case .aggregatedMeasure(let aggregation) = request.purpose else {
                return nil
            }
            return "\(request.context.rawValue):\(aggregation.rawValue):\(request.column?.id.rawValue ?? "nil")"
        }
        let presentation = selection.presentation(
            columns: [v2Category, v2Measure],
            formatters: formatter)

        #expect(
            presentation.valueDescription
                == "selectionSummary:countDistinct:\(v2Measure.id.rawValue)")
        #expect(
            formatter.format(
                column: v2Measure,
                aggregation: .countDistinct,
                value: .double(2),
                context: .axisTick)
                == "axisTick:countDistinct:\(v2Measure.id.rawValue)")

        let defaults = AutoChartFormatters(locale: Locale(identifier: "en_US"))
        let defaultPresentation = selection.presentation(
            columns: [v2Category, v2Measure],
            formatters: defaults)
        #expect(!defaultPresentation.valueDescription.contains("$"))
        #expect(!defaultPresentation.valueDescription.contains("USD"))

        let legacyFormatter = AutoChartFormatters { column, _, context, _, _ in
            "\(context.rawValue):\(column?.id.rawValue ?? "nil")"
        }
        for aggregation in [AutoChartAggregation.count, .countDistinct] {
            #expect(
                legacyFormatter.format(
                    column: v2Measure,
                    aggregation: aggregation,
                    value: .double(2),
                    context: .axisTick)
                    == "axisTick:nil")
        }
    }

    @Test func rawSelectionRangesUseValueFormattingPurpose() {
        let formatter = AutoChartFormatters { request, _, _ in
            switch request.purpose {
            case .value:
                "value"
            case .aggregatedMeasure(let aggregation):
                "aggregated:\(aggregation.rawValue)"
            case .normalizedFraction:
                "normalized"
            }
        }
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 60)
        let rangeSpecification = AutoChartSpecification(
            family: .range,
            encoding: .init(x: v2Category.id, start: "start", end: "end"))
        let boxSpecification = AutoChartSpecification.boxPlot(
            measure: v2Measure.id,
            category: v2Category.id)
        let temporal = AutoChartSelection<Int>(
            sourceRowIDs: [1],
            measure: .init(
                columnID: nil,
                aggregation: .none,
                value: .temporalRange(start: start, end: end)),
            family: .range,
            specificationID: rangeSpecification.id,
            markID: "range")
        let distribution = AutoChartSelection<Int>(
            sourceRowIDs: [1],
            measure: .init(
                columnID: v2Measure.id,
                aggregation: .none,
                value: .distribution(
                    lower: 1, quartile1: 2, median: 3, quartile3: 4, upper: 5)),
            family: .boxPlot,
            specificationID: boxSpecification.id,
            markID: "box")
        let numericRange = AutoChartSelection<Int>(
            sourceRowIDs: [1],
            measure: .init(
                columnID: v2Measure.id,
                aggregation: .none,
                value: .numericRange(lower: 1, upper: 5)),
            family: .boxPlot,
            specificationID: boxSpecification.id,
            markID: "numeric-range")
        let scalar = AutoChartSelection<Int>(
            sourceRowIDs: [1],
            measure: .init(
                columnID: v2Measure.id,
                aggregation: .none,
                value: .scalar(.double(3))),
            family: .bar,
            specificationID: AutoChartSpecification.bar(
                category: v2Category.id,
                measure: v2Measure.id).id,
            markID: "scalar")

        #expect(
            temporal.presentation(columns: [], formatters: formatter).valueDescription
                == "value–value")
        #expect(
            distribution.presentation(columns: [v2Measure], formatters: formatter)
                .valueDescription == "Median value; range value–value")
        #expect(
            numericRange.presentation(columns: [v2Measure], formatters: formatter)
                .valueDescription == "value–value")
        #expect(
            scalar.presentation(columns: [v2Measure], formatters: formatter)
                .valueDescription == "value")

        let startColumn = AutoChartColumn(
            id: "start", name: "Start",
            hints: .init(semanticType: .temporal, role: .intervalStart))
        let endColumn = AutoChartColumn(
            id: "end", name: "End",
            hints: .init(semanticType: .temporal, role: .intervalEnd))
        let endpointFormatter = AutoChartFormatters { request, _, _ in
            request.column?.id.rawValue ?? "nil"
        }
        let temporalWithLineage = AutoChartSelection<Int>(
            sourceRowIDs: [1],
            measure: .init(
                columnID: nil,
                rangeStartColumnID: startColumn.id,
                rangeEndColumnID: endColumn.id,
                aggregation: .none,
                value: .temporalRange(start: start, end: end)),
            family: .range,
            specificationID: rangeSpecification.id,
            markID: "range-with-lineage")
        #expect(
            temporalWithLineage.presentation(
                columns: [startColumn, endColumn],
                formatters: endpointFormatter
            ).valueDescription == "start–end")
    }

    @Test func defaultsFormatUnitsAndDatesWithExplicitLocaleAndTimeZone() {
        let formatter = AutoChartFormatters(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let percent = AutoChartColumn(
            id: "percent", name: "Percent",
            hints: .init(unit: .percent(fractional: true)))
        let area = AutoChartColumn(
            id: "area", name: "Area", hints: .init(unit: .area(unit: "sq ft")))
        #expect(
            formatter.format(column: percent, value: .double(0.25), context: .detail)
                .contains("25"))
        #expect(
            formatter.format(column: area, value: .double(1200), context: .detail)
                .contains("sq ft"))
        #expect(
            !formatter.format(
                column: nil,
                value: .date(Date(timeIntervalSince1970: 0)),
                context: .axisTick).isEmpty)
        let buddhistFormatter = AutoChartFormatters(
            locale: Locale(identifier: "en_US@calendar=buddhist"),
            timeZone: .gmt)
        let buddhistDate = buddhistFormatter.format(
            column: nil,
            value: .date(Date(timeIntervalSinceReferenceDate: 0)),
            context: .selectionSummary)
        #expect(buddhistDate.contains("2544"))
        #expect(!buddhistDate.contains("2001"))
        #expect(formatter.formatNormalizedFraction(0.25, context: .axisTick).contains("25"))
        #expect(!formatter.formatNormalizedFraction(0.25, context: .axisTick).contains("0.25"))
    }

    @Test func resolverFallsBackAndCanOverrideSelectionAccessibility() {
        let message = AutoChartMessage(
            category: .interface, code: .clearSelection, defaultText: "Clear")
        #expect(AutoChartTextResolver.default(message) == "Clear")
        #expect(AutoChartTextResolver { _ in "Localized" }(message) == "Localized")

        let specification = AutoChartSpecification.bar(category: "c", measure: "m")
        let selection = AutoChartSelection(
            sourceRowIDs: [3],
            dimensions: [.init(columnID: "c", value: .text("Office"))],
            measure: .init(
                columnID: "m", aggregation: .none, value: .scalar(.double(20))),
            family: .bar,
            specificationID: specification.id,
            markID: "office")
        let presentation = selection.presentation(
            columns: [v2Category, v2Measure],
            textResolver: AutoChartTextResolver { message in
                switch message.code {
                case .selectionValue:
                    guard case .string(let value) = message.arguments["value"],
                        !value.isEmpty
                    else { return nil }
                    return "Localized value"
                case .selectionSummary:
                    guard message.arguments["label"] == .string("Office"),
                        message.arguments["value"] == .string("Localized value"),
                        message.arguments["rows"] == .integer(1)
                    else { return nil }
                    return "Localized selection"
                default:
                    return nil
                }
            })
        #expect(presentation.label == "Office")
        #expect(presentation.valueDescription == "Localized value")
        #expect(presentation.accessibilityDescription == "Localized selection")

        let firstMeasure = AutoChartColumn(id: "m", name: "First")
        let secondMeasure = AutoChartColumn(id: "m", name: "Second")
        let duplicatePresentation = selection.presentation(
            columns: [v2Category, firstMeasure, secondMeasure],
            formatters: AutoChartFormatters { column, _, _, _, _ in column?.name })
        #expect(duplicatePresentation.valueDescription == "First")
    }

    @Test func messageIdentifiersRetainUnknownCodableValues() throws {
        let encoded = Data(
            #"{"arguments":{},"category":"future-category","code":"future-code","defaultText":"Future"}"#
                .utf8)
        let message = try JSONDecoder().decode(AutoChartMessage.self, from: encoded)

        #expect(message.category.rawValue == "future-category")
        #expect(message.code.rawValue == "future-code")
        let reencoded = try JSONEncoder().encode(message)
        let object = try #require(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(object["category"] as? String == "future-category")
        #expect(object["code"] as? String == "future-code")
        #expect(try JSONDecoder().decode(AutoChartMessage.self, from: reencoded) == message)
    }

    @Test func messagesIgnoreUnknownArgumentRepresentationsWithoutLosingKnownValues() throws {
        let original = AutoChartMessage(
            category: .diagnostic,
            code: .validationFailed,
            arguments: ["known": .string("Known")],
            defaultText: "Future message")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any])
        var arguments = try #require(object["arguments"] as? [String: Any])
        arguments["future"] = ["future": ["_0": "payload"]]
        arguments["future-family"] = ["family": ["_0": "future-family"]]
        arguments["future-scalar"] = 42
        arguments["future-array"] = ["payload"]
        arguments["future-null"] = NSNull()
        arguments["future-empty-object"] = [String: Any]()
        arguments["future-multi-case"] = [
            "first-future-case": ["_0": "first"],
            "second-future-case": ["_0": "second"],
        ]
        object["arguments"] = arguments

        let decoded = try JSONDecoder().decode(
            AutoChartMessage.self,
            from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.arguments == ["known": .string("Known")])
        #expect(decoded.defaultText == "Future message")
    }

    @Test func messageArgumentCodingRoundTripsEveryKnownCase() throws {
        let values: [AutoChartMessageArgument] = [
            .string("Text"),
            .integer(42),
            .number(4.25),
            .column("measure"),
            .family(.bar),
            .aggregation(.countDistinct),
        ]
        for value in values {
            let encoded = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(AutoChartMessageArgument.self, from: encoded) == value)
        }
    }

    @Test func directMessageArgumentsRejectMixedKnownAndUnknownCases() {
        let mixed = Data(
            #"{"string":{"_0":"Known"},"future":{"_0":"payload"}}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AutoChartMessageArgument.self, from: mixed)
        }
    }

    @Test func messagesRejectMalformedKnownArgumentRepresentations() throws {
        let original = AutoChartMessage(
            category: .diagnostic,
            code: .validationFailed,
            arguments: ["known": .string("Known")],
            defaultText: "Malformed message")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any])
        var arguments = try #require(object["arguments"] as? [String: Any])
        arguments["known"] = ["string": ["_0": 42]]
        object["arguments"] = arguments
        let encoded = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AutoChartMessage.self, from: encoded)
        }

        arguments["known"] = [
            "string": ["_0": "Known"],
            "future": ["_0": "payload"],
        ]
        object["arguments"] = arguments
        let multipleCases = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AutoChartMessage.self, from: multipleCases)
        }
    }

    #if canImport(Charts) && canImport(SwiftUI)
    @MainActor
    @Test func distinctCountRenderingSurfacesResolveLineageWithoutApplyingUnits() async throws {
        let distinctMeasure = AutoChartColumn(
            id: "distinct-measure",
            name: "Customer ID",
            hints: .init(
                semanticType: .quantitative,
                role: .measure,
                unit: .currency(code: "USD"),
                measureSemantics: .init(
                    source: .rowLevel,
                    rollup: .safe(.countDistinct))))
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, distinctMeasure],
            rows: [
                [.text("A"), .integer(1)],
                [.text("A"), .integer(2)],
            ])
        let analysis = try await AutoChartAnalyzer().analyze(dataset)
        let prepared = try await analysis.prepare(
            AutoChartSpecification(
                family: .bar,
                encoding: .init(x: v2Category.id, y: distinctMeasure.id),
                aggregation: .countDistinct))
        let formatter = AutoChartFormatters { request, _, _ in
            guard case .aggregatedMeasure(let aggregation) = request.purpose else {
                return nil
            }
            return "\(request.context.rawValue):\(aggregation.rawValue):\(request.column?.id.rawValue ?? "nil")"
        }
        let view = AutoChartView(preparedChart: prepared, formatters: formatter)

        #expect(
            view.formattedMeasureValue(2, for: .axisTick)
                == "axisTick:countDistinct:\(distinctMeasure.id.rawValue)")
        #expect(
            view.formattedMeasureValue(2, for: .markAccessibility)
                == "markAccessibility:countDistinct:\(distinctMeasure.id.rawValue)")

        let defaultView = AutoChartView(
            preparedChart: prepared,
            formatters: AutoChartFormatters(locale: Locale(identifier: "en_US")))
        let axisValue = defaultView.formattedMeasureValue(2, for: .axisTick)
        let accessibilityValue = defaultView.formattedMeasureValue(
            2, for: .markAccessibility)
        #expect(!axisValue.contains("$"))
        #expect(!axisValue.contains("USD"))
        #expect(!accessibilityValue.contains("$"))
        #expect(!accessibilityValue.contains("USD"))
    }

    @MainActor
    @Test func normalizedAxisUsesPercentSemanticsWhileMarksKeepRawMeasureSemantics() async throws {
        let series = AutoChartColumn(
            id: "series",
            name: "Series",
            hints: .init(semanticType: .nominal, role: .dimension))
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, series, v2Measure],
            rows: [
                [.text("A"), .text("One"), .double(10)],
                [.text("A"), .text("Two"), .double(30)],
            ])
        let analysis = try await AutoChartAnalyzer().analyze(dataset)
        let prepared = try await analysis.prepare(
            .normalizedBar(
                category: v2Category.id,
                measure: v2Measure.id,
                series: series.id,
                aggregation: .sum))
        let formatter = AutoChartFormatters { request, _, _ in
            let column = request.column?.id.rawValue ?? "nil"
            switch request.purpose {
            case .normalizedFraction(let aggregation):
                return "normalized:\(aggregation.rawValue):\(column)"
            case .aggregatedMeasure(let aggregation):
                return "measure:\(aggregation.rawValue):\(column)"
            case .value:
                return nil
            }
        }
        let view = AutoChartView(preparedChart: prepared, formatters: formatter)

        #expect(
            view.formattedMeasureValue(0.25, for: .axisTick)
                == "normalized:sum:\(v2Measure.id.rawValue)")
        #expect(
            view.formattedMeasureValue(10, for: .markAccessibility)
                == "measure:sum:\(v2Measure.id.rawValue)")
    }

    @MainActor
    @Test func renderedMeasureFormattingCoversPreparedFamilies() async throws {
        let histogramDataset = try AutoChartDataset<Int>(
            columns: [v2Measure],
            rows: [[.double(1)], [.double(2)]])
        let histogramAnalysis = try await AutoChartAnalyzer().analyze(histogramDataset)
        let histogram = try await histogramAnalysis.prepare(
            .histogram(value: v2Measure.id, binCount: 2))

        let secondaryCategory = AutoChartColumn(
            id: "secondary-category",
            name: "Secondary category",
            hints: .init(semanticType: .nominal, role: .dimension))
        let heatmapDataset = try AutoChartDataset<Int>(
            columns: [v2Category, secondaryCategory],
            rows: [
                [.text("A"), .text("One")],
                [.text("A"), .text("Two")],
            ])
        let heatmapAnalysis = try await AutoChartAnalyzer().analyze(heatmapDataset)
        let heatmap = try await heatmapAnalysis.prepare(
            .heatmap(x: v2Category.id, y: secondaryCategory.id))

        let boxDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (1...5).map { [.text("A"), .double(Double($0))] })
        let boxAnalysis = try await AutoChartAnalyzer().analyze(boxDataset)
        let boxPlot = try await boxAnalysis.prepare(
            .boxPlot(measure: v2Measure.id, category: v2Category.id))

        let donutDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("A"), .double(2)],
                [.text("B"), .double(4)],
            ])
        let donutAnalysis = try await AutoChartAnalyzer().analyze(donutDataset)
        let donut = try await donutAnalysis.prepare(
            .donut(
                category: v2Category.id,
                measure: v2Measure.id,
                aggregation: .sum))

        let kpiMeasure = AutoChartColumn(
            id: "kpi-measure",
            name: "Revenue",
            hints: .init(semanticType: .quantitative, role: .measure))
        let kpiDataset = try AutoChartDataset<Int>(
            columns: [kpiMeasure],
            rows: [[.double(42)]])
        let kpiAnalysis = try await AutoChartAnalyzer().analyze(kpiDataset)
        let kpi = try await kpiAnalysis.prepare(.kpi(measure: kpiMeasure.id))

        let formatter = AutoChartFormatters { request, _, _ in
            let column = request.column?.id.rawValue ?? "nil"
            switch request.purpose {
            case .value:
                if request.context == .kpi {
                    let value = request.value == .double(42)
                        ? "42" : "unexpected \(String(reflecting: request.value))"
                    return "\(request.context.rawValue):value:\(column):\(value)"
                }
                return "\(request.context.rawValue):value:\(column)"
            case .aggregatedMeasure(let aggregation):
                return "\(request.context.rawValue):\(aggregation.rawValue):\(column)"
            case .normalizedFraction:
                return nil
            }
        }
        for prepared in [histogram, heatmap] {
            let view = AutoChartView(preparedChart: prepared, formatters: formatter)
            #expect(
                view.formattedMeasureValue(2, for: .axisTick)
                    == "axisTick:count:nil")
            #expect(
                view.formattedMeasureValue(2, for: .markAccessibility)
                    == "markAccessibility:count:nil")
        }

        let boxView = AutoChartView(
            preparedChart: boxPlot,
            formatters: formatter)
        #expect(
            boxView.formattedMeasureValue(3, for: .axisTick)
                == "axisTick:value:\(v2Measure.id.rawValue)")
        #expect(
            boxView.formattedMeasureValue(3, for: .markAccessibility)
                == "markAccessibility:value:\(v2Measure.id.rawValue)")

        let donutView = AutoChartView(
            preparedChart: donut,
            formatters: formatter)
        #expect(
            donutView.formattedMeasureValue(3, for: .axisTick)
                == "axisTick:sum:\(v2Measure.id.rawValue)")

        #expect(kpi.core.data.first?.ySourceValue == .double(42))
        let kpiContent = AutoChartKPIContent(
            preparedChart: kpi,
            typography: .standard,
            formatters: formatter,
            textResolver: .default)
        #expect(kpiContent.valueText == "kpi:value:\(kpiMeasure.id.rawValue):42")
        #expect(kpiContent.title == "Revenue")
        #expect(!kpiContent.isCompact)
        #expect(
            kpiContent.accessibilityText
                == "Revenue, kpi:value:\(kpiMeasure.id.rawValue):42")
        let localizedKPIContent = AutoChartKPIContent(
            preparedChart: kpi,
            typography: .standard,
            formatters: formatter,
            textResolver: AutoChartTextResolver { message in
                guard message.category == .accessibility,
                    message.code == .kpiAccessibility,
                    message.arguments["title"] == .string("Revenue"),
                    message.arguments["value"]
                        == .string("kpi:value:\(kpiMeasure.id.rawValue):42")
                else { return nil }
                return "Localized KPI"
            })
        #expect(localizedKPIContent.accessibilityText == "Localized KPI")
    }

    @Test func previewUsesExactHeightAndIndependentControls() {
        #expect(AutoChartDefaultPlotHeight.explorer == 280)
        #expect(AutoChartDefaultPlotHeight.plotOnly == 180)
        #expect(AutoChartPresentation().plotHeight == 280)
        #expect(AutoChartPresentation.explorer().plotHeight == 280)
        #expect(AutoChartPresentation.explorer(plotHeight: nil).plotHeight == nil)

        let preview = AutoChartPresentation.preview(plotHeight: 156)
        #expect(preview.plotHeight == 156)
        #expect(preview.chrome == [.diagnostics])
        #expect(preview.interactions.isEmpty)

        let custom = AutoChartPresentation(
            plotHeight: 156,
            chrome: [.title],
            interactions: [.selection],
            typography: .standard)
        #expect(custom.plotHeight == 156)
        #expect(custom.chrome.contains(.title))
        #expect(custom.interactions == [.selection])
    }
    #endif
}

@Suite struct V2AnalyzerLifecycleTests {
    @Test func preparationGateDisarmsAfterEntryWaitTimesOut() async throws {
        let gate = OneShotPreparationGate(timeout: .milliseconds(10))
        try #require(await gate.arm())

        await #expect(throws: PreparationGateError.self) {
            try await gate.waitUntilBlocked()
        }
        #expect(!(await gate.isArmed))
        #expect(await gate.activeTimeoutTaskCount == 0)
    }

    @Test func preparationGateTimesOutEveryConcurrentEntryWaiter() async throws {
        let gate = OneShotPreparationGate(timeout: .seconds(30))
        let peerStarted = DispatchSemaphore(value: 0)
        let peerFinished = DispatchGroup()
        try #require(await gate.arm())
        let peers = (0..<31).map { _ in
            peerFinished.enter()
            return Task {
                defer { peerFinished.leave() }
                try await gate.waitUntilBlocked(onWaiting: { peerStarted.signal() })
            }
        }
        func drain<Success: Sendable, Failure: Error>(
            _ tasks: [Task<Success, Failure>],
            completion: DispatchGroup,
            name: String
        ) async {
            tasks.forEach { $0.cancel() }
            let didFinish = await finishesPromptly(completion)
            #expect(didFinish, "Cancelled \(name) should finish promptly")
            guard didFinish else { return }
            for task in tasks { _ = await task.result }
        }

        let peersStarted = await receivesSignalsPromptly(peerStarted, count: peers.count)
        #expect(peersStarted)
        guard peersStarted else {
            await drain(peers, completion: peerFinished, name: "peer waiters")
            return
        }

        let triggerStarted = DispatchSemaphore(value: 0)
        let triggerFinished = DispatchGroup()
        triggerFinished.enter()
        let trigger = Task {
            defer { triggerFinished.leave() }
            try await gate.waitUntilBlocked(
                timeout: .milliseconds(100),
                onWaiting: { triggerStarted.signal() })
        }
        let triggerDidStart = await receivesSignalPromptly(triggerStarted)
        #expect(triggerDidStart)
        guard triggerDidStart else {
            await drain([trigger], completion: triggerFinished, name: "trigger")
            await drain(peers, completion: peerFinished, name: "peer waiters")
            return
        }

        let triggerDidFinish = await finishesPromptly(triggerFinished)
        #expect(triggerDidFinish)
        guard triggerDidFinish else {
            await drain([trigger], completion: triggerFinished, name: "trigger")
            await drain(peers, completion: peerFinished, name: "peer waiters")
            return
        }
        await #expect(throws: PreparationGateError.self) {
            try await trigger.value
        }

        let activeTimeoutTaskCount = await gate.activeTimeoutTaskCount
        #expect(activeTimeoutTaskCount == 0)
        guard activeTimeoutTaskCount == 0 else {
            await drain(peers, completion: peerFinished, name: "peer waiters")
            return
        }

        let peersDidFinish = await finishesPromptly(peerFinished)
        #expect(peersDidFinish)
        guard peersDidFinish else {
            await drain(peers, completion: peerFinished, name: "peer waiters")
            return
        }
        for peer in peers {
            await #expect(throws: PreparationGateError.self) {
                try await peer.value
            }
        }

        #expect(!(await gate.isArmed))
    }

    @Test func preparationGateCancelsSomeWaitersAndReleasesTheRest() async throws {
        let gate = OneShotPreparationGate(timeout: .seconds(30))
        let waiterStarted = DispatchSemaphore(value: 0)
        try #require(await gate.arm())
        let waiters = (0..<32).map { _ in
            Task {
                try await gate.waitUntilBlocked(onWaiting: { waiterStarted.signal() })
            }
        }

        let allWaitersStarted = await receivesSignalsPromptly(
            waiterStarted,
            count: waiters.count)
        #expect(allWaitersStarted)
        guard allWaitersStarted else {
            waiters.forEach { $0.cancel() }
            for waiter in waiters { _ = try? await waiter.value }
            return
        }
        for waiter in waiters.enumerated() where waiter.offset.isMultiple(of: 2) {
            waiter.element.cancel()
        }
        for waiter in waiters.enumerated() where waiter.offset.isMultiple(of: 2) {
            await #expect(throws: CancellationError.self) {
                try await waiter.element.value
            }
        }
        #expect(await gate.activeTimeoutTaskCount == waiters.count / 2)

        let preparation = Task { await gate.waitWhenArmed() }
        for waiter in waiters.enumerated() where !waiter.offset.isMultiple(of: 2) {
            try await waiter.element.value
        }
        #expect(await gate.activeTimeoutTaskCount == 1)
        await gate.resume()
        await preparation.value

        #expect(await gate.activeTimeoutTaskCount == 0)
    }

    @Test func preparationGatePreservesArmForAlreadyCancelledPreparation() async throws {
        let gate = OneShotPreparationGate()
        try #require(await gate.arm())
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let cancelledPreparation = Task {
            for await _ in stream {}
            await gate.waitWhenArmed()
        }

        cancelledPreparation.cancel()
        continuation.finish()
        await cancelledPreparation.value
        #expect(await gate.activeTimeoutTaskCount == 0)
        #expect(await gate.cancelledAttemptCount == 1)

        let remainedArmed = await gate.isArmed
        #expect(remainedArmed)
        guard remainedArmed else { return }

        let nextPreparation = Task { await gate.waitWhenArmed() }
        do {
            try await gate.waitUntilBlocked()
            await gate.resume()
            await nextPreparation.value
        } catch {
            nextPreparation.cancel()
            await gate.resume()
            await nextPreparation.value
            throw error
        }
    }

    @Test func preparationGateFailsWaiterAndPreservesArmAfterCancelledAttempt() async throws {
        let gate = OneShotPreparationGate()
        try #require(await gate.arm())
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterCompleted = DispatchSemaphore(value: 0)
        let waiter = Task {
            defer { waiterCompleted.signal() }
            try await gate.waitUntilBlocked(onWaiting: { waiterStarted.signal() })
        }
        let startedPromptly = await receivesSignalPromptly(waiterStarted)
        #expect(startedPromptly)
        guard startedPromptly else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let cancelledPreparation = Task {
            for await _ in stream {}
            await gate.waitWhenArmed()
        }
        cancelledPreparation.cancel()
        continuation.finish()
        await cancelledPreparation.value

        let waiterReturnedPromptly = await receivesSignalPromptly(waiterCompleted)
        #expect(waiterReturnedPromptly)
        guard waiterReturnedPromptly else {
            waiter.cancel()
            _ = try? await waiter.value
            return
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.activeTimeoutTaskCount == 0)

        let remainedArmed = await gate.isArmed
        #expect(remainedArmed)
        guard remainedArmed else { return }

        let nextPreparation = Task { await gate.waitWhenArmed() }
        do {
            try await gate.waitUntilBlocked()
            await gate.resume()
            await nextPreparation.value
        } catch {
            nextPreparation.cancel()
            await gate.resume()
            await nextPreparation.value
            throw error
        }
    }

    @Test func preparationGateCancelsTimeoutTaskAfterRelease() async throws {
        let gate = OneShotPreparationGate()
        try #require(await gate.arm())
        let preparation = Task { await gate.waitWhenArmed() }

        try await gate.waitUntilBlocked()
        #expect(await gate.activeTimeoutTaskCount == 1)
        await gate.resume()
        await preparation.value

        #expect(await gate.activeTimeoutTaskCount == 0)
    }

    @Test func preparationGateRejectedRearmReleasesBlockedPreparation() async throws {
        let gate = OneShotPreparationGate()
        try #require(await gate.arm())
        let preparationCompleted = DispatchSemaphore(value: 0)
        let preparation = Task {
            defer { preparationCompleted.signal() }
            await gate.waitWhenArmed()
        }

        try await gate.waitUntilBlocked()
        var rearmResult: Bool?
        await withKnownIssue("Re-arming reports the gate invariant violation.") {
            rearmResult = await gate.arm()
        }
        #expect(rearmResult == false)
        let releasedPromptly = await receivesSignalPromptly(preparationCompleted)
        #expect(releasedPromptly)
        if !releasedPromptly {
            await gate.resume()
        }
        await preparation.value

        #expect(await gate.activeTimeoutTaskCount == 0)
    }

    @Test func identicalKeyedRequestsCoalesce() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<200).map { [.text("A"), .double(Double($0))] },
            key: .init(identity: "coalesced", revision: "1"))
        let analyzer = AutoChartAnalyzer()
        async let first = analyzer.analyze(dataset)
        async let second = analyzer.analyze(dataset)
        let (firstResult, secondResult) = try await (first, second)

        #expect(
            firstResult.primaryChart?.recommendation.id
                == secondResult.primaryChart?.recommendation.id)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.misses == 1)
        #expect(statistics.analyses.misses == 1)
        #expect(statistics.inFlightRequests == 0)
    }

    @Test func keyedAnalysisHitsDoNotReadRowsOrMissTheTableLayerAgain() async throws {
        let counter = ChartRowsReadCounter()
        let table = CountingChartRowsTable(
            rows: [
                .init(chartRowID: 1, value: 10),
                .init(chartRowID: 2, value: 20),
            ],
            counter: counter,
            chartDataKey: .init(identity: "counted-analysis", revision: "1"))
        let analyzer = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 0),
                maximumRetainedCost: 1_024 * 1_024))

        _ = try await analyzer.analyze(table)
        let baseline = await analyzer.cacheStatistics
        _ = try await analyzer.analyze(table)
        let reused = await analyzer.cacheStatistics

        #expect(counter.count == 1)
        #expect(reused.tables.misses == baseline.tables.misses)
        #expect(reused.analyses.hits == baseline.analyses.hits + 1)
    }

    @Test func identicalUnkeyedRequestsCoalesceAfterFingerprintComparison() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<200).map { [.text("A"), .double(Double($0))] })
        let analyzer = AutoChartAnalyzer()
        async let first = analyzer.analyze(dataset)
        async let second = analyzer.analyze(dataset)
        let (firstResult, secondResult) = try await (first, second)

        #expect(
            firstResult.primaryChart?.recommendation.id
                == secondResult.primaryChart?.recommendation.id)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.misses == 1)
        #expect(statistics.analyses.misses == 1)
        #expect(statistics.inFlightRequests == 0)
    }

    @Test func crossLayerSourceReuseIsChargedToTheProvidingLayer() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]])

        let analysisBacked = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 0),
                maximumRetainedCost: 1_024 * 1_024))
        _ = try await analysisBacked.analyze(dataset)
        let analysisBaseline = await analysisBacked.cacheStatistics
        _ = try await analysisBacked.analyze(dataset)
        let analysisReuse = await analysisBacked.cacheStatistics
        #expect(analysisReuse.tables.misses == analysisBaseline.tables.misses)
        #expect(analysisReuse.analyses.hits > analysisBaseline.analyses.hits)

        let chartBacked = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 0),
                preparedCharts: .init(maximumEntries: 4),
                maximumRetainedCost: 1_024 * 1_024))
        _ = try await chartBacked.analyze(dataset)
        let chartBaseline = await chartBacked.cacheStatistics
        _ = try await chartBacked.analyze(dataset)
        let chartReuse = await chartBacked.cacheStatistics
        #expect(chartReuse.tables.misses == chartBaseline.tables.misses)
        #expect(chartReuse.preparedCharts.hits > chartBaseline.preparedCharts.hits)
    }

    @Test func keyedCrossLayerSourceReuseIsChargedToTheProvidingLayer() async throws {
        let analysisCounter = ChartRowsReadCounter()
        let analysisTable = CountingChartRowsTable(
            rows: [
                .init(chartRowID: 1, value: 10),
                .init(chartRowID: 2, value: 20),
            ],
            counter: analysisCounter,
            chartDataKey: .init(identity: "keyed-analysis-layer", revision: "1"))
        let analysisBacked = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 0),
                maximumRetainedCost: 1_024 * 1_024))
        _ = try await analysisBacked.analyze(analysisTable)
        let analysisBaseline = await analysisBacked.cacheStatistics
        _ = try await analysisBacked.analyze(
            analysisTable,
            context: AutoChartContext(goal: .distribution))
        let analysisReuse = await analysisBacked.cacheStatistics
        #expect(analysisCounter.count == 1)
        #expect(analysisReuse.tables.misses == analysisBaseline.tables.misses)
        #expect(analysisReuse.analyses.hits > analysisBaseline.analyses.hits)

        let chartCounter = ChartRowsReadCounter()
        let chartTable = CountingChartRowsTable(
            rows: [
                .init(chartRowID: 1, value: 10),
                .init(chartRowID: 2, value: 20),
            ],
            counter: chartCounter,
            chartDataKey: .init(identity: "keyed-chart-layer", revision: "1"))
        let chartBacked = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 0),
                preparedCharts: .init(maximumEntries: 4),
                maximumRetainedCost: 1_024 * 1_024))
        _ = try await chartBacked.analyze(chartTable)
        let chartBaseline = await chartBacked.cacheStatistics
        _ = try await chartBacked.analyze(chartTable)
        let chartReuse = await chartBacked.cacheStatistics
        #expect(chartCounter.count == 1)
        #expect(chartReuse.tables.misses == chartBaseline.tables.misses)
        #expect(chartReuse.preparedCharts.hits > chartBaseline.preparedCharts.hits)
    }

    @Test func concurrentIdenticalChartPreparationsUseOneCacheMiss() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<5_000).map {
                [.text("Category \($0 % 50)"), .double(Double($0))]
            })
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        let baselineMisses = await analyzer.cacheStatistics.preparedCharts.misses
        let specification = AutoChartSpecification.bar(
            category: v2Category.id,
            measure: v2Measure.id,
            aggregation: .sum,
            title: "Concurrent single flight")

        try await withThrowingTaskGroup(of: AutoChartPreparedChart<Int>.self) { group in
            for _ in 0..<24 {
                group.addTask { try await analysis.prepare(specification) }
            }
            while try await group.next() != nil {}
        }

        let statistics = await analyzer.cacheStatistics
        #expect(statistics.preparedCharts.misses == baselineMisses + 1)
        #expect(statistics.preparedCharts.entries >= 1)
    }

    @Test func unkeyedRequestsWithDifferentLineageDoNotCoalesce() async throws {
        let rows: [[AutoChartValue]] = (0..<500).map {
            [.text("A"), .double(Double($0))]
        }
        let firstIDs = Array(0..<500)
        let secondIDs = Array(1_000..<1_500)
        let firstDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: rows,
            rowIDs: firstIDs)
        let secondDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: rows,
            rowIDs: secondIDs)
        let analyzer = AutoChartAnalyzer()

        async let first = analyzer.analyze(firstDataset)
        async let second = analyzer.analyze(secondDataset)
        let (firstResult, secondResult) = try await (first, second)
        let firstLineage = Set(
            try #require(firstResult.primaryChart).marks.flatMap { $0.sourceRowIDs })
        let secondLineage = Set(
            try #require(secondResult.primaryChart).marks.flatMap { $0.sourceRowIDs })

        #expect(!firstLineage.isEmpty)
        #expect(!secondLineage.isEmpty)
        #expect(firstLineage.isSubset(of: Set(firstIDs)))
        #expect(secondLineage.isSubset(of: Set(secondIDs)))
        #expect(firstLineage.isDisjoint(with: secondLineage))
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.misses == 2)
        #expect(statistics.analyses.misses == 2)
    }

    @Test func chartOnlyCacheKeepsUnkeyedLineageCollisionSafe() async throws {
        let rows: [[AutoChartValue]] = [[.text("A"), .double(10)]]
        let firstDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: rows,
            rowIDs: [1])
        let secondDataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: rows,
            rowIDs: [2])
        let analyzer = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 0),
                preparedCharts: .init(maximumEntries: 4),
                maximumRetainedCost: 1_024 * 1_024))

        let first = try await analyzer.analyze(firstDataset)
        let second = try await analyzer.analyze(secondDataset)
        let firstLineage = Set(
            try #require(first.primaryChart).marks.flatMap { $0.sourceRowIDs })
        let secondLineage = Set(
            try #require(second.primaryChart).marks.flatMap { $0.sourceRowIDs })

        #expect(firstLineage == [1])
        #expect(secondLineage == [2])
        #expect(await analyzer.cacheStatistics.preparedCharts.misses == 2)
    }

    @Test func uncachedAnalyzerRetainsNothing() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]])
        let analyzer = AutoChartAnalyzer(configuration: .uncached)
        _ = try await analyzer.analyze(dataset)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.entries == 0)
        #expect(statistics.analyses.entries == 0)
        #expect(statistics.preparedCharts.entries == 0)
    }

    @Test func sharedSnapshotCostIsChargedWhenTheTableLayerIsDisabled() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<100).map { [.text("Category \($0)"), .double(Double($0))] },
            key: .init(identity: "costed", revision: "1"))
        let analyzer = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 0),
                maximumRetainedCost: 1_024))
        let analysis = try await analyzer.analyze(dataset)
        let statistics = await analyzer.cacheStatistics

        #expect(analysis.primaryChart != nil)
        #expect(statistics.tables.entries == 0)
        #expect(statistics.analyses.entries == 0)
        // The shared snapshot's cost exceeds the retained-cost budget, so the
        // analysis is rejected at admission instead of being admitted and
        // immediately evicted after draining the cache.
        #expect(statistics.analyses.evictions == 0)
    }

    @Test func anEntryTooLargeToOutliveItsSharedSnapshotDoesNotDrainTheCache() async throws {
        let analyzer = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 4),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 4),
                maximumRetainedCost: 64 * 1_024))
        let resident = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]],
            key: .init(identity: "resident", revision: "1"))
        _ = try await analyzer.analyze(resident)
        let baseline = await analyzer.cacheStatistics
        #expect(baseline.tables.entries == 1)
        #expect(baseline.analyses.entries == 1)

        let oversized = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<1_000).map { [.text("Category \($0)"), .double(Double($0))] },
            key: .init(identity: "oversized", revision: "1"))
        let analysis = try await analyzer.analyze(oversized)
        let statistics = await analyzer.cacheStatistics

        #expect(analysis.primaryChart != nil)
        #expect(statistics.tables.entries == 1)
        #expect(statistics.analyses.entries == 1)
        #expect(statistics.tables.evictions == 0)
        #expect(statistics.analyses.evictions == 0)
        #expect(statistics.preparedCharts.evictions == 0)
    }

    #if ATC_TEST_HOOKS
    @Test func removeAllDoesNotFailConcurrentAnalyzeCallers() async throws {
        let gate = OneShotPreparationGate()
        let counter = ChartRowsReadCounter()
        let table = CountingChartRowsTable(
            rows: [DuplicateIDRow(chartRowID: 0, value: 1)],
            counter: counter)
        let analyzer = AutoChartAnalyzer(
            testHooks: .chartPreparation { await gate.waitWhenArmed() })
        try #require(await gate.arm())
        let task = Task { try await analyzer.analyze(table) }

        try await gate.waitUntilBlocked()
        #expect(await analyzer.cacheStatistics.inFlightRequests == 1)
        await analyzer.removeAll()
        await gate.resume()
        let analysis = try await task.value

        #expect(analysis.primaryChart != nil)
        #expect(counter.count >= 2)
        #expect(await analyzer.cacheStatistics.inFlightRequests == 0)
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func removeAllDoesNotFailConcurrentAnalyzeCallers() {}
    #endif

    @Test func evictionDoesNotBreakLiveAnalyses() async throws {
        let configuration = AutoChartAnalyzerConfiguration(
            tables: .init(maximumEntries: 1),
            analyses: .init(maximumEntries: 1),
            preparedCharts: .init(maximumEntries: 1),
            maximumRetainedCost: 1_024 * 1_024)
        let analyzer = AutoChartAnalyzer(configuration: configuration)
        let first = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]],
            key: .init(identity: "first", revision: "1"))
        let second = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("B"), .double(2)]],
            key: .init(identity: "second", revision: "1"))
        let live = try await analyzer.analyze(first)
        let primaryID = try #require(live.primaryChart?.recommendation.id)
        _ = try await analyzer.analyze(second)

        #expect(try await live.prepare(primaryID).recommendation.id == primaryID)
        #expect(await analyzer.cacheStatistics.tables.evictions > 0)
    }

    @Test func cancelledRequestDoesNotReturnAnAnalysis() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<1_000).map { [.text("A"), .double(Double($0))] })
        let analyzer = AutoChartAnalyzer()
        let task = Task { try await analyzer.analyze(dataset) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    #if ATC_TEST_HOOKS
    @Test func cancellationBeforeKeyedMaterializationDoesNotReadRows() async throws {
        let gate = OneShotPreparationGate()
        let counter = ChartRowsReadCounter()
        let table = CountingChartRowsTable(
            rows: [DuplicateIDRow(chartRowID: 0, value: 0)],
            counter: counter,
            chartDataKey: .init(identity: "cancel-before-materialization", revision: "1"))
        let analyzer = AutoChartAnalyzer(
            testHooks: .keyedMaterialization { await gate.waitWhenArmed() })
        try #require(await gate.arm())
        let completed = DispatchSemaphore(value: 0)
        let pending = Task {
            defer { completed.signal() }
            return try await analyzer.analyze(table)
        }

        do {
            try await gate.waitUntilBlocked()
            pending.cancel()
            let returnedPromptly = await receivesSignalPromptly(completed)
            await gate.resume()

            #expect(returnedPromptly)
            await #expect(throws: CancellationError.self) {
                try await pending.value
            }
            #expect(counter.count == 0)
        } catch {
            pending.cancel()
            await gate.resume()
            _ = try? await pending.value
            throw error
        }
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func cancellationBeforeKeyedMaterializationDoesNotReadRows() {}
    #endif
}


@Suite struct ReviewFixRegressionTests {
    /// `AutoChartSpecification.id` excludes the title, so two identically
    /// shaped charts must share one preparation instead of each paying a full
    /// pass over the snapshot.
    @Test func chartCacheIgnoresTitleWhenSharingPreparedMarks() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<200).map { [.text("Category \($0 % 10)"), .double(Double($0))] })
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        let baseline = await analyzer.cacheStatistics.preparedCharts

        func specification(title: String) -> AutoChartSpecification {
            .bar(
                category: v2Category.id,
                measure: v2Measure.id,
                aggregation: .sum,
                title: title)
        }
        #expect(specification(title: "One").id == specification(title: "Two").id)

        let first = try await analysis.prepare(specification(title: "One"))
        let second = try await analysis.prepare(specification(title: "Two"))
        let statistics = await analyzer.cacheStatistics.preparedCharts
        #expect(statistics.misses == baseline.misses + 1)
        #expect(statistics.hits > baseline.hits)
        // Sharing the preparation must not leak the first caller's title.
        #expect(first.recommendation.specification.title == "One")
        #expect(second.recommendation.specification.title == "Two")
        #expect(first.marks == second.marks)
    }

    #if ATC_TEST_HOOKS
    /// A memory trim must release memory: work already in flight when the host
    /// trimmed must not repopulate the cache it was asked to empty, and it must
    /// still hand its caller a result.
    @Test func trimStopsInFlightWorkFromRepopulatingTheCache() async throws {
        let gate = OneShotPreparationGate()
        let table = CountingChartRowsTable(
            rows: [DuplicateIDRow(chartRowID: 0, value: 1)],
            counter: ChartRowsReadCounter())
        let analyzer = AutoChartAnalyzer(
            testHooks: .chartPreparation { await gate.waitWhenArmed() })
        try #require(await gate.arm())
        let pending = Task { try await analyzer.analyze(table) }

        try await gate.waitUntilBlocked()
        #expect(await analyzer.cacheStatistics.inFlightRequests == 1)
        await analyzer.trim(to: .minimum)
        await gate.resume()
        let analysis = try await pending.value

        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.entries == 0)
        #expect(statistics.analyses.entries == 0)
        #expect(statistics.preparedCharts.entries == 0)
        // The caller still gets its analysis; only caching was suppressed.
        #expect(analysis.primaryChart != nil)
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func trimStopsInFlightWorkFromRepopulatingTheCache() {}
    #endif

    /// `validation(for:)` shares the prepared-chart cache with `prepare(_:)`
    /// instead of preparing the same marks a second time.
    @Test func asyncValidationSharesPreparationWithPrepare() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<200).map { [.text("Category \($0 % 10)"), .double(Double($0))] })
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        let baseline = await analyzer.cacheStatistics.preparedCharts
        let specification = AutoChartSpecification.bar(
            category: v2Category.id,
            measure: v2Measure.id,
            aggregation: .sum)

        let validation = try await analysis.validation(for: specification)
        #expect(validation.isValid)
        #expect(validation == analysis.validate(specification))
        _ = try await analysis.prepare(specification)

        let statistics = await analyzer.cacheStatistics.preparedCharts
        #expect(statistics.misses == baseline.misses + 1)
        #expect(statistics.hits > baseline.hits)
    }

    #if ATC_TEST_HOOKS
    @Test func removeAllRetriesUncancelledPreparedChartWaiters() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let analyzer = AutoChartAnalyzer(
            testHooks: .chartPreparation { await gate.waitWhenArmed() })
        let analysis = try await analyzer.analyze(dataset)
        let specification = AutoChartSpecification.histogram(value: v2Measure.id)

        try #require(await gate.arm())
        let pending = Task { try await analysis.prepare(specification) }
        try await gate.waitUntilBlocked()
        await analyzer.removeAll()
        await gate.resume()

        let prepared = try await pending.value
        #expect(prepared.validation.isValid)
        #expect(!Task.isCancelled)
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func removeAllRetriesUncancelledPreparedChartWaiters() {}
    #endif

    /// An invalid specification reports its issues rather than surfacing as a
    /// thrown preparation error the caller has to unwrap.
    @Test func asyncValidationReportsInvalidSpecificationsWithoutThrowing() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        // A donut needs its measure on `y`; without one it cannot compose.
        let invalid = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: v2Category.id),
            aggregation: .sum)

        let entriesBefore = await analyzer.cacheStatistics.preparedCharts.entries
        let validation = try await analysis.validation(for: invalid)
        #expect(!validation.isValid)
        #expect(validation.issues.contains { $0.severity == .error })
        // Documented on `validation(for:)`: only a valid specification is left
        // in the cache, so a rejected candidate cannot evict a wanted entry.
        #expect(await analyzer.cacheStatistics.preparedCharts.entries == entriesBefore)
    }

    #if ATC_TEST_HOOKS
    /// Converting an invalid preparation into a validation result must not
    /// override cancellation that arrived while that preparation was running.
    @Test func asyncValidationPreservesCancellationForInvalidSpecifications() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(-1)]])
        let analyzer = AutoChartAnalyzer(
            testHooks: .chartPreparation { await gate.waitWhenArmed() })
        let analysis = try await analyzer.analyze(dataset)
        let invalid = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: v2Category.id, y: v2Measure.id),
            aggregation: .sum)
        let missesBefore = await analyzer.cacheStatistics.preparedCharts.misses
        try #require(await gate.arm())
        let completed = DispatchSemaphore(value: 0)
        let pending = Task {
            defer { completed.signal() }
            return try await analysis.validation(for: invalid)
        }

        // The barrier runs after the cache miss is registered but before the
        // invalid result is produced, so cancellation deterministically reaches
        // `validation(for:)`'s invalid-result conversion path.
        try await gate.waitUntilBlocked()
        #expect(await analyzer.cacheStatistics.preparedCharts.misses == missesBefore + 1)
        pending.cancel()
        let returnedWhilePreparationWasBlocked = await receivesSignalPromptly(completed)
        await gate.resume()

        #expect(returnedWhilePreparationWasBlocked)
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func asyncValidationPreservesCancellationForInvalidSpecifications() {}
    #endif

    #if ATC_TEST_HOOKS
    @Test func prepareCancellationTakesPriorityOverInvalidSpecification() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(-1)]])
        let analyzer = AutoChartAnalyzer(
            testHooks: .chartPreparation { await gate.waitWhenArmed() })
        let analysis = try await analyzer.analyze(dataset)
        let invalid = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: v2Category.id, y: v2Measure.id),
            aggregation: .sum)
        try #require(await gate.arm())
        let completed = DispatchSemaphore(value: 0)
        let pending = Task {
            defer { completed.signal() }
            return try await analysis.prepare(invalid)
        }

        try await gate.waitUntilBlocked()
        pending.cancel()
        let returnedWhilePreparationWasBlocked = await receivesSignalPromptly(completed)
        await gate.resume()

        #expect(returnedWhilePreparationWasBlocked)
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
    }
    #else
    @Test(.disabled(testHooksUnavailable))
    func prepareCancellationTakesPriorityOverInvalidSpecification() {}
    #endif

    @Test func generationRetryExhaustionHasADistinctError() async {
        let attempts = InvocationCounter()

        do {
            let _: Int = try await AutoChartAnalyzer.retryingGenerationInvalidations {
                await attempts.increment()
                throw AutoChartAnalyzer.GenerationInvalidatedError()
            }
            Issue.record("Generation invalidation retries unexpectedly succeeded.")
        } catch let error as AutoChartAnalyzerError {
            #expect(error == .resetRetryLimitExceeded(maximumRetries: 3))
        } catch {
            Issue.record("Unexpected retry exhaustion error: \(error)")
        }
        #expect(await attempts.count == 4)
    }

    @Test func malformedAutoChartValueRepresentationsAreRejected() {
        for malformed in [
            #"{"null":123}"#,
            #"{"decimal":{"_0":"inf"}}"#,
            #"{"decimal":{"_0":"-inf"}}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    AutoChartValue.self,
                    from: Data(malformed.utf8))
            }
        }
    }

    @Test func nonFiniteAutoChartValuesHaveStableEqualityHashingAndCoding() throws {
        let values: [AutoChartValue] = [
            .double(.nan),
            .decimal(.nan),
            .date(Date(timeIntervalSinceReferenceDate: .nan)),
        ]
        for value in values {
            #expect(value == value)
            #expect(Set([value, value]).count == 1)
            let decoded = try JSONDecoder().decode(
                AutoChartValue.self,
                from: JSONEncoder().encode(value))
            #expect(decoded == value)
            #expect(decoded.hashValue == value.hashValue)
        }

        #expect(AutoChartValue.double(0) == .double(-0.0))
        #expect(AutoChartValue.double(0).hashValue == AutoChartValue.double(-0.0).hashValue)
    }

    @Test func corruptLegacyRecommendationIDsFailDecodingInsteadOfTrapping() throws {
        for corrupt in ["\"-1:a\"", "\"999:a\"", "\"junk\""] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    AutoChartRecommendationID.self, from: Data(corrupt.utf8))
            }
        }
        let legacy = try JSONDecoder().decode(
            AutoChartRecommendationID.self, from: Data("\"1:7|3:bar\"".utf8))
        #expect(legacy.policyVersion == 7)
        #expect(legacy.specificationID.rawValue == "3:bar")
    }

    @Test func negativeCacheLimitsAreClampedEverywhere() async throws {
        let limit = try JSONDecoder().decode(
            AutoChartCacheLimit.self, from: Data(#"{"maximumEntries":-1}"#.utf8))
        #expect(limit.maximumEntries == 0)

        var mutated = AutoChartCacheLimit(maximumEntries: 3)
        mutated.maximumEntries = -5
        #expect(mutated.maximumEntries == 0)

        let configJSON = #"""
            {"tables":{"maximumEntries":-1},"analyses":{"maximumEntries":16},
             "preparedCharts":{"maximumEntries":16},"maximumRetainedCost":-9}
            """#
        let configuration = try JSONDecoder().decode(
            AutoChartAnalyzerConfiguration.self, from: Data(configJSON.utf8))
        #expect(configuration.tables.maximumEntries == 0)
        #expect(configuration.maximumRetainedCost == 0)

        let analyzer = AutoChartAnalyzer(configuration: configuration)
        await analyzer.trim(to: .configuredLimits)
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]])
        _ = try await analyzer.analyze(dataset)
    }

    @Test func nonFiniteValuesRoundTripThroughDatasetCoding() throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [
                [.text("A"), .double(.infinity)],
                [.text("B"), .double(-.infinity)],
                [.text("C"), .decimal(.nan)],
                [.date(Date(timeIntervalSinceReferenceDate: .infinity)), .double(1)],
            ])
        let encoded = try JSONEncoder().encode(dataset)
        let decoded = try JSONDecoder().decode(AutoChartDataset<Int>.self, from: encoded)
        let values = decoded.chartRows.map { $0.chartValue(for: v2Measure.id) }
        #expect(values[0] == .double(.infinity))
        #expect(values[1] == .double(-.infinity))
        guard case .decimal(let notANumber) = values[2] else {
            Issue.record("Expected a decimal value.")
            return
        }
        #expect(notANumber.isNaN)
        guard case .date(let date) = decoded.chartRows[3].chartValue(for: v2Category.id)
        else {
            Issue.record("Expected a date value.")
            return
        }
        #expect(date.timeIntervalSinceReferenceDate == .infinity)
    }

    @Test func distinctDataKeysNeverCollideThroughConcatenation() async throws {
        let analyzer = AutoChartAnalyzer()
        let first = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)]],
            key: .init(identity: "sales:2024", revision: "1"))
        let second = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]],
            key: .init(identity: "sales", revision: "2024:1"))
        let firstAnalysis = try await analyzer.analyze(first)
        let secondAnalysis = try await analyzer.analyze(second)
        #expect(try #require(firstAnalysis.primaryChart).marks.count == 1)
        #expect(try #require(secondAnalysis.primaryChart).marks.count == 2)
    }

    @Test func callerSpecificationPreparationKeepsRecommendationMetadataDistinct()
        async throws
    {
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]],
            key: .init(identity: "metadata", revision: "1"))
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(dataset)
        guard case .charts(let recommendations) = analysis.outcome,
            let primary = recommendations.first
        else {
            Issue.record("Expected chart recommendations.")
            return
        }
        let caller = try await analysis.prepare(primary.specification)
        #expect(caller.recommendation.score == 0)
        let prepared = try await analysis.prepare(primary.id)
        #expect(prepared.recommendation == primary)
        #expect(await analyzer.cacheStatistics.preparedCharts.entries == 1)
    }

    @Test func truncatedCallerSpecificationsCarryTheIncompleteResultCaution()
        async throws
    {
        let x = AutoChartColumn(
            id: "x", name: "X",
            hints: .init(semanticType: .quantitative, role: .measure))
        let y = AutoChartColumn(
            id: "y", name: "Y",
            hints: .init(semanticType: .quantitative, role: .measure))
        let dataset = try AutoChartDataset<Int>(
            columns: [x, y],
            rows: (0..<20).map { [.double(Double($0)), .double(Double($0 * 2))] },
            metadata: .init(isTruncated: true))
        let analysis = try await AutoChartAnalyzer().analyze(dataset)
        let prepared = try await analysis.prepare(.scatter(x: "x", y: "y"))
        #expect(prepared.diagnostics.contains {
            $0.severity == .warning && $0.messageValue.code == .incompleteResult
        })
        if let primary = analysis.primaryChart {
            let cautions = primary.diagnostics.filter {
                $0.messageValue.code == .incompleteResult
            }
            #expect(cautions.count == 1)
        }
    }

    @Test func upstreamMeanMeasuresAreNotSummedDespiteAdditiveRollup() async throws {
        func recommendations(
            source: AutoChartMeasureSource
        ) async throws -> [AutoChartRecommendation] {
            let measure = AutoChartColumn(
                id: "measure", name: "Value",
                hints: .init(
                    semanticType: .quantitative,
                    role: .measure,
                    measureSemantics: .init(source: source, rollup: .additive)))
            let dataset = try AutoChartDataset<Int>(
                columns: [v2Category, measure],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("A"), .double(2)],
                    [.text("B"), .double(3)],
                ])
            let analysis = try await AutoChartAnalyzer(configuration: .uncached)
                .analyze(dataset)
            guard case .charts(let recommendations) = analysis.outcome else { return [] }
            return recommendations
        }
        let summed = try await recommendations(source: .aggregated(.sum))
        #expect(summed.contains { $0.specification.aggregation == .sum })
        let meaned = try await recommendations(source: .aggregated(.mean))
        #expect(!meaned.contains { $0.specification.aggregation == .sum })
    }

    @Test func subDayTemporalValuesFormatDistinctly() {
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US"), timeZone: .gmt)
        let midnight = Date(timeIntervalSince1970: 1_699_920_000)
        let first = formatters.format(
            column: nil, value: .date(midnight), context: .axisTick)
        let second = formatters.format(
            column: nil,
            value: .date(midnight.addingTimeInterval(6 * 3_600)),
            context: .axisTick)
        let third = formatters.format(
            column: nil,
            value: .date(midnight.addingTimeInterval(12 * 3_600)),
            context: .axisTick)
        #expect(second != first)
        #expect(third != second)
        #expect(!first.contains(":"))
        let nonFinite = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(
            AutoChartDateFormatting.precision(
                for: nonFinite,
                locale: formatters.locale,
                timeZone: formatters.timeZone) == .date)
        #expect(
            AutoChartDateFormatting.string(
                nonFinite,
                locale: formatters.locale,
                timeZone: formatters.timeZone)
                == AutoChartValue.unrepresentableValuePlaceholder)
    }
}
