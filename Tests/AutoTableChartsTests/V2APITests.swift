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
    }

    @Test func resolutionReportsExactAndPolicyDefaulting() async throws {
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
            policyVersion: primary.id.policyVersion - 1,
            specificationID: primary.specification.id)
        guard case .defaulted(let defaulted, reason: .policyVersionChanged) =
            analysis.resolve(stale)
        else {
            Issue.record("Expected policy-version default")
            return
        }
        #expect(defaulted.id == primary.id)

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
        let dataset = try AutoChartDataset<Int>(
            columns: [v2Category, v2Measure],
            rows: (0..<2_000).map { [.text("Category \($0 % 25)"), .double(Double($0))] })
        let analyzer = AutoChartAnalyzer()
        let task = Task { try await analyzer.analyze(dataset) }
        await analyzer.removeAll()
        let analysis = try await task.value
        #expect(analysis.primaryChart != nil)
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
