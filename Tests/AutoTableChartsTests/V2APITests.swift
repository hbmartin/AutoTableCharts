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

private final class FirstRowReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var reads = 0

    func read<Row>(_ rows: [Row]) -> [Row] {
        lock.lock()
        reads += 1
        let shouldBlock = reads == 1
        lock.unlock()
        if shouldBlock {
            entered.signal()
            release.wait()
        }
        return rows
    }

    func waitUntilFirstRead() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func resumeFirstRead() {
        release.signal()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

private actor OneShotPreparationGate {
    private var armed = false
    private var blocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func arm() {
        armed = true
    }

    func waitWhenArmed() async {
        guard armed else { return }
        armed = false
        blocked = true
        let waiters = enteredContinuations
        enteredContinuations.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func resume() {
        blocked = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor InvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func receivesSignalPromptly(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}

private struct FirstReadBlockingTable: AutoChartTable {
    let rows: [DuplicateIDRow]
    let gate: FirstRowReadGate
    let chartColumns = [v2Measure]
    let chartMetadata = AutoChartTableMetadata()

    var chartRows: [DuplicateIDRow] { gate.read(rows) }
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
        #expect(AutoTableCharts.recommendationPolicyVersion == 10)
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
            policyVersion: 9,
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
        #expect(previous == 9)
        #expect(current == 10)

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

    #if canImport(Charts) && canImport(SwiftUI)
    @Test func previewUsesExactHeightAndIndependentControls() {
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

    @Test func removeAllDoesNotFailConcurrentAnalyzeCallers() async throws {
        let gate = FirstRowReadGate()
        let table = FirstReadBlockingTable(
            rows: (0..<2_000).map {
                DuplicateIDRow(chartRowID: $0, value: Double($0))
            },
            gate: gate)
        let analyzer = AutoChartAnalyzer()
        let task = Task { try await analyzer.analyze(table) }

        await gate.waitUntilFirstRead()
        #expect(await analyzer.cacheStatistics.inFlightRequests == 1)
        await analyzer.removeAll()
        gate.resumeFirstRead()
        let analysis = try await task.value

        #expect(analysis.primaryChart != nil)
        #expect(gate.readCount >= 2)
        #expect(await analyzer.cacheStatistics.inFlightRequests == 0)
    }

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

    /// A memory trim must release memory: work already in flight when the host
    /// trimmed must not repopulate the cache it was asked to empty, and it must
    /// still hand its caller a result.
    @Test func trimStopsInFlightWorkFromRepopulatingTheCache() async throws {
        let gate = FirstRowReadGate()
        let table = FirstReadBlockingTable(
            rows: (0..<2_000).map {
                DuplicateIDRow(chartRowID: $0, value: Double($0))
            },
            gate: gate)
        let analyzer = AutoChartAnalyzer()
        let pending = Task { try await analyzer.analyze(table) }

        await gate.waitUntilFirstRead()
        #expect(await analyzer.cacheStatistics.inFlightRequests == 1)
        await analyzer.trim(to: .minimum)
        gate.resumeFirstRead()
        let analysis = try await pending.value

        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.entries == 0)
        #expect(statistics.analyses.entries == 0)
        #expect(statistics.preparedCharts.entries == 0)
        // The caller still gets its analysis; only caching was suppressed.
        #expect(analysis.primaryChart != nil)
    }

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

    @Test func removeAllRetriesUncancelledPreparedChartWaiters() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let analyzer = AutoChartAnalyzer {
            await gate.waitWhenArmed()
        }
        let analysis = try await analyzer.analyze(dataset)
        let specification = AutoChartSpecification.histogram(value: v2Measure.id)

        await gate.arm()
        let pending = Task { try await analysis.prepare(specification) }
        await gate.waitUntilBlocked()
        await analyzer.removeAll()
        await gate.resume()

        let prepared = try await pending.value
        #expect(prepared.validation.isValid)
        #expect(!Task.isCancelled)
    }

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

    /// Converting an invalid preparation into a validation result must not
    /// override cancellation that arrived while that preparation was running.
    @Test func asyncValidationPreservesCancellationForInvalidSpecifications() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<2_000).map {
                [.text("Category \($0)"), .double(-1)]
            })
        let analyzer = AutoChartAnalyzer {
            await gate.waitWhenArmed()
        }
        let analysis = try await analyzer.analyze(dataset)
        let invalid = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: v2Category.id, y: v2Measure.id),
            aggregation: .sum)
        let missesBefore = await analyzer.cacheStatistics.preparedCharts.misses
        await gate.arm()
        let completed = DispatchSemaphore(value: 0)
        let pending = Task {
            defer { completed.signal() }
            return try await analysis.validation(for: invalid)
        }

        // The barrier runs after the cache miss is registered but before the
        // invalid result is produced, so cancellation deterministically reaches
        // `validation(for:)`'s invalid-result conversion path.
        await gate.waitUntilBlocked()
        #expect(await analyzer.cacheStatistics.preparedCharts.misses == missesBefore + 1)
        pending.cancel()
        let returnedWhilePreparationWasBlocked = await receivesSignalPromptly(completed)
        await gate.resume()

        #expect(returnedWhilePreparationWasBlocked)
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
    }

    @Test func prepareCancellationTakesPriorityOverInvalidSpecification() async throws {
        let gate = OneShotPreparationGate()
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<2_000).map {
                [.text("Category \($0)"), .double(-1)]
            })
        let analyzer = AutoChartAnalyzer {
            await gate.waitWhenArmed()
        }
        let analysis = try await analyzer.analyze(dataset)
        let invalid = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: v2Category.id, y: v2Measure.id),
            aggregation: .sum)
        await gate.arm()
        let completed = DispatchSemaphore(value: 0)
        let pending = Task {
            defer { completed.signal() }
            return try await analysis.prepare(invalid)
        }

        await gate.waitUntilBlocked()
        pending.cancel()
        let returnedWhilePreparationWasBlocked = await receivesSignalPromptly(completed)
        await gate.resume()

        #expect(returnedWhilePreparationWasBlocked)
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
    }

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
    }
}
