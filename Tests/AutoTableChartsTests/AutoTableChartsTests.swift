import Foundation
import Testing

@testable import AutoTableCharts

private struct TestRow: AutoChartRow {
    var chartRowID: AutoChartRowID
    var values: [AutoChartColumnID: AutoChartValue]

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        values[columnID] ?? .null
    }
}

private struct TestTable: AutoChartTable {
    var chartColumns: [AutoChartColumn]
    var chartRows: [TestRow]
    var chartMetadata = AutoChartTableMetadata()
}

private func table(
    columns: [AutoChartColumn],
    rows: [[AutoChartValue]],
    truncated: Bool = false
) -> TestTable {
    precondition(
        rows.allSatisfy { $0.count == columns.count },
        "Every test row must contain exactly one value per column.")
    return TestTable(
        chartColumns: columns,
        chartRows: rows.enumerated().map { index, values in
            TestRow(
                chartRowID: AutoChartRowID(rawValue: "r\(index)"),
                values: Dictionary(
                    uniqueKeysWithValues: zip(columns, values).map { ($0.id, $1) }))
        },
        chartMetadata: AutoChartTableMetadata(isTruncated: truncated))
}

private let category = AutoChartColumn(
    id: "category", name: "property_type",
    hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
private let measure = AutoChartColumn(
    id: "measure", name: "current_market_value",
    hints: AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .currency(code: "USD"),
        aggregation: .sum,
        aggregationSafety: .alreadyAggregated))
private let date = AutoChartColumn(
    id: "date", name: "valuation_date",
    hints: AutoChartColumnHints(semanticType: .temporal, role: .dimension))

@Suite struct ModelTests {
    @Test func numericValuesRejectNonFiniteDecimals() {
        #expect(AutoChartValue.decimal(.nan).numericValue == nil)
        #expect(AutoChartValue.double(.infinity).numericValue == nil)
    }

    @Test func optionsClampInitializationMutationAndDecoding() throws {
        var options = AutoChartOptions(
            maximumRecommendations: 0,
            maximumCategories: 0,
            maximumDonutSectors: 0,
            maximumSeries: 0,
            maximumFacets: 0)
        options.maximumRecommendations = 0
        options.maximumCategories = 0
        options.maximumDonutSectors = 0
        options.maximumSeries = 0
        options.maximumFacets = 0
        let mutatedLimits: [Int] = [
            options.maximumRecommendations,
            options.maximumCategories,
            options.maximumDonutSectors,
            options.maximumSeries,
            options.maximumFacets,
        ]
        #expect(mutatedLimits == [1, 2, 2, 2, 2])

        let encoded = Data(
            #"{"maximumRecommendations":0,"maximumCategories":0,"maximumDonutSectors":0,"maximumSeries":0,"maximumFacets":0}"#
                .utf8)
        let decoded = try JSONDecoder().decode(AutoChartOptions.self, from: encoded)
        let decodedLimits: [Int] = [
            decoded.maximumRecommendations,
            decoded.maximumCategories,
            decoded.maximumDonutSectors,
            decoded.maximumSeries,
            decoded.maximumFacets,
        ]
        #expect(decodedLimits == [1, 2, 2, 2, 2])
    }

    @Test func specificationIDsEncodeSeparatorsAndOptionalBinCounts() {
        let first = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "a|b", y: "c"))
        let second = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "a", y: "b|c"))
        let noBins = AutoChartSpecification(family: .histogram, binCount: nil)
        let zeroBins = AutoChartSpecification(family: .histogram, binCount: 0)
        #expect(first.id != second.id)
        #expect(noBins.id != zeroBins.id)
    }

    @Test func snapshotFingerprintTracksTableContent() {
        let first = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(1)]]))
        let identical = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(1)]]))
        let changedValue = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(2)]]))
        let changedRow = TestTable(
            chartColumns: [measure],
            chartRows: [
                TestRow(chartRowID: "different", values: [measure.id: .double(1)])
            ])
        #expect(first.contentFingerprint == identical.contentFingerprint)
        #expect(first.contentFingerprint != changedValue.contentFingerprint)
        #expect(first.contentFingerprint != AutoChartSnapshot(changedRow).contentFingerprint)
    }

    @Test func dateDisplayAndAccessibilityUseGMTLocalizedFormatting() throws {
        let value = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let expectedDate = value.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .omitted,
                timeZone: TimeZone.gmt))
        #expect(AutoChartValue.date(value).displayString == expectedDate)

        let expectedAccessibleDate = value.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                timeZone: TimeZone.gmt))
        let datum = AutoChartDatum(
            id: "date",
            sourceRowIDs: ["r0"],
            xDate: value,
            yNumber: 2)
        #expect(datum.accessibilityLabel == "\(expectedAccessibleDate), 2")
        #expect(!datum.accessibilityLabel.contains("T00:00:00Z"))
    }

    @Test func accessibilityLabelsIncludeSeriesContext() {
        let datum = AutoChartDatum(
            id: "series",
            sourceRowIDs: ["r0"],
            xLabel: "Office",
            yNumber: 2,
            series: "North")
        #expect(datum.accessibilityLabel == "Office, North, 2")
    }
}

@Suite struct ProfilingTests {
    @Test func explicitHintsOverrideValueInference() {
        let ordinal = AutoChartColumn(
            id: "year", name: "year",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [ordinal], rows: [[.integer(2024)], [.integer(2025)]]))
        #expect(AutoChartProfiler.profiles(snapshot)[0].semanticType == .ordinal)
    }

    @Test func isoDateTextIsTemporal() {
        let inferred = AutoChartColumn(id: "observed", name: "observed")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [inferred],
                rows: [[.text("2026-01-01")], [.text("2026-02-01")]]))
        #expect(AutoChartProfiler.profiles(snapshot)[0].semanticType == .temporal)
    }

    @Test func invalidCalendarDatesAreRejected() {
        #expect(AutoChartProfiler.parseISODate("2026-02-29") == nil)
        #expect(AutoChartProfiler.parseISODate("2024-02-29") != nil)
    }

    @Test func abbreviatedAndCodeLikeDatesAreRejected() {
        #expect(AutoChartProfiler.parseISODate("1-2-3") == nil)
        #expect(AutoChartProfiler.parseISODate("10-11-12") == nil)
        #expect(AutoChartProfiler.parseISODate("0001-02-03") != nil)
    }

    @Test func duplicateColumnIDsAreDeduplicatedAtSnapshotBoundary() {
        let first = AutoChartColumn(
            id: "duplicate", name: "first",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let second = AutoChartColumn(
            id: "duplicate", name: "second",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let input = TestTable(
            chartColumns: [first, second],
            chartRows: [TestRow(chartRowID: "r0", values: ["duplicate": .double(1)])])
        let snapshot = AutoChartSnapshot(input)
        #expect(snapshot.columns.map(\.name) == ["first"])
        #expect(AutoChartProfiler.profiles(snapshot).count == 1)
        #expect(
            AutoChartEngine.validate(
                specification: AutoChartSpecification(
                    family: .histogram,
                    encoding: AutoChartEncoding(x: "duplicate"),
                    aggregation: .count),
                for: input
            ).isValid)
    }

    @Test func identifiersAndBinaryAreNotMeasures() {
        let identifier = AutoChartColumn(id: "property_id", name: "property_id")
        let blob = AutoChartColumn(id: "payload", name: "payload")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [identifier, blob],
                rows: [[.integer(1), .binary(Data([1]))]]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        #expect(profiles[0].semanticType == .identifier)
        #expect(profiles[1].semanticType == .unsupported)
    }

    @Test func camelCaseIdentifiersAndYearMeasuresAreInferredConservatively() {
        let identifier = AutoChartColumn(id: "propertyId", name: "propertyId")
        let revenue = AutoChartColumn(id: "revenue", name: "yearly_revenue")
        let year = AutoChartColumn(id: "year", name: "fiscalYear")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [identifier, revenue, year],
                rows: [
                    [.integer(1001), .double(10), .integer(2025)],
                    [.integer(1002), .double(20), .integer(2026)],
                ]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        #expect(profiles[0].semanticType == .identifier)
        #expect(profiles[1].semanticType == .quantitative)
        #expect(profiles[2].semanticType == .ordinal)
    }

    @Test func mixedDateTextRemainsNominal() {
        let mixed = AutoChartColumn(id: "observed", name: "observed")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [mixed],
                rows: [
                    [.text("2026-01-01")],
                    [.text("2026-01-02")],
                    [.text("2026-01-03")],
                    [.text("2026-01-04")],
                    [.text("not-a-date")],
                ]))
        #expect(AutoChartProfiler.profiles(snapshot)[0].semanticType == .nominal)
    }

    @Test func nullsRemainVisibleInProfile() {
        let column = AutoChartColumn(id: "amount", name: "amount")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [column], rows: [[.double(1)], [.null]]))
        let profile = AutoChartProfiler.profiles(snapshot)[0]
        #expect(profile.nonNullCount == 1)
        #expect(profile.nullFraction == 0.5)
    }

    @Test func humanizedNamesReuseCamelCaseTokens() {
        #expect(AutoChartProfiler.humanized("propertyType") == "Property Type")
        #expect(AutoChartProfiler.humanized("current_market_value") == "Current Market Value")
        #expect(AutoChartProfiler.humanized("propertyId") == "Property ID")
    }
}

@Suite struct RecommendationTests {
    @Test func scalarUsesKPI() {
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [measure], rows: [[.double(42)]]))
        #expect(result.chartRecommendations.first?.specification.family == .kpi)
    }

    @Test func scalarKPIChoosesAPopulatedMeasure() {
        let empty = AutoChartColumn(
            id: "empty", name: "empty",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let populated = AutoChartColumn(
            id: "populated", name: "populated",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let input = table(
            columns: [empty, populated],
            rows: [[.null, .double(42)]])
        let result = AutoChartEngine.recommendations(for: input)
        #expect(result.chartRecommendations.first?.specification.family == .kpi)
        #expect(result.chartRecommendations.first?.specification.encoding.y == populated.id)

        let emptyKPI = AutoChartSpecification(
            family: .kpi,
            encoding: .init(y: empty.id))
        #expect(!AutoChartEngine.validate(specification: emptyKPI, for: input).isValid)
    }

    @Test func categoryMeasureUsesBarAndDonutAlternatives() {
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, measure],
                rows: [
                    [.text("Office"), .double(20)],
                    [.text("Retail"), .double(10)],
                    [.text("Industrial"), .double(15)],
                ]),
            context: AutoChartContext(goal: .composition))
        let families = Set(result.chartRecommendations.map(\.specification.family))
        #expect(families.contains(.bar))
        #expect(families.contains(.donut))
    }

    @Test func temporalMeasureUsesLine() {
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [date, measure],
                rows: [
                    [.text("2026-01-01"), .double(10)],
                    [.text("2026-02-01"), .double(12)],
                ]),
            context: AutoChartContext(goal: .trend))
        #expect(result.chartRecommendations.first?.specification.family == .line)
    }

    @Test func twoMeasuresUseScatter() {
        let second = AutoChartColumn(
            id: "second", name: "occupancy_rate",
            hints: AutoChartColumnHints(semanticType: .quantitative, role: .measure))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [measure, second],
                rows: [[.double(10), .double(0.8)], [.double(12), .double(0.9)]]),
            context: AutoChartContext(goal: .relationship))
        #expect(result.chartRecommendations.first?.specification.family == .scatter)
    }

    @Test func singleMeasureOffersHistogramAndBoxPlot() {
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [measure],
                rows: [[.double(1)], [.double(2)], [.double(4)], [.double(8)]]),
            context: AutoChartContext(goal: .distribution))
        let families = Set(result.chartRecommendations.map(\.specification.family))
        #expect(families.contains(.histogram))
        #expect(families.contains(.boxPlot))
    }

    @Test func categoricalPairOffersHeatmap() {
        let second = AutoChartColumn(
            id: "market", name: "market",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, second],
                rows: [
                    [.text("Office"), .text("Boston")],
                    [.text("Retail"), .text("Boston")],
                ]),
            context: AutoChartContext(goal: .relationship))
        #expect(result.chartRecommendations.contains { $0.specification.family == .heatmap })
    }

    @Test func temporalPairOffersRange() {
        let end = AutoChartColumn(
            id: "end", name: "expiration_date",
            hints: AutoChartColumnHints(semanticType: .temporal, role: .intervalEnd))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, date, end],
                rows: [[.text("Lease A"), .text("2026-01-01"), .text("2026-12-31")]]),
            context: AutoChartContext(goal: .range))
        #expect(result.chartRecommendations.contains { $0.specification.family == .range })
    }

    @Test func datedEventsWithMeasuresOfferRangeInsteadOfInvalidBubble() {
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [date, category, measure],
                rows: [
                    [.text("2026-01-01"), .text("A"), .double(1)],
                    [.text("2026-01-02"), .text("B"), .double(2)],
                ]),
            context: AutoChartContext(goal: .range))
        #expect(result.chartRecommendations.contains { $0.specification.family == .range })
        #expect(
            !result.chartRecommendations.contains {
                $0.specification.family == .bubble && $0.specification.encoding.size == nil
            })
    }

    @Test func truncatedResultsSuppressCompositionAndHeatmap() {
        let second = AutoChartColumn(
            id: "market", name: "market",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, second, measure],
                rows: [
                    [.text("Office"), .text("Boston"), .double(10)],
                    [.text("Retail"), .text("Denver"), .double(20)],
                ],
                truncated: true),
            context: AutoChartContext(goal: .composition))
        let families = Set(result.chartRecommendations.map(\.specification.family))
        #expect(!families.contains(.donut))
        #expect(!families.contains(.normalizedBar))
        #expect(!families.contains(.heatmap))
    }

    @Test func rankingIsStable() {
        let input = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let recommendations = AutoChartEngine.recommendations(for: input)
        #expect(
            recommendations.chartRecommendations.map(\.specification.family) == [
                .bar, .rankedDot, .boxPlot, .histogram, .donut,
            ])
    }

    @Test func unknownAggregationBlocksDuplicateCategoryBars() {
        let unsafeMeasure = AutoChartColumn(
            id: "raw", name: "raw_value",
            hints: AutoChartColumnHints(semanticType: .quantitative, role: .measure))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, unsafeMeasure],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("A"), .double(2)],
                ]))
        #expect(!result.chartRecommendations.contains { $0.specification.family == .bar })
    }

    @Test func nonadditiveAggregatesCannotBeRolledUpAcrossDuplicateCategories() {
        let mean = AutoChartColumn(
            id: "mean", name: "average_rent",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .measure,
                aggregation: .mean,
                aggregationSafety: .alreadyAggregated))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, mean],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("A"), .double(2)],
                ]))
        #expect(!result.chartRecommendations.contains { $0.specification.family == .bar })
    }

    @Test func safeRollupUsesTheExplicitAggregationWithoutEnablingComposition() {
        let average = AutoChartColumn(
            id: "average", name: "average_rent",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .measure,
                aggregation: .mean,
                aggregationSafety: .safe))
        let result = AutoChartEngine.recommendations(
            for: table(
                columns: [category, average],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("A"), .double(3)],
                ]))
        #expect(
            result.chartRecommendations.first {
                $0.specification.family == .bar
            }?.specification.aggregation == .mean)
        #expect(
            !result.chartRecommendations.contains {
                [.donut, .stackedBar, .normalizedBar].contains($0.specification.family)
            })
    }

    @Test func preaggregatedCountsRollUpBySummingValues() {
        let count = AutoChartColumn(
            id: "count", name: "count",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                aggregation: .count,
                aggregationSafety: .alreadyAggregated))
        let input = table(
            columns: [category, count],
            rows: [
                [.text("A"), .double(2)],
                [.text("A"), .double(3)],
            ])
        let recommendation = AutoChartEngine.recommendations(for: input)
            .chartRecommendations.first { $0.specification.family == .bar }
        #expect(recommendation?.specification.aggregation == .sum)
        let data = recommendation.map {
            AutoChartDataPreparation.data(
                snapshot: AutoChartSnapshot(input),
                specification: $0.specification)
        }
        #expect(data?.first?.yNumber == 5)

        let wrongCount = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: count.id),
            aggregation: .count)
        #expect(!AutoChartEngine.validate(specification: wrongCount, for: input).isValid)

        let donut = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: count.id),
            aggregation: .sum)
        #expect(AutoChartEngine.validate(specification: donut, for: input).isValid)
    }

    @Test func distinctCountsAreNotCompositionSafeOrImplicitlyRollable() {
        let distinctCount = AutoChartColumn(
            id: "distinct", name: "distinct",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                aggregation: .countDistinct,
                aggregationSafety: .alreadyAggregated))
        let input = table(
            columns: [category, distinctCount],
            rows: [
                [.text("A"), .double(2)],
                [.text("A"), .double(3)],
                [.text("B"), .double(4)],
            ])
        let result = AutoChartEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition))
        #expect(!result.chartRecommendations.contains { $0.specification.family == .donut })
        #expect(!result.chartRecommendations.contains { $0.specification.family == .bar })
    }

    @Test func rowLevelSafeCountsProduceCountAggregatedDonuts() {
        let count = AutoChartColumn(
            id: "count", name: "count",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                aggregation: .count,
                aggregationSafety: .safe))
        let input = table(
            columns: [category, count],
            rows: [
                [.text("A"), .double(10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let donut = AutoChartEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition)
        ).chartRecommendations.first { $0.specification.family == .donut }
        #expect(donut?.specification.aggregation == .count)
        let data = donut.map {
            AutoChartDataPreparation.data(
                snapshot: AutoChartSnapshot(input),
                specification: $0.specification)
        }
        #expect(
            Dictionary(
                uniqueKeysWithValues: data?.compactMap { datum in
                    guard let label = datum.xLabel, let value = datum.yNumber else { return nil }
                    return (label, value)
                } ?? []) == ["A": 2, "B": 1])
    }

    @Test func intervalEndHintsDoNotBecomeRangeStarts() {
        let end = AutoChartColumn(
            id: "end", name: "end",
            hints: AutoChartColumnHints(
                semanticType: .temporal,
                role: .intervalEnd))
        let start = AutoChartColumn(
            id: "start", name: "start",
            hints: AutoChartColumnHints(semanticType: .temporal))
        let input = table(
            columns: [end, start, category],
            rows: [[.text("2026-12-31"), .text("2026-01-01"), .text("A")]])
        let range = AutoChartEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .range)
        ).chartRecommendations.first { $0.specification.family == .range }
        #expect(range?.specification.encoding.start == start.id)
        #expect(range?.specification.encoding.end == end.id)
    }

    @Test func datedEventSeriesRespectMaximumSeries() {
        let highCardinality = AutoChartColumn(
            id: "event", name: "event",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [date, highCardinality, measure],
            rows: [
                [.text("2026-01-01"), .text("A"), .double(1)],
                [.text("2026-01-02"), .text("B"), .double(2)],
                [.text("2026-01-03"), .text("C"), .double(3)],
            ])
        let result = AutoChartEngine.recommendations(
            for: input,
            options: AutoChartOptions(maximumSeries: 2))
        #expect(
            !result.chartRecommendations.contains {
                $0.specification.family == .scatter
                    && $0.specification.encoding.series == highCardinality.id
            })
    }
}

@Suite struct ValidationAndLineageTests {
    @Test func everyDeclaredFamilyValidatesAndPreparesMarks() {
        let series = AutoChartColumn(
            id: "series", name: "market",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .series))
        let facet = AutoChartColumn(
            id: "facet", name: "fund",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let end = AutoChartColumn(
            id: "end", name: "expiration_date",
            hints: AutoChartColumnHints(
                semanticType: .temporal, role: .intervalEnd))
        let secondMeasure = AutoChartColumn(
            id: "second", name: "current_balance",
            hints: AutoChartColumnHints(
                semanticType: .quantitative, role: .measure,
                aggregationSafety: .rowLevel))
        let size = AutoChartColumn(
            id: "size", name: "rentable_sqft",
            hints: AutoChartColumnHints(
                semanticType: .quantitative, role: .measure,
                aggregationSafety: .rowLevel))
        let input = table(
            columns: [category, series, facet, date, end, measure, secondMeasure, size],
            rows: [
                [
                    .text("Office"), .text("Boston"), .text("Core"),
                    .text("2026-01-01"), .text("2026-07-01"),
                    .double(20), .double(12), .double(100),
                ],
                [
                    .text("Retail"), .text("Denver"), .text("Value-Add"),
                    .text("2026-02-01"), .text("2026-10-01"),
                    .double(10), .double(7), .double(60),
                ],
                [
                    .text("Industrial"), .text("Boston"), .text("Core"),
                    .text("2026-03-01"), .text("2027-01-01"),
                    .double(15), .double(9), .double(80),
                ],
            ])
        let xy = AutoChartEncoding(x: category.id, y: measure.id)
        let grouped = AutoChartEncoding(
            x: category.id, y: measure.id, series: series.id)
        let specifications: [AutoChartSpecification] = [
            .init(family: .table),
            .init(family: .kpi, encoding: .init(y: measure.id)),
            .init(family: .bar, encoding: xy),
            .init(family: .rankedDot, encoding: xy),
            .init(family: .groupedBar, encoding: grouped),
            .init(family: .stackedBar, encoding: grouped, stacking: .standard),
            .init(family: .normalizedBar, encoding: grouped, stacking: .normalized),
            .init(family: .line, encoding: .init(x: date.id, y: measure.id)),
            .init(family: .pointLine, encoding: .init(x: date.id, y: measure.id)),
            .init(family: .area, encoding: .init(x: date.id, y: measure.id)),
            .init(family: .scatter, encoding: .init(x: measure.id, y: secondMeasure.id)),
            .init(
                family: .bubble,
                encoding: .init(
                    x: measure.id, y: secondMeasure.id, size: size.id)),
            .init(
                family: .histogram, encoding: .init(x: measure.id),
                aggregation: .count, binCount: 5),
            .init(family: .boxPlot, encoding: xy),
            .init(
                family: .heatmap,
                encoding: .init(x: category.id, y: series.id),
                aggregation: .count),
            .init(family: .donut, encoding: xy, aggregation: .sum),
            .init(
                family: .range,
                encoding: .init(
                    x: category.id, start: date.id, end: end.id)),
            .init(
                family: .faceted,
                encoding: .init(
                    x: date.id, y: measure.id, facet: facet.id)),
        ]

        #expect(Set(specifications.map(\.family)) == Set(AutoChartFamily.allCases))
        for specification in specifications {
            let validationInput =
                specification.family == .kpi
                ? table(columns: [measure], rows: [[.double(20)]])
                : input
            #expect(
                AutoChartEngine.validate(
                    specification: specification, for: validationInput
                ).isValid,
                "\(specification.family) should validate")
            #expect(
                !AutoChartDataPreparation.data(
                    snapshot: AutoChartSnapshot(validationInput),
                    specification: specification
                ).isEmpty,
                "\(specification.family) should prepare data")
        }
    }

    @Test func invalidManualSpecificationReportsErrors() {
        let input = table(columns: [category], rows: [[.text("A")]])
        let spec = AutoChartSpecification(
            family: .scatter,
            encoding: AutoChartEncoding(x: category.id, y: category.id))
        let validation = AutoChartEngine.validate(specification: spec, for: input)
        #expect(!validation.isValid)
        #expect(!validation.issues.isEmpty)
    }

    @Test func familySpecificEncodingsAndDuplicateLineMarksAreValidated() {
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [category, facet, date, measure],
            rows: [
                [.text("A"), .text("One"), .text("2026-01-01"), .double(1)],
                [.text("B"), .text("Two"), .text("2026-01-01"), .double(2)],
            ])
        let bubble = AutoChartSpecification(
            family: .bubble,
            encoding: AutoChartEncoding(x: measure.id, y: measure.id, size: category.id))
        let range = AutoChartSpecification(
            family: .range,
            encoding: AutoChartEncoding(x: measure.id, start: date.id, end: date.id))
        let faceted = AutoChartSpecification(
            family: .faceted,
            encoding: AutoChartEncoding(x: date.id, facet: facet.id))
        let line = AutoChartSpecification(
            family: .line,
            encoding: AutoChartEncoding(x: date.id, y: measure.id))
        #expect(!AutoChartEngine.validate(specification: bubble, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: range, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: faceted, for: input).isValid)
        #expect(
            AutoChartEngine.validate(
                specification: line, for: input
            ).issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func truncatedCompositionReportsOneCompletenessIssue() {
        let input = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]],
            truncated: true)
        let specification = AutoChartSpecification(
            family: .donut,
            encoding: AutoChartEncoding(x: category.id, y: measure.id),
            aggregation: .sum)
        let issues = AutoChartEngine.validate(
            specification: specification, for: input
        ).issues
        #expect(issues.map(\.message) == ["Composition charts require a complete result."])
    }

    @Test func histogramBinsRetainSourceRowIDs() {
        let input = table(
            columns: [measure], rows: [[.double(1)], [.double(2)], [.double(3)]])
        let spec = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 2)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: spec)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == 3)
    }

    @Test func nullMeasuresAreOmittedRatherThanRenderedAsZero() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .null],
                [.text("B"), .double(2)],
            ])
        let spec = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: category.id, y: measure.id))
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: spec)
        #expect(data.count == 1)
        #expect(data.first?.xLabel == "B")
        #expect(data.first?.yNumber == 2)
    }

    @Test func groupedMarksRetainAllContributingRows() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("A"), .double(2)],
            ])
        let spec = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: category.id, y: measure.id),
            aggregation: .sum)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: spec)
        #expect(data.count == 1)
        #expect(data[0].yNumber == 3)
        #expect(data[0].sourceRowIDs == ["r0", "r1"])
    }

    @Test func boxPlotsExcludeNullMeasuresFromLineage() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("A"), .null],
                [.text("A"), .double(3)],
            ])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: category.id, y: measure.id))
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        #expect(data.first?.sourceRowIDs == ["r0", "r2"])
        #expect(data.first?.median == 2)
    }

    @Test func groupedMarksPreserveFirstSourceOrder() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("B"), .double(1)],
                [.text("A"), .double(2)],
                [.text("B"), .double(3)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: category.id, y: measure.id),
            aggregation: .sum,
            sort: .source)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(data.map(\.xLabel) == ["B", "A"])
        #expect(data.map(\.yNumber) == [4, 2])
    }

    @Test func histogramHandlesOverflowingFiniteRanges() {
        let input = table(
            columns: [measure], rows: [[.double(-1e308)], [.double(1e308)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 10)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(data.count == 10)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == 2)
        #expect(data.compactMap(\.lower).allSatisfy { $0.isFinite })
        #expect(data.compactMap(\.upper).allSatisfy { $0.isFinite })
    }

    @Test func typedHourlyDatesRemainDistinctAndSortChronologically() throws {
        let dates = try [
            Date("2026-01-01T03:00:00Z", strategy: .iso8601),
            Date("2026-01-01T01:00:00Z", strategy: .iso8601),
            Date("2026-01-01T02:00:00Z", strategy: .iso8601),
        ]
        let input = table(
            columns: [date, measure],
            rows: zip(dates, [3.0, 1.0, 2.0]).map { [.date($0.0), .double($0.1)] })
        let specification = AutoChartSpecification(
            family: .line,
            encoding: AutoChartEncoding(x: date.id, y: measure.id),
            aggregation: .sum)
        #expect(AutoChartEngine.validate(specification: specification, for: input).isValid)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(data.count == 3)
        #expect(data.compactMap(\.xDate) == dates.sorted())
        #expect(data.compactMap(\.yNumber) == [1, 2, 3])
    }

    @Test func numericOrdinalsKeepCategoricalSourceOrder() {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let input = table(
            columns: [ordinal, measure],
            rows: [
                [.integer(2), .double(20)],
                [.integer(1), .double(10)],
            ])
        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: ordinal.id, y: measure.id),
            sort: .source)
        #expect(AutoChartEngine.validate(specification: specification, for: input).isValid)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        #expect(data.compactMap(\.xLabel) == ["2", "1"])
    }

    @Test func invalidTransformAndFamilyCombinationsAreRejected() {
        let categoryInput = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(10)], [.text("B"), .double(20)]])
        let donutCount = AutoChartSpecification(
            family: .donut,
            encoding: AutoChartEncoding(x: category.id, y: measure.id),
            aggregation: .count)
        let normalizedBar = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: category.id, y: measure.id),
            stacking: .normalized)
        let rangeAggregation = AutoChartSpecification(
            family: .range,
            encoding: AutoChartEncoding(x: category.id, start: date.id, end: date.id),
            aggregation: .sum)
        let bubbleAggregation = AutoChartSpecification(
            family: .bubble,
            encoding: AutoChartEncoding(
                x: measure.id, y: measure.id, size: measure.id),
            aggregation: .sum)
        #expect(
            !AutoChartEngine.validate(
                specification: donutCount, for: categoryInput
            ).isValid)
        #expect(
            !AutoChartEngine.validate(
                specification: normalizedBar, for: categoryInput
            ).isValid)
        #expect(
            !AutoChartEngine.validate(
                specification: rangeAggregation,
                for: table(
                    columns: [category, date],
                    rows: [[.text("A"), .text("2026-01-01")]])
            ).isValid)
        #expect(
            !AutoChartEngine.validate(
                specification: bubbleAggregation,
                for: table(columns: [measure], rows: [[.double(1)]])
            ).isValid)
    }

    @Test func familySafetyRulesApplyToCallerSpecifications() {
        let kpiInput = table(
            columns: [measure], rows: (0..<5).map { [.double(Double($0))] })
        let kpi = AutoChartSpecification(
            family: .kpi, encoding: AutoChartEncoding(y: measure.id))
        #expect(!AutoChartEngine.validate(specification: kpi, for: kpiInput).isValid)

        let negativeAreaInput = table(
            columns: [date, measure],
            rows: [
                [.text("2026-01-01"), .double(-1)],
                [.text("2026-01-02"), .double(2)],
            ])
        let area = AutoChartSpecification(
            family: .area, encoding: AutoChartEncoding(x: date.id, y: measure.id))
        #expect(
            !AutoChartEngine.validate(
                specification: area, for: negativeAreaInput
            ).isValid)
    }

    @Test func ordinaryBarsRejectSeriesEncodings() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(1)],
                [.text("A"), .text("Two"), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id, series: series.id),
            aggregation: .sum)
        #expect(
            AutoChartEngine.validate(
                specification: specification,
                for: input
            ).issues.contains {
                $0.message == "Bar does not support a series encoding."
            })
    }

    @Test func truncatedCategoricalFacetsInheritBarCompleteness() {
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let categoricalInput = table(
            columns: [category, facet, measure],
            rows: [
                [.text("A"), .text("One"), .double(1)],
                [.text("B"), .text("Two"), .double(2)],
            ],
            truncated: true)
        let categorical = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: category.id, y: measure.id, facet: facet.id))
        #expect(
            !AutoChartEngine.validate(specification: categorical, for: categoricalInput).isValid)

        let temporalInput = table(
            columns: [date, facet, measure],
            rows: [
                [.text("2026-01-01"), .text("One"), .double(1)],
                [.text("2026-01-02"), .text("Two"), .double(2)],
            ],
            truncated: true)
        let temporal = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: date.id, y: measure.id, facet: facet.id))
        #expect(AutoChartEngine.validate(specification: temporal, for: temporalInput).isValid)
    }

    @Test func nullGroupsDoNotMergeWithRealLabels() {
        let input = table(
            columns: [category, measure],
            rows: [[.null, .double(1)], [.text("All"), .double(2)]])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: AutoChartEncoding(x: category.id, y: measure.id))
        #expect(!AutoChartEngine.validate(specification: specification, for: input).isValid)
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(Set(data.compactMap(\.xLabel)) == ["Missing value", "All"])
        #expect(data.allSatisfy { $0.sourceRowIDs.count == 1 })

        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let facetedInput = table(
            columns: [category, facet, measure],
            rows: [
                [.text("A"), .null, .double(1)],
                [.text("B"), .text("Other"), .double(2)],
            ])
        let faceted = AutoChartSpecification(
            family: .faceted,
            encoding: AutoChartEncoding(
                x: category.id, y: measure.id, facet: facet.id))
        #expect(
            !AutoChartEngine.validate(
                specification: faceted, for: facetedInput
            ).isValid)
        let facetData = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(facetedInput), specification: faceted)
        #expect(facetData[0].facetIdentity == nil)
        #expect(facetData[1].facetIdentity != nil)
    }

    @Test func facetedDuplicateMarksRequireSeriesOrAggregation() {
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [category, facet, series, measure],
            rows: [
                [.text("A"), .text("One"), .text("First"), .double(1)],
                [.text("A"), .text("One"), .text("Second"), .double(2)],
            ])
        let duplicate = AutoChartSpecification(
            family: .faceted,
            encoding: AutoChartEncoding(
                x: category.id, y: measure.id, facet: facet.id))
        let separated = AutoChartSpecification(
            family: .faceted,
            encoding: AutoChartEncoding(
                x: category.id, y: measure.id, series: series.id, facet: facet.id))
        #expect(!AutoChartEngine.validate(specification: duplicate, for: input).isValid)
        #expect(AutoChartEngine.validate(specification: separated, for: input).isValid)
    }

    @Test func explicitTemporalColumnsRejectUnparseableRows() {
        let temporal = AutoChartColumn(
            id: "temporal", name: "temporal",
            hints: AutoChartColumnHints(semanticType: .temporal))
        let input = table(
            columns: [temporal, measure],
            rows: [
                [.text("2026-01-01"), .double(1)],
                [.text("not-a-date"), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .line,
            encoding: AutoChartEncoding(x: temporal.id, y: measure.id))
        #expect(!AutoChartEngine.validate(specification: specification, for: input).isValid)
    }

    @Test func completeResultFamiliesRejectMissingEncodedValues() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let end = AutoChartColumn(
            id: "end", name: "end",
            hints: AutoChartColumnHints(semanticType: .temporal))

        let compositionInput = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(1)],
                [.text("B"), .null, .double(2)],
                [.text("C"), .text("Two"), .null],
                [.null, .text("Three"), .double(3)],
            ])
        let normalized = AutoChartSpecification(
            family: .normalizedBar,
            encoding: .init(x: category.id, y: measure.id, series: series.id),
            stacking: .normalized)
        let compositionIssues = AutoChartEngine.validate(
            specification: normalized, for: compositionInput
        ).issues.map(\.message)
        #expect(compositionIssues.contains("Series fields must not contain missing values."))
        #expect(
            compositionIssues.contains(
                "Composition categories must not contain missing values."))
        #expect(
            compositionIssues.contains(
                "Composition measures must not contain missing values."))

        let heatmapInput = table(
            columns: [category, series],
            rows: [[.text("A"), .text("One")], [.null, .text("Two")]])
        let heatmap = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: category.id, y: series.id),
            aggregation: .count)
        #expect(
            AutoChartEngine.validate(
                specification: heatmap, for: heatmapInput
            ).issues.contains {
                $0.message == "Heatmap x categories must not contain missing values."
            })

        let rangeInput = table(
            columns: [category, date, end],
            rows: [[.text("A"), .text("2026-01-01"), .null]])
        let range = AutoChartSpecification(
            family: .range,
            encoding: .init(x: category.id, start: date.id, end: end.id))
        #expect(
            AutoChartEngine.validate(
                specification: range, for: rangeInput
            ).issues.contains {
                $0.message == "Range ends must not contain missing values."
            })
    }

    @Test func callerAggregationMustMatchDeclaredSafeOperation() {
        let average = AutoChartColumn(
            id: "average", name: "average",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                aggregation: .mean,
                aggregationSafety: .safe))
        let input = table(
            columns: [category, average],
            rows: [[.text("A"), .double(1)], [.text("A"), .double(3)]])
        let sum = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: average.id),
            aggregation: .sum)
        let mean = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: average.id),
            aggregation: .mean)
        #expect(!AutoChartEngine.validate(specification: sum, for: input).isValid)
        #expect(AutoChartEngine.validate(specification: mean, for: input).isValid)
    }

    @Test func typedHeatmapIdentitiesAndIDsDoNotCollide() {
        let x = AutoChartColumn(
            id: "x", name: "x",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let y = AutoChartColumn(
            id: "y", name: "y",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let specification = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: x.id, y: y.id),
            aggregation: .count)

        let typed = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(
                table(
                    columns: [x, y],
                    rows: [[.integer(1), .text("A")], [.text("1"), .text("A")]])),
            specification: specification)
        #expect(typed.count == 2)
        #expect(Set(typed.compactMap(\.xLabel)) == ["1"])
        #expect(Set(typed.compactMap(\.xIdentity)).count == 2)
        #expect(Set(typed.map(\.id)).count == 2)

        let hyphenated = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(
                table(
                    columns: [x, y],
                    rows: [[.text("a-b"), .text("c")], [.text("a"), .text("b-c")]])),
            specification: specification)
        #expect(hyphenated.count == 2)
        #expect(Set(hyphenated.map(\.id)).count == 2)
    }

    @Test func typedIdentityDisplayLabelsRemainVisuallyDistinct() {
        let labels = disambiguatedCategoryLabels([
            (identity: "integer:1", label: "1"),
            (identity: "text:1:1", label: "1"),
        ])
        let integer = disambiguatedCategoryValue(
            identity: "integer:1", label: "1", labels: labels)
        let text = disambiguatedCategoryValue(
            identity: "text:1:1", label: "1", labels: labels)
        #expect(integer == "1 (Integer)")
        #expect(text == "1 (Text)")
        #expect(integer != text)
    }

    @Test func nearestAxisSelectionIncludesEverySeriesAtTheNearestPosition() throws {
        let selectedDate = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let matches = [
            AutoChartDatum(
                id: "first", sourceRowIDs: ["r0"], xDate: selectedDate,
                yNumber: 10, series: "First"),
            AutoChartDatum(
                id: "second", sourceRowIDs: ["r1"], xDate: selectedDate,
                yNumber: 20, series: "Second"),
            AutoChartDatum(
                id: "later", sourceRowIDs: ["r2"],
                xDate: selectedDate.addingTimeInterval(86_400),
                yNumber: 30, series: "First"),
        ]
        let nearest = AutoChartSelectionPreparation.nearestDateMatches(
            to: selectedDate.addingTimeInterval(60),
            in: matches)
        #expect(Set(nearest.map(\.id)) == ["first", "second"])
        #expect(
            AutoChartSelectionPreparation.valueDescription(
                for: nearest,
                aggregation: .none) == "2 marks · 2 source rows")
    }

    @Test func selectionSummariesRespectNonadditiveAggregations() {
        let matches = [
            AutoChartDatum(id: "first", sourceRowIDs: ["r0"], yNumber: 10),
            AutoChartDatum(id: "second", sourceRowIDs: ["r1", "r2"], yNumber: 20),
        ]
        #expect(
            AutoChartSelectionPreparation.valueDescription(
                for: matches,
                aggregation: .mean) == "16.667 · 3 source rows")
        #expect(
            AutoChartSelectionPreparation.valueDescription(
                for: matches,
                aggregation: .countDistinct) == "2 marks · 3 source rows")
    }

    @Test func boxPlotLabelTiesUseIdentityAsDeterministicTieBreaker() {
        let mixed = AutoChartColumn(
            id: "mixed", name: "mixed",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [mixed, measure],
            rows: [[.text("1"), .double(2)], [.integer(1), .double(1)]])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: mixed.id, y: measure.id))
        let data = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        #expect(data.compactMap(\.xLabel) == ["1", "1"])
        #expect(data.compactMap(\.xIdentity) == ["integer:1", "text:1:1"])
    }

}
