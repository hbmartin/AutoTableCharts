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
    TestTable(
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

@Suite struct ProfilingTests {
    @Test func explicitHintsOverrideValueInference() {
        let ordinal = AutoChartColumn(
            id: "year", name: "year",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let snapshot = AutoChartSnapshot(table(
            columns: [ordinal], rows: [[.integer(2024)], [.integer(2025)]]))
        #expect(AutoChartProfiler.profiles(snapshot)[0].semanticType == .ordinal)
    }

    @Test func isoDateTextIsTemporal() {
        let inferred = AutoChartColumn(id: "observed", name: "observed")
        let snapshot = AutoChartSnapshot(table(
            columns: [inferred],
            rows: [[.text("2026-01-01")], [.text("2026-02-01")]]))
        #expect(AutoChartProfiler.profiles(snapshot)[0].semanticType == .temporal)
    }

    @Test func identifiersAndBinaryAreNotMeasures() {
        let identifier = AutoChartColumn(id: "property_id", name: "property_id")
        let blob = AutoChartColumn(id: "payload", name: "payload")
        let snapshot = AutoChartSnapshot(table(
            columns: [identifier, blob],
            rows: [[.integer(1), .binary(Data([1]))]]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        #expect(profiles[0].semanticType == .identifier)
        #expect(profiles[1].semanticType == .unsupported)
    }

    @Test func nullsRemainVisibleInProfile() {
        let column = AutoChartColumn(id: "amount", name: "amount")
        let snapshot = AutoChartSnapshot(table(
            columns: [column], rows: [[.double(1)], [.null]]))
        let profile = AutoChartProfiler.profiles(snapshot)[0]
        #expect(profile.nonNullCount == 1)
        #expect(profile.nullFraction == 0.5)
    }
}

@Suite struct RecommendationTests {
    @Test func scalarUsesKPI() {
        let result = AutoChartEngine.recommendations(for: table(
            columns: [measure], rows: [[.double(42)]]))
        #expect(result.chartRecommendations.first?.specification.family == .kpi)
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
        let first = AutoChartEngine.recommendations(for: input)
        let second = AutoChartEngine.recommendations(for: input)
        #expect(first == second)
    }

    @Test func unknownAggregationBlocksDuplicateCategoryBars() {
        let unsafeMeasure = AutoChartColumn(
            id: "raw", name: "raw_value",
            hints: AutoChartColumnHints(semanticType: .quantitative, role: .measure))
        let result = AutoChartEngine.recommendations(for: table(
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
        let result = AutoChartEngine.recommendations(for: table(
            columns: [category, mean],
            rows: [
                [.text("A"), .double(1)],
                [.text("A"), .double(2)],
            ]))
        #expect(!result.chartRecommendations.contains { $0.specification.family == .bar })
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
                [.text("Office"), .text("Boston"), .text("Core"),
                 .text("2026-01-01"), .text("2026-07-01"),
                 .double(20), .double(12), .double(100)],
                [.text("Retail"), .text("Denver"), .text("Value-Add"),
                 .text("2026-02-01"), .text("2026-10-01"),
                 .double(10), .double(7), .double(60)],
                [.text("Industrial"), .text("Boston"), .text("Core"),
                 .text("2026-03-01"), .text("2027-01-01"),
                 .double(15), .double(9), .double(80)],
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
            .init(family: .donut, encoding: xy),
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
            #expect(
                AutoChartEngine.validate(
                    specification: specification, for: input
                ).isValid,
                "\(specification.family) should validate")
            #expect(
                !AutoChartDataPreparation.data(
                    snapshot: AutoChartSnapshot(input),
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
        #expect(data[0].sourceRowIDs == ["r0", "r1"])
    }
}
