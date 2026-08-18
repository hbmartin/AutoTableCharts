import Foundation
import Testing

@testable import AutoTableCharts

#if canImport(Charts) && canImport(SwiftUI)
import Charts
import SwiftUI

@MainActor
// Reads the private stored `data` property of `AutoChartView` by reflection.
// Update this helper if that storage changes. A nil result means reflection failed,
// while an empty array means the view successfully prepared no marks.
private func preparedData(in view: AutoChartView) -> [AutoChartDatum]? {
    Mirror(reflecting: view).children.first { $0.label == "data" }?.value
        as? [AutoChartDatum]
}

@MainActor
private func reflectedStoredValue<Value>(
    named name: String,
    in view: AutoChartView
) -> Value? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? Value
}

@MainActor
private func reflectedOptionalStoredValue<Value>(
    named name: String,
    in view: AutoChartView
) -> Value? {
    guard
        let stored = Mirror(reflecting: view).children.first(where: { $0.label == name })?.value
    else { return nil }
    return Mirror(reflecting: stored).children.first?.value as? Value
}
#endif

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

private final class ChartValueReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct CountingRow: AutoChartRow {
    var chartRowID: AutoChartRowID
    var values: [AutoChartColumnID: AutoChartValue]
    var counter: ChartValueReadCounter

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        counter.increment()
        return values[columnID] ?? .null
    }
}

private struct VersionedCountingTable: AutoChartTable {
    var chartColumns: [AutoChartColumn]
    var chartRows: [CountingRow]
    var chartMetadata = AutoChartTableMetadata()
    var chartDataIdentity: String?
    var chartDataVersion: String?
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
            maximumFacets: 0,
            maximumCandidateColumns: 0)
        options.maximumRecommendations = 0
        options.maximumCategories = 0
        options.maximumDonutSectors = 0
        options.maximumSeries = 0
        options.maximumFacets = 0
        options.maximumCandidateColumns = 0
        let mutatedLimits: [Int] = [
            options.maximumRecommendations,
            options.maximumCategories,
            options.maximumDonutSectors,
            options.maximumSeries,
            options.maximumFacets,
            options.maximumCandidateColumns,
        ]
        #expect(mutatedLimits == [1, 2, 2, 2, 2, 2])

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
            decoded.maximumCandidateColumns,
        ]
        #expect(decodedLimits == [1, 2, 2, 2, 2, 24])
    }

    @Test func specificationIDsEncodeSeparatorsOptionalBinsAndFacetBases() throws {
        let first = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "a|b", y: "c"))
        let second = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "a", y: "b|c"))
        let noBins = AutoChartSpecification(family: .histogram, binCount: nil)
        let zeroBins = AutoChartSpecification(family: .histogram, binCount: 0)
        let facetedLine = AutoChartSpecification(
            family: .faceted,
            facetBaseFamily: .line)
        let facetedBar = AutoChartSpecification(
            family: .faceted,
            facetBaseFamily: .bar)
        #expect(first.id != second.id)
        #expect(noBins.id != zeroBins.id)
        #expect(facetedLine.id != facetedBar.id)

        let encoded = try JSONEncoder().encode(facetedLine)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "facetBaseFamily")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(AutoChartSpecification.self, from: legacyData)
        #expect(legacy.facetBaseFamily == nil)
    }

    @Test func encodingColumnIDsPreserveChannelOrderAndDuplicates() {
        let encoding = AutoChartEncoding(
            x: "x", y: "y", series: "series", size: "size",
            facet: "facet", start: "start", end: "y")

        #expect(
            encoding.columnIDs
                == ["x", "y", "series", "size", "facet", "start", "y"])
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

    @Test func snapshotFingerprintDistinguishesSignedZero() {
        let positiveZero = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(0.0)]]))
        let negativeZero = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(-0.0)]]))

        #expect(!positiveZero.hasSameContent(as: negativeZero))
        #expect(positiveZero.contentFingerprint != negativeZero.contentFingerprint)
    }

    @Test func snapshotContentComparisonHandlesNonFiniteValues() {
        let first = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(.nan)], [.double(.infinity)]]))
        let identical = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(.nan)], [.double(.infinity)]]))
        let changed = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(.nan)], [.double(-.infinity)]]))

        #expect(first.hasSameContent(as: identical))
        #expect(!first.hasSameContent(as: changed))
    }

    @Test func snapshotContentComparisonHandlesNonFiniteDates() {
        func snapshot(_ interval: TimeInterval) -> AutoChartSnapshot {
            AutoChartSnapshot(
                table(
                    columns: [date],
                    rows: [[.date(Date(timeIntervalSinceReferenceDate: interval))]]))
        }
        let nonFinite = snapshot(.nan)
        let finite = snapshot(0)

        // A snapshot that can't match itself would evict and re-prepare its
        // cached table on every render, because the fingerprint still matches.
        #expect(nonFinite.hasSameContent(as: nonFinite))
        #expect(nonFinite.hasSameContent(as: snapshot(.nan)))
        #expect(!nonFinite.hasSameContent(as: finite))
        #expect(nonFinite.contentFingerprint == snapshot(.nan).contentFingerprint)
        #expect(finite.hasSameContent(as: snapshot(-0.0)))
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
        let label = AutoChartAccessibility.markLabel(
            for: datum,
            family: .line,
            xSemanticType: .temporal,
            xCategoryName: "Unused")
        #expect(label == "\(expectedAccessibleDate), 2")
        #expect(!label.contains("T00:00:00Z"))
    }

    @Test func accessibilityLabelsIncludeSeriesContext() {
        let datum = AutoChartDatum(
            id: "series",
            sourceRowIDs: ["r0"],
            xLabel: "Office",
            yNumber: 2,
            series: "North")
        #expect(
            AutoChartAccessibility.markLabel(
                for: datum,
                family: .bar,
                xSemanticType: .nominal,
                xCategoryName: "Office",
                seriesName: "North",
                facetDescription: "Region: West") == "Office, North, Region: West, 2")
    }

    @Test func quantitativeAccessibilityDoesNotResolveAnUnusedCategoryLabel() {
        var categoryLookupCount = 0
        func categoryName() -> String {
            categoryLookupCount += 1
            return "Unused"
        }
        let datum = AutoChartDatum(
            id: "number",
            sourceRowIDs: ["r0"],
            xNumber: 10,
            yNumber: 2)

        let label = AutoChartAccessibility.markLabel(
            for: datum,
            family: .scatter,
            xSemanticType: .quantitative,
            xCategoryName: categoryName())

        #expect(label == "10, 2")
        #expect(categoryLookupCount == 0)
    }

    @Test func heatmapAccessibilityIncludesBothCategoriesAndCount() {
        let datum = AutoChartDatum(
            id: "heatmap",
            sourceRowIDs: ["r0", "r1", "r2"],
            yNumber: 3)

        #expect(
            AutoChartAccessibility.heatmapLabel(
                for: datum,
                xCategoryName: "Office",
                yCategoryName: "Boston") == "Office, Boston, 3")
    }

    @Test func rangeAccessibilityDescribesDates() throws {
        let start = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let end = try Date("2026-02-01T00:00:00Z", strategy: .iso8601)
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            timeZone: TimeZone.gmt)
        let datum = AutoChartDatum(
            id: "range",
            sourceRowIDs: ["r0"],
            xLabel: "Lease",
            startDate: start,
            endDate: end)
        let interval = "From \(start.formatted(style)) to \(end.formatted(style))"
        #expect(datum.intervalAccessibilityDescription == interval)
        #expect(
            datum.accessibilityLabel(
                name: "Lease",
                series: nil,
                valueDescription: datum.intervalAccessibilityDescription)
                == "Lease, \(interval)")
    }
}

@Suite(.serialized) struct RenderCacheTests {
    @Test func configurationClampsNegativeLimits() {
        let configuration = AutoChartRenderCacheConfiguration(
            maximumTableEntries: -1,
            maximumTableCost: -1,
            maximumRenderEntries: -1,
            maximumRenderCost: -1)

        #expect(configuration.maximumTableEntries == 0)
        #expect(configuration.maximumTableCost == 0)
        #expect(configuration.maximumRenderEntries == 0)
        #expect(configuration.maximumRenderCost == 0)
    }

    #if canImport(Charts) && canImport(SwiftUI)
    @Test @MainActor func oversizedTableCacheKeysCountAgainstTheByteBudget() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 8,
                maximumTableCost: 4_096,
                maximumRenderEntries: 0,
                maximumRenderCost: 0))
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        let oversizedKey = String(repeating: "identity", count: 1_024)
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [category.id: .text("A"), measure.id: .double(1)],
                    counter: counter)
            ],
            chartDataIdentity: oversizedKey,
            chartDataVersion: oversizedKey)
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Oversized table-key test"])

        _ = AutoChartView(table: input, recommendation: recommendation)

        #expect(AutoChartRenderCache.retainedTableCount == 0)
        #expect(AutoChartRenderCache.retainedRenderCount == 0)
    }

    @Test @MainActor func specificationEncodingIDsCountAgainstTheRenderBudget() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 8,
                maximumTableCost: 1_024 * 1_024,
                maximumRenderEntries: 8,
                maximumRenderCost: 4_096))
        AutoChartRenderCache.removeAll()

        let oversizedID = AutoChartColumnID(
            rawValue: String(repeating: "encoding", count: 1_024))
        let oversizedCategory = AutoChartColumn(
            id: oversizedID,
            name: "oversized_category",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let input = table(
            columns: [oversizedCategory, measure],
            rows: [[.text("A"), .double(1)]])
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: oversizedID, y: measure.id)),
            score: 0,
            rationale: ["Oversized render-key test"])

        _ = AutoChartView(table: input, recommendation: recommendation)

        #expect(AutoChartRenderCache.retainedTableCount == 1)
        #expect(AutoChartRenderCache.retainedRenderCount == 0)
    }

    @Test @MainActor func presentationTitlesCountAgainstTheRenderBudget() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 8,
                maximumTableCost: 1_024 * 1_024,
                maximumRenderEntries: 8,
                maximumRenderCost: 4_096))
        AutoChartRenderCache.removeAll()

        let oversizedDisplayName = String(repeating: "Presentation title", count: 512)
        let titledCategory = AutoChartColumn(
            id: "category", name: "category", displayName: oversizedDisplayName,
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let input = table(
            columns: [titledCategory, measure],
            rows: [[.text("A"), .double(1)]])
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: titledCategory.id, y: measure.id)),
            score: 0,
            rationale: ["Oversized presentation-title test"])

        _ = AutoChartView(table: input, recommendation: recommendation)

        #expect(AutoChartRenderCache.retainedTableCount == 1)
        #expect(AutoChartRenderCache.retainedRenderCount == 0)
    }

    @Test @MainActor func versionedTablesReusePreparedRenderingData() throws {
        let counter = ChartValueReadCounter()
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [category.id: .text("A"), measure.id: .double(1)],
                    counter: counter)
            ],
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let recommendation = try #require(
            AutoChartEngine.recommendations(for: input).chartRecommendations.first)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count > 0)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count == 0)
    }

    @Test @MainActor func renderCachingWorksWhenTableCachingIsDisabled() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 0,
                maximumTableCost: 0,
                maximumRenderEntries: 8,
                maximumRenderCost: 1_024 * 1_024))
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [category.id: .text("A"), measure.id: .double(1)],
                    counter: counter)
            ],
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Independent render-cache test"])

        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(AutoChartRenderCache.retainedTableCount == 0)
        #expect(AutoChartRenderCache.retainedRenderCount == 1)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count == 0)
        #expect(AutoChartRenderCache.retainedTableCount == 0)
        #expect(AutoChartRenderCache.retainedRenderCount == 1)
    }

    @Test @MainActor func distinctSpecificationsReuseARenderOwnedVersionedSnapshot() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 0,
                maximumTableCost: 0,
                maximumRenderEntries: 8,
                maximumRenderCost: 1_024 * 1_024))
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: (0..<100).map { index in
                CountingRow(
                    chartRowID: AutoChartRowID(rawValue: "r\(index)"),
                    values: [
                        category.id: .text("Category \(index)"),
                        measure.id: .double(Double(index)),
                    ],
                    counter: counter)
            },
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let bar = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Render-owned sharing test"])
        let dots = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .rankedDot,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Render-owned sharing test"])

        _ = AutoChartView(table: input, recommendation: bar)
        #expect(counter.count > 0)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: dots)
        #expect(counter.count == 0)
        #expect(AutoChartRenderCache.retainedTableCount == 0)
        #expect(AutoChartRenderCache.retainedRenderCount == 2)
    }

    @Test @MainActor func disablingTableCachingPreservesIndependentlyOwnedRenders() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        let renderOnly = AutoChartRenderCacheConfiguration(
            maximumTableEntries: 0,
            maximumTableCost: 0,
            maximumRenderEntries: 8,
            maximumRenderCost: 1_024 * 1_024)
        AutoChartRenderCache.configure(renderOnly)
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        let identity = UUID().uuidString
        let version = UUID().uuidString
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [category.id: .text("A"), measure.id: .double(1)],
                    counter: counter)
            ],
            chartDataIdentity: identity,
            chartDataVersion: version)
        let bar = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Independent render preservation test"])
        let dots = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .rankedDot,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Independent render preservation test"])

        _ = AutoChartView(table: input, recommendation: bar)
        AutoChartRenderCache.configure(
            AutoChartRenderCacheConfiguration(
                maximumTableEntries: 8,
                maximumTableCost: 1_024 * 1_024,
                maximumRenderEntries: 8,
                maximumRenderCost: 1_024 * 1_024))
        _ = AutoChartView(table: input, recommendation: dots)
        #expect(AutoChartRenderCache.retainedTableCount == 1)
        #expect(AutoChartRenderCache.retainedRenderCount == 2)

        AutoChartRenderCache.configure(renderOnly)
        #expect(AutoChartRenderCache.retainedTableCount == 0)
        #expect(AutoChartRenderCache.retainedRenderCount == 1)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: bar)
        #expect(counter.count == 0)
    }

    @Test @MainActor func aVersionWithoutATableIdentityCannotCrossContaminateTables() throws {
        let counter = ChartValueReadCounter()
        func input(value: Double) -> VersionedCountingTable {
            VersionedCountingTable(
                chartColumns: [category, measure],
                chartRows: [
                    CountingRow(
                        chartRowID: "r0",
                        values: [category.id: .text("A"), measure.id: .double(value)],
                        counter: counter)
                ],
                chartDataIdentity: nil,
                chartDataVersion: "shared-version")
        }
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Test"])

        let first = AutoChartView(
            table: input(value: 1), recommendation: recommendation)
        let second = AutoChartView(
            table: input(value: 2), recommendation: recommendation)
        let firstValue = try #require(preparedData(in: first)?.first?.yNumber)
        let secondValue = try #require(preparedData(in: second)?.first?.yNumber)

        #expect(firstValue == 1)
        #expect(secondValue == 2)
        #expect(firstValue != secondValue)
    }

    @Test @MainActor func signedZeroContentCanReplaceAndReuseCachedRenderingData() throws {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }
        AutoChartRenderCache.configure(.standard)
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        func input(value: Double) -> VersionedCountingTable {
            VersionedCountingTable(
                chartColumns: [category, measure],
                chartRows: [
                    CountingRow(
                        chartRowID: "r0",
                        values: [category.id: .text("A"), measure.id: .double(value)],
                        counter: counter)
                ],
                chartDataIdentity: nil,
                chartDataVersion: nil)
        }
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Signed-zero cache test"])

        // The cache is process-wide and other suites render into it, so measure
        // growth from this test's own insertions rather than its absolute size.
        let baseline = AutoChartRenderCache.retainedTableCount
        _ = AutoChartView(table: input(value: 0.0), recommendation: recommendation)
        let afterPositiveZero = AutoChartRenderCache.retainedTableCount
        #expect(afterPositiveZero >= baseline + 1)
        let negative = AutoChartView(
            table: input(value: -0.0), recommendation: recommendation)
        let negativeValue = try #require(preparedData(in: negative)?.first?.yNumber)
        #expect(negativeValue.bitPattern == (-0.0).bitPattern)
        let afterNegativeZero = AutoChartRenderCache.retainedTableCount
        // Signed-zero content is distinct, so it takes an entry of its own.
        #expect(afterNegativeZero >= afterPositiveZero + 1)

        counter.reset()
        _ = AutoChartView(table: input(value: -0.0), recommendation: recommendation)
        #expect(counter.count == 2)
        // Repeating identical content reuses the entry instead of adding one.
        #expect(AutoChartRenderCache.retainedTableCount == afterNegativeZero)
    }

    @Test @MainActor func recommendationsShareOneVersionedTableSnapshot() {
        let counter = ChartValueReadCounter()
        let measures = (0..<9).map { index in
            AutoChartColumn(
                id: AutoChartColumnID(rawValue: "measure-\(index)"),
                name: "measure_\(index)",
                hints: AutoChartColumnHints(semanticType: .quantitative))
        }
        let columns = [category] + measures
        let rows = (0..<5_000).map { rowIndex in
            var values: [AutoChartColumnID: AutoChartValue] = [
                category.id: .text("Category \(rowIndex)")
            ]
            for (measureIndex, measure) in measures.enumerated() {
                values[measure.id] = .double(Double(rowIndex + measureIndex))
            }
            return CountingRow(
                chartRowID: AutoChartRowID(rawValue: "r\(rowIndex)"),
                values: values,
                counter: counter)
        }
        let input = VersionedCountingTable(
            chartColumns: columns,
            chartRows: rows,
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let recommendations = measures.prefix(6).map { measure in
            AutoChartRecommendation(
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: category.id, y: measure.id)),
                score: 0,
                rationale: ["Cache sharing test"])
        }

        counter.reset()
        for recommendation in recommendations {
            _ = AutoChartView(table: input, recommendation: recommendation)
        }
        #expect(counter.count == rows.count * columns.count)

        counter.reset()
        for recommendation in recommendations {
            _ = AutoChartView(table: input, recommendation: recommendation)
        }
        #expect(counter.count == 0)
    }

    @Test @MainActor func oversizedBinaryPayloadsAreNotRetainedByTheRenderCache() {
        let counter = ChartValueReadCounter()
        // The payload must exceed whatever table-cache budget is active so the
        // prepared table is rejected from the process-wide cache.
        let oversizedPayloadSize =
            AutoChartRenderCache.configuration.maximumTableCost + 1_024 * 1_024
        let blob = AutoChartColumn(id: "blob", name: "blob")
        let input = VersionedCountingTable(
            chartColumns: [category, measure, blob],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [
                        category.id: .text("A"),
                        measure.id: .double(1),
                        blob.id: .binary(Data(count: oversizedPayloadSize)),
                    ],
                    counter: counter)
            ],
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Large payload test"])

        _ = AutoChartView(table: input, recommendation: recommendation)
        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)

        #expect(counter.count > 0)
    }

    @Test @MainActor func cacheCanBeConfiguredAndMemoryPressurePurgesIt() {
        let originalConfiguration = AutoChartRenderCache.configuration
        defer {
            AutoChartRenderCache.configure(originalConfiguration)
            AutoChartRenderCache.removeAll()
        }

        AutoChartRenderCache.configure(.standard)
        AutoChartRenderCache.removeAll()

        let counter = ChartValueReadCounter()
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: [
                CountingRow(
                    chartRowID: "r0",
                    values: [category.id: .text("A"), measure.id: .double(1)],
                    counter: counter)
            ],
            chartDataIdentity: UUID().uuidString,
            chartDataVersion: UUID().uuidString)
        let recommendation = AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: .bar,
                encoding: .init(x: category.id, y: measure.id)),
            score: 0,
            rationale: ["Cache configuration test"])

        _ = AutoChartView(table: input, recommendation: recommendation)
        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count == 0)

        AutoChartRenderCache.handleMemoryPressure()
        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count > 0)

        let disabledConfiguration = AutoChartRenderCacheConfiguration(
            maximumTableEntries: 0,
            maximumTableCost: 0,
            maximumRenderEntries: 0,
            maximumRenderCost: 0)
        AutoChartRenderCache.configure(disabledConfiguration)
        #expect(AutoChartRenderCache.configuration == disabledConfiguration)

        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        counter.reset()
        _ = AutoChartView(table: input, recommendation: recommendation)
        #expect(counter.count > 0)
    }
    #endif
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

    @Test func typedDateColumnsRemainTemporalWithANonFiniteValue() {
        let inferred = AutoChartColumn(id: "observed", name: "observed")
        let snapshot = AutoChartSnapshot(
            table(
                columns: [inferred],
                rows: [
                    [.date(Date(timeIntervalSinceReferenceDate: 0))],
                    [.date(Date(timeIntervalSinceReferenceDate: .nan))],
                ]))
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(profile.semanticType == .temporal)
        #expect(profile.temporalValues.count == 1)
        #expect(profile.nonFiniteDateCount == 1)
    }

    @Test func temporalProfilesStoreFiniteBounds() throws {
        let inferred = AutoChartColumn(id: "observed", name: "observed")
        let first = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let last = try Date("2026-03-01T00:00:00Z", strategy: .iso8601)
        let middle = try Date("2026-02-01T00:00:00Z", strategy: .iso8601)
        let profile = AutoChartProfiler.profiles(
            AutoChartSnapshot(
                table(
                    columns: [inferred],
                    rows: [[.date(middle)], [.date(last)], [.date(first)]]))
        )[0]

        #expect(profile.temporalMinimum == first)
        #expect(profile.temporalMaximum == last)
        #expect(profile.hasFiniteTemporalSpan)
    }

    @Test func invalidCalendarDatesAreRejected() {
        #expect(AutoChartProfiler.parseISODate("2026-02-29") == nil)
        #expect(AutoChartProfiler.parseISODate("2024-02-29") != nil)
    }

    @Test func abbreviatedAndCodeLikeDatesAreRejected() {
        #expect(AutoChartProfiler.parseISODate("1-2-3") == nil)
        #expect(AutoChartProfiler.parseISODate("10-11-12") == nil)
        #expect(AutoChartProfiler.parseISODate("2026-1-05") == nil)
        #expect(AutoChartProfiler.parseISODate("2026-05-1") == nil)
        #expect(AutoChartProfiler.parseISODate("2026-+1-05") == nil)
        #expect(AutoChartProfiler.parseISODate("2026-05-+1") == nil)
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
        #expect(profile.renderableValueCount == 1)
    }

    @Test func nonFiniteValuesDoNotInflateChartableDistinctCounts() {
        let nominalNumber = AutoChartColumn(
            id: "nominal-number", name: "nominal_number",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [nominalNumber],
                rows: [
                    [.double(.nan)], [.double(.nan)], [.double(.infinity)],
                    [.decimal(.nan)], [.integer(1)],
                ]))
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(profile.distinctCount == 1)
        #expect(profile.renderableValueCount == 1)
    }

    @Test func humanizedNamesReuseCamelCaseTokens() {
        #expect(AutoChartProfiler.humanized("propertyType") == "Property Type")
        #expect(AutoChartProfiler.humanized("current_market_value") == "Current Market Value")
        #expect(AutoChartProfiler.humanized("propertyId") == "Property ID")
        #expect(AutoChartProfiler.humanized("noi") == "Noi")
        #expect(
            AutoChartProfiler.displayName(
                AutoChartColumn(id: "noi", name: "noi", displayName: "NOI")) == "NOI")
    }
}

@Suite struct RecommendationTests {
    @Test func candidateDeduplicationUsesStableSpecificationIDs() throws {
        let first = AutoChartRecommendation(
            specification: AutoChartSpecification(family: .bar, title: "First title"),
            score: 10,
            rationale: ["First"])
        let higher = AutoChartRecommendation(
            specification: AutoChartSpecification(family: .bar, title: "Higher title"),
            score: 20,
            rationale: ["Higher"])
        let equal = AutoChartRecommendation(
            specification: AutoChartSpecification(family: .bar, title: "Equal title"),
            score: 10,
            rationale: ["Equal"])

        #expect(first.id == higher.id)
        let highest = try #require(AutoChartEngine.bestCandidatesByID([first, higher]).first)
        #expect(AutoChartEngine.bestCandidatesByID([first, higher]).count == 1)
        #expect(highest.specification.title == "Higher title")

        let stableTie = try #require(AutoChartEngine.bestCandidatesByID([first, equal]).first)
        #expect(stableTie.specification.title == "First title")
    }

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

    @Test func displayNamesOverrideGeneratedChartLabels() throws {
        let segment = AutoChartColumn(
            id: "segment", name: "segment_code", displayName: "Segment")
        let income = AutoChartColumn(
            id: "income", name: "noi", displayName: "NOI",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                aggregation: .sum,
                aggregationSafety: .alreadyAggregated))
        let input = table(
            columns: [segment, income],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let bar = try #require(
            AutoChartEngine.recommendations(for: input).chartRecommendations.first {
                $0.specification.family == .bar
            })
        #expect(bar.specification.title == "NOI by Segment")
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

    @Test func nonFiniteTypedDatesDoNotSuppressTemporalRecommendations() {
        let inferredDate = AutoChartColumn(id: "observed", name: "observed")
        let input = table(
            columns: [inferredDate, measure],
            rows: [
                [.date(Date(timeIntervalSinceReferenceDate: 0)), .double(1)],
                [.date(Date(timeIntervalSinceReferenceDate: .nan)), .double(2)],
            ])

        let result = AutoChartEngine.recommendations(for: input)

        #expect(
            result.chartRecommendations.contains {
                $0.specification.family == .line
                    && $0.specification.encoding.x == inferredDate.id
            })
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
                [.text("A"), .double(-10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let donut = AutoChartEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition)
        ).chartRecommendations.first { $0.specification.family == .donut }
        #expect(donut?.specification.aggregation == .count)
        #expect(donut?.specification.title == "Count of Count by Property Type")
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
            context: AutoChartContext(goal: .relationship),
            options: AutoChartOptions(
                maximumRecommendations: 12,
                maximumSeries: 2))
        let scatter = result.chartRecommendations.first {
            $0.specification.family == .scatter
        }
        #expect(scatter != nil)
        #expect(scatter?.specification.encoding.series == nil)
        #expect(
            !result.chartRecommendations.contains {
                $0.specification.family == .scatter
                    && $0.specification.encoding.series == highCardinality.id
            })
    }

    @Test func datedMeasuresWithoutCategoriesStillOfferScatter() {
        let input = table(
            columns: [date, measure],
            rows: [
                [.text("2026-01-01"), .double(1)],
                [.text("2026-01-02"), .double(2)],
                [.text("2026-01-03"), .double(3)],
            ])
        let scatter = AutoChartEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .relationship),
            options: AutoChartOptions(maximumRecommendations: 12)
        ).chartRecommendations.first { $0.specification.family == .scatter }
        #expect(scatter != nil)
        #expect(scatter?.specification.encoding.x == date.id)
        #expect(scatter?.specification.encoding.y == measure.id)
        #expect(scatter?.specification.encoding.series == nil)
    }

    @Test func candidateColumnsAreBoundedPerSemanticType() {
        let measures = (0..<3).map { index in
            AutoChartColumn(
                id: AutoChartColumnID(rawValue: "measure-\(index)"),
                name: "measure_\(index)",
                hints: AutoChartColumnHints(semanticType: .quantitative))
        }
        let input = table(
            columns: measures,
            rows: [
                [.double(1), .double(2), .double(3)],
                [.double(4), .double(5), .double(6)],
            ])
        let result = AutoChartEngine.recommendations(
            for: input,
            options: AutoChartOptions(
                maximumRecommendations: 12,
                maximumCandidateColumns: 2))
        let referenced = result.chartRecommendations.flatMap { recommendation in
            [recommendation.specification.encoding.x, recommendation.specification.encoding.y]
                .compactMap { $0 }
        }
        #expect(!referenced.contains(measures[2].id))
    }

    @Test func facetingSkipsAColumnAlreadyUsedAsSeriesAndPreservesTheBaseFamily() throws {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [date, series, facet, measure],
            rows: [
                [.text("2026-01-01"), .text("A"), .text("East"), .double(1)],
                [.text("2026-01-01"), .text("B"), .text("East"), .double(2)],
                [.text("2026-01-02"), .text("A"), .text("West"), .double(3)],
                [.text("2026-01-02"), .text("B"), .text("West"), .double(4)],
            ],
            truncated: true)
        let recommendation = try #require(
            AutoChartEngine.recommendations(
                for: input,
                options: AutoChartOptions(maximumRecommendations: 12)
            ).chartRecommendations.first { $0.specification.family == .faceted })
        #expect(recommendation.specification.encoding.series == series.id)
        #expect(recommendation.specification.encoding.facet == facet.id)
        #expect(recommendation.specification.facetBaseFamily == .line)
    }

    @Test func facetedBarsPreserveHorizontalBaseOrientation() throws {
        let longCategory = AutoChartColumn(
            id: "long-category", name: "long_category",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [longCategory, facet, measure],
            rows: [
                [.text("A very long category"), .text("East"), .double(1)],
                [.text("A very long category"), .text("West"), .double(2)],
            ])
        let recommendation = try #require(
            AutoChartEngine.recommendations(
                for: input,
                options: AutoChartOptions(maximumRecommendations: 12)
            ).chartRecommendations.first {
                $0.specification.family == .faceted
                    && $0.specification.facetBaseFamily == .bar
            })

        #expect(recommendation.specification.orientation == .horizontal)
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
        let barWithFacet = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: category.id, y: measure.id, facet: facet.id))
        #expect(!AutoChartEngine.validate(specification: bubble, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: range, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: faceted, for: input).isValid)
        #expect(
            AutoChartEngine.validate(
                specification: barWithFacet, for: input
            ).issues.contains {
                $0.message == "Bar does not support a facet encoding."
            })
        #expect(
            AutoChartEngine.validate(
                specification: line, for: input
            ).issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func equivalentTemporalValuesRequireExplicitAggregation() {
        let input = table(
            columns: [date, measure],
            rows: [
                [.text("2026-01-01"), .double(1)],
                [.text("2026-01-01T00:00:00Z"), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id))
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        let validation = AutoChartEngine.validate(specification: specification, for: input)

        #expect(prepared.count == 2)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 1)
        #expect(
            validation.issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func equivalentQuantitativeValuesRequireExplicitAggregation() {
        let quantitativeDimension = AutoChartColumn(
            id: "quantitative-dimension", name: "quantitative_dimension",
            hints: AutoChartColumnHints(
                semanticType: .quantitative, role: .dimension))
        let input = table(
            columns: [quantitativeDimension, measure],
            rows: [
                [.integer(1), .double(1)],
                [.double(1), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: quantitativeDimension.id, y: measure.id))
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        let validation = AutoChartEngine.validate(specification: specification, for: input)

        #expect(prepared.count == 2)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 1)
        #expect(
            validation.issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func equivalentOrdinalValuesRequireExplicitAggregation() {
        let year = AutoChartColumn(
            id: "year", name: "year",
            hints: AutoChartColumnHints(semanticType: .ordinal, role: .dimension))
        let input = table(
            columns: [year, measure],
            rows: [
                [.integer(2_020), .double(1)],
                [.double(2_020), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: year.id, y: measure.id))
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification)
        let validation = AutoChartEngine.validate(specification: specification, for: input)
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        // Ordinal years accept mixed integer and floating-point storage, so two
        // spellings of the same year must collapse into one category rather than
        // render as two bars labeled "2,020 (Integer)" and "2,020 (Number)".
        #expect(prepared.count == 2)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 1)
        #expect(!profile.isUniqueAtRowGrain)
        #expect(
            validation.issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func largeOrdinalIntegersRemainDistinct() {
        let ordinal = AutoChartColumn(
            id: "large-ordinal", name: "large_ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal, role: .dimension))
        let first = Int64(9_007_199_254_740_992)
        let second = first + 1
        let input = table(
            columns: [ordinal, measure],
            rows: [
                [.integer(first), .double(1)],
                [.integer(second), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: ordinal.id, y: measure.id))
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification)
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(prepared.count == 2)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 2)
        #expect(profile.renderableDistinctCount == 2)
        #expect(profile.isUniqueAtRowGrain)
        #expect(AutoChartEngine.validate(specification: specification, for: input).isValid)
    }

    @Test func equivalentLargeOrdinalStorageValuesShareAnExactIdentity() throws {
        let ordinal = AutoChartColumn(
            id: "large-ordinal", name: "large_ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal, role: .dimension))
        let exactInteger = Int64(36_028_797_018_963_968)
        let exactDecimal = try #require(Decimal(string: "36028797018963968"))
        let nearbyDecimal = try #require(Decimal(string: "36028797018963970"))
        let input = table(
            columns: [ordinal, measure],
            rows: [
                [.integer(exactInteger), .double(1)],
                [.double(Double(exactInteger)), .double(2)],
                [.decimal(exactDecimal), .double(3)],
                [.decimal(nearbyDecimal), .double(4)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: ordinal.id, y: measure.id))
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification)
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(prepared.count == 4)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 2)
        #expect(profile.renderableDistinctCount == 2)
        #expect(!profile.isUniqueAtRowGrain)
        #expect(
            AutoChartEngine.validate(
                specification: specification,
                snapshot: snapshot,
                profiles: AutoChartProfiler.profileIndex(snapshot)
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

    @Test func redundantFamilyChannelsAreRejectedWithoutBanningDiscreteEvents() {
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [category, facet, measure],
            rows: [
                [.text("A"), .text("East"), .double(1)],
                [.text("B"), .text("West"), .double(2)],
            ])
        let heatmap = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: category.id, y: category.id),
            aggregation: .count)
        let facetEqualsX = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: category.id, y: measure.id, facet: category.id),
            facetBaseFamily: .bar)
        let facetEqualsSeries = AutoChartSpecification(
            family: .faceted,
            encoding: .init(
                x: category.id, y: measure.id, series: facet.id, facet: facet.id),
            facetBaseFamily: .bar)
        #expect(!AutoChartEngine.validate(specification: heatmap, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: facetEqualsX, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: facetEqualsSeries, for: input).isValid)

        let eventDate = AutoChartColumn(
            id: "event-date", name: "event_date",
            hints: AutoChartColumnHints(semanticType: .temporal))
        let events = table(
            columns: [category, eventDate],
            rows: [[.text("A"), .text("2026-01-01")]])
        let discreteEvent = AutoChartSpecification(
            family: .range,
            encoding: .init(
                x: category.id,
                start: eventDate.id,
                end: eventDate.id),
            orientation: .horizontal)
        #expect(AutoChartEngine.validate(specification: discreteEvent, for: events).isValid)
    }

    @Test func legacyFacetsInferTheirBaseWhileExplicitBasesControlValidation() {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [ordinal, facet, measure],
            rows: [
                [.integer(1), .text("East"), .double(1)],
                [.integer(2), .text("West"), .double(2)],
            ])
        let legacy = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: ordinal.id, y: measure.id, facet: facet.id))
        let legacyValidation = AutoChartEngine.validate(specification: legacy, for: input)
        #expect(legacyValidation.isValid)
        #expect(legacyValidation.issues.contains { $0.severity == .warning })

        let line = AutoChartSpecification(
            family: .faceted,
            encoding: legacy.encoding,
            facetBaseFamily: .line)
        let scatter = AutoChartSpecification(
            family: .faceted,
            encoding: legacy.encoding,
            facetBaseFamily: .scatter)
        #expect(AutoChartEngine.validate(specification: line, for: input).isValid)
        #expect(!AutoChartEngine.validate(specification: scatter, for: input).isValid)
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

    @Test func explicitQuantitativeColumnsRejectNonNumericRows() {
        let quantitative = AutoChartColumn(
            id: "quantitative", name: "quantitative",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let input = table(
            columns: [category, quantitative],
            rows: [
                [.text("A"), .double(1)],
                [.text("B"), .text("not-a-number")],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: quantitative.id))
        let validation = AutoChartEngine.validate(
            specification: specification,
            for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message == "Quantitative field quantitative contains non-numeric values."
            })
    }

    @Test func nonFiniteQuantitativeValuesAreOmittedWithoutInvalidatingCharts() throws {
        let quantitative = AutoChartColumn(
            id: "quantitative", name: "quantitative",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .measure))
        let input = table(
            columns: [category, quantitative],
            rows: [
                [.text("A"), .double(1)],
                [.text("B"), .double(.nan)],
                [.text("C"), .double(3)],
            ])
        let recommendation = try #require(
            AutoChartEngine.recommendations(for: input).chartRecommendations.first {
                $0.specification.family == .bar
            })
        let validation = AutoChartEngine.validate(
            specification: recommendation.specification,
            for: input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: recommendation.specification)

        #expect(validation.isValid)
        #expect(!validation.issues.contains { $0.message.contains("non-numeric") })
        #expect(
            validation.issues.contains {
                $0.severity == .warning
                    && $0.message
                        == "Quantitative field quantitative contains non-finite values that will be omitted."
            })
        #expect(prepared.map(\.xLabel) == ["A", "C"])
    }

    @Test func bubbleOmitsNonFinitePositionsButRejectsNonFiniteSizes() {
        func quantitative(_ id: String) -> AutoChartColumn {
            AutoChartColumn(
                id: AutoChartColumnID(rawValue: id),
                name: id,
                hints: AutoChartColumnHints(semanticType: .quantitative))
        }
        let x = quantitative("x")
        let y = quantitative("y")
        let size = quantitative("size")
        let specification = AutoChartSpecification(
            family: .bubble,
            encoding: .init(x: x.id, y: y.id, size: size.id))
        let positionsInput = table(
            columns: [x, y, size],
            rows: [
                [.double(1), .double(2), .double(3)],
                [.double(.nan), .double(4), .double(5)],
                [.double(6), .double(.infinity), .double(7)],
            ])
        let positionValidation = AutoChartEngine.validate(
            specification: specification,
            for: positionsInput)
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(positionsInput),
            specification: specification)

        #expect(positionValidation.isValid)
        #expect(
            positionValidation.issues.filter { $0.severity == .warning }.map(\.message) == [
                "Quantitative field x contains non-finite values that will be omitted.",
                "Quantitative field y contains non-finite values that will be omitted.",
            ])
        #expect(prepared.count == 1)

        let sizesInput = table(
            columns: [x, y, size],
            rows: [
                [.double(1), .double(2), .double(3)],
                [.double(4), .double(5), .double(.nan)],
            ])
        let sizeValidation = AutoChartEngine.validate(
            specification: specification,
            for: sizesInput)
        #expect(!sizeValidation.isValid)
        #expect(
            sizeValidation.issues.contains {
                $0.severity == .error
                    && $0.message == "Quantitative field size contains non-finite values."
            })
        // One defect reports once: a present-but-non-finite size isn't missing.
        #expect(
            !sizeValidation.issues.contains {
                $0.message == "Bubble sizes must not contain missing values."
            })
    }

    @Test func compositionRejectsNonFiniteMeasuresInsteadOfRenderingAPartialWhole() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(1)],
                [.text("B"), .text("Two"), .double(.nan)],
            ])
        let specifications = [
            AutoChartSpecification(
                family: .donut,
                encoding: .init(x: category.id, y: measure.id),
                aggregation: .sum),
            AutoChartSpecification(
                family: .stackedBar,
                encoding: .init(x: category.id, y: measure.id, series: series.id),
                stacking: .standard),
            AutoChartSpecification(
                family: .normalizedBar,
                encoding: .init(x: category.id, y: measure.id, series: series.id),
                stacking: .normalized),
        ]

        for specification in specifications {
            let validation = AutoChartEngine.validate(specification: specification, for: input)
            #expect(!validation.isValid)
            #expect(
                validation.issues.contains {
                    $0.severity == .error
                        && $0.message == "Quantitative field measure contains non-finite values."
                })
            // The non-finite error already names the defect, so the measure must
            // not also be reported as missing or as non-positive.
            #expect(
                !validation.issues.contains {
                    $0.message == "Composition measures must not contain missing values."
                        || $0.message == "Composition requires positive values."
                })
        }
    }

    @Test func compositionPositivityIsReportedOnlyForCompleteMeasures() {
        func donut(_ rows: [[AutoChartValue]]) -> [String] {
            AutoChartEngine.validate(
                specification: AutoChartSpecification(
                    family: .donut,
                    encoding: .init(x: category.id, y: measure.id),
                    aggregation: .sum),
                for: table(columns: [category, measure], rows: rows)
            ).issues.map(\.message)
        }
        let positive = "Composition requires positive values."

        // A complete measure that isn't positive is exactly what this error is for.
        #expect(donut([[.text("A"), .double(1)], [.text("B"), .double(-2)]]).contains(positive))
        #expect(donut([[.text("A"), .double(1)], [.text("B"), .double(0)]]).contains(positive))
        #expect(donut([]).contains(positive))
        // Non-finite and missing measures are already reported by their own,
        // more specific errors, so they must not also be called non-positive.
        let nonFinite = donut([[.text("A"), .double(.nan)], [.text("B"), .double(.infinity)]])
        #expect(nonFinite.contains("Quantitative field measure contains non-finite values."))
        #expect(!nonFinite.contains(positive))
        let missing = donut([[.text("A"), .double(1)], [.text("B"), .null]])
        #expect(missing.contains("Composition measures must not contain missing values."))
        #expect(!missing.contains(positive))
    }

    @Test func explicitNominalBinaryValuesFailCompletenessValidation() {
        let binaryCategory = AutoChartColumn(
            id: "binary-category", name: "binary_category",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [binaryCategory, category],
            rows: [
                [.binary(Data([1])), .text("A")],
                [.text("Renderable"), .text("B")],
            ])
        let heatmap = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: binaryCategory.id, y: category.id),
            aggregation: .count)
        let validation = AutoChartEngine.validate(specification: heatmap, for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message == "Heatmap x categories must not contain missing values."
            })
    }

    @Test func nonFiniteNominalValuesAreNotPreparedAsMarks() {
        let nominalNumber = AutoChartColumn(
            id: "nominal-number", name: "nominal_number",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [nominalNumber, measure],
            rows: [
                [.double(.nan), .double(1)],
                [.double(.nan), .double(2)],
                [.integer(1), .double(3)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: nominalNumber.id, y: measure.id))
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(AutoChartEngine.validate(specification: specification, for: input).isValid)
        #expect(prepared.count == 1)
        #expect(prepared.first?.sourceRowIDs == ["r2"])
        #expect(prepared.first?.xIdentity != nil)
    }

    @Test func nonFiniteDatesAreWarnedAndNotRenderableInAnySemanticType() {
        let nonFinite = Date(timeIntervalSinceReferenceDate: .nan)
        let nominalDate = AutoChartColumn(
            id: "nominal-date", name: "nominal_date",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [date, nominalDate, measure],
                rows: [
                    [.date(nonFinite), .date(nonFinite), .double(1)],
                    [.text("2026-01-01"), .text("2026-01-01"), .double(2)],
                ]))
        let profiles = AutoChartProfiler.profileIndex(snapshot)

        #expect(
            AutoChartProfiler.identity(.date(nonFinite), semanticType: .temporal) == .missing)
        #expect(AutoChartProfiler.identity(.date(nonFinite), semanticType: nil) == .missing)
        #expect(profiles[date.id]?.nonNullCount == 2)
        #expect(profiles[date.id]?.temporalValues.count == 1)
        #expect(profiles[date.id]?.renderableValueCount == 1)
        #expect(profiles[nominalDate.id]?.renderableValueCount == 1)

        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id))
        let validation = AutoChartEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles
        )
        let issues = validation.issues
        #expect(validation.isValid)
        #expect(
            issues.contains {
                $0.severity == .warning
                    && $0.message
                        == "Temporal field date contains non-finite dates that will be omitted."
            })
        #expect(!issues.contains { $0.message.contains("unparseable") })
    }

    @Test func rangeRejectsNonFiniteEndpointsThatPreparationDrops() {
        let end = AutoChartColumn(
            id: "end", name: "end",
            hints: AutoChartColumnHints(semanticType: .temporal, role: .intervalEnd))
        let input = table(
            columns: [category, date, end],
            rows: [
                [
                    .text("A"),
                    .date(Date(timeIntervalSinceReferenceDate: .nan)),
                    .date(Date(timeIntervalSinceReferenceDate: 0)),
                ]
            ])
        let specification = AutoChartSpecification(
            family: .range,
            encoding: .init(x: category.id, start: date.id, end: end.id),
            orientation: .horizontal)
        let validation = AutoChartEngine.validate(specification: specification, for: input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(!validation.isValid)
        #expect(prepared.isEmpty)
        #expect(
            validation.issues.contains {
                $0.severity == .error
                    && $0.message == "Temporal field date contains non-finite dates."
            })
        #expect(
            !validation.issues.contains {
                $0.message == "Range starts must not contain missing values."
            })
    }

    @Test func aggregationOverflowProducesAValidationError() {
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .sum)
        let validation = AutoChartEngine.validate(specification: specification, for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message
                    == "Aggregation of quantitative field measure produces non-finite values."
            })
    }

    @Test func stackedTotalsMustRemainFiniteBeforeRendering() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(halfExtreme)],
                [.text("A"), .text("Two"), .double(halfExtreme)],
                [.text("A"), .text("Three"), .double(halfExtreme)],
            ])
        let specifications = [
            AutoChartSpecification(
                family: .stackedBar,
                encoding: .init(x: category.id, y: measure.id, series: series.id),
                stacking: .standard),
            AutoChartSpecification(
                family: .normalizedBar,
                encoding: .init(x: category.id, y: measure.id, series: series.id),
                stacking: .normalized),
        ]

        for specification in specifications {
            let validation = AutoChartEngine.validate(
                specification: specification,
                for: input)
            #expect(!validation.isValid)
            #expect(
                validation.issues.contains {
                    $0.message
                        == "Stacking quantitative field measure produces non-finite totals."
                })
        }
    }

    @Test func donutPreparationIsCheckedEvenWhenAggregationIsNone() {
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
            ])
        let specification = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: measure.id))
        let validation = AutoChartEngine.validate(
            specification: specification,
            for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message
                    == "Aggregation of quantitative field measure produces non-finite values."
            })
    }

    @Test func donutSectorTotalMustRemainFinite() {
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(halfExtreme)],
                [.text("B"), .double(halfExtreme)],
                [.text("C"), .double(halfExtreme)],
            ])
        let specification = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .sum)
        let validation = AutoChartEngine.validate(
            specification: specification,
            for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message
                    == "Composition of quantitative field measure produces a non-finite total."
            })
    }

    @Test func recommendationsFullyValidatePreparedDomainsBeforeReturning() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(halfExtreme)],
                [.text("A"), .text("Two"), .double(halfExtreme)],
                [.text("A"), .text("Three"), .double(halfExtreme)],
            ])
        let recommendations = AutoChartEngine.recommendations(for: input)

        #expect(!recommendations.chartRecommendations.isEmpty)
        for recommendation in recommendations.chartRecommendations {
            #expect(
                AutoChartEngine.validate(
                    specification: recommendation.specification,
                    for: input
                ).isValid)
        }
        #expect(
            !recommendations.chartRecommendations.contains {
                [.stackedBar, .normalizedBar].contains($0.specification.family)
            })
    }

    @Test func aggregatedFiniteValuesCannotOverflowTheirAxisSpan() {
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [facet, category, measure],
            rows: [
                [.text("West"), .text("A"), .double(halfExtreme)],
                [.text("West"), .text("A"), .double(halfExtreme)],
                [.text("East"), .text("A"), .double(-halfExtreme)],
                [.text("East"), .text("A"), .double(-halfExtreme)],
            ])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: category.id, y: measure.id, facet: facet.id),
            aggregation: .sum,
            facetBaseFamily: .bar)
        let snapshot = AutoChartSnapshot(input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let validation = AutoChartEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles,
            preparedData: prepared)

        #expect(profiles[measure.id]?.hasFiniteNumericSpan == true)
        #expect(prepared.compactMap(\.yNumber).allSatisfy { $0.isFinite })
        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message
                    == "Aggregated quantitative field measure spans a range too large to render safely."
            })
    }

    #if canImport(Charts) && canImport(SwiftUI)
    @Test @MainActor func nonFiniteDatesCannotBoundASharedFacetAxis() throws {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [facet, date, measure],
            rows: [
                [.text("West"), .date(Date(timeIntervalSinceReferenceDate: .nan)), .double(1)],
                [.text("East"), .text("2026-01-01"), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: date.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .line)
        let prepared = AutoChartDataPreparation.data(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(prepared.count == 1)
        // Building the view computes the shared date domain after the non-finite
        // row has been omitted.
        let view = AutoChartView(
            table: input,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Non-finite date test"]))
        #expect(preparedData(in: view)?.count == 1)
        let domain: ClosedRange<Date>? = reflectedOptionalStoredValue(
            named: "sharedXDateDomain",
            in: view)
        #expect(domain?.lowerBound.timeIntervalSinceReferenceDate.isFinite == true)
        #expect(domain?.upperBound.timeIntervalSinceReferenceDate.isFinite == true)
    }

    private func extremeNumericFacetFixture(
        oneSided: Bool = false
    ) -> (
        quantitativeX: AutoChartColumn,
        input: TestTable,
        specification: AutoChartSpecification
    ) {
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let quantitativeX = AutoChartColumn(
            id: "quantitative-x", name: "quantitative_x",
            hints: AutoChartColumnHints(semanticType: .quantitative, role: .dimension))
        let finiteExtreme = Double.greatestFiniteMagnitude
        let input = table(
            columns: [facet, quantitativeX, measure],
            rows: [
                [.text("West"), .double(-finiteExtreme), .double(1)],
                [.text("East"), .double(oneSided ? 0 : finiteExtreme), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: quantitativeX.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .scatter)
        return (quantitativeX, input, specification)
    }

    private func extremeTemporalFacetFixture() -> (
        input: TestTable,
        specification: AutoChartSpecification
    ) {
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let finiteExtreme = Double.greatestFiniteMagnitude
        let input = table(
            columns: [facet, date, measure],
            rows: [
                [
                    .text("West"),
                    .date(Date(timeIntervalSinceReferenceDate: -finiteExtreme)),
                    .double(1),
                ],
                [
                    .text("East"),
                    .date(Date(timeIntervalSinceReferenceDate: finiteExtreme)),
                    .double(2),
                ],
            ])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: date.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .line)
        return (input, specification)
    }

    @Test @MainActor func extremeQuantitativeFacetSpanIsRejectedAndHasNoDomain() {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let fixture = extremeNumericFacetFixture()
        let view = AutoChartView(
            table: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite-domain test"]))
        let domain: ClosedRange<Double>? = reflectedOptionalStoredValue(
            named: "sharedXNumberDomain",
            in: view)
        #expect(domain == nil)
        #expect(
            AutoChartEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).issues.contains {
                $0.message
                    == "Quantitative field quantitative-x spans a range too large to render safely."
            })
    }

    @Test @MainActor func oneSidedExtremeQuantitativeFacetDomainRemainsFinite() {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let fixture = extremeNumericFacetFixture(oneSided: true)
        let view = AutoChartView(
            table: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite unpadded-domain test"]))
        let domain: ClosedRange<Double>? = reflectedOptionalStoredValue(
            named: "sharedXNumberDomain",
            in: view)
        #expect(domain != nil)
        #expect(domain.map { ($0.upperBound - $0.lowerBound).isFinite } == true)
        #expect(
            AutoChartEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).isValid)
    }

    @Test @MainActor func extremeQuantitativeSpanDisablesZoom() {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let fixture = extremeNumericFacetFixture()
        let scatter = AutoChartSpecification(
            family: .scatter,
            encoding: .init(x: fixture.quantitativeX.id, y: measure.id))
        let view = AutoChartView(
            table: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: scatter,
                score: 0,
                rationale: ["Finite-zoom test"]))
        let zoomCount: Int? = reflectedStoredValue(
            named: "numberZoomValueCount",
            in: view)
        let zoomSpan: Double? = reflectedStoredValue(
            named: "numberZoomSpan",
            in: view)
        #expect(zoomCount == 0)
        #expect(zoomSpan?.isFinite == true)
    }

    @Test @MainActor func extremeTemporalFacetSpanIsRejectedAndHasNoDomain() {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let fixture = extremeTemporalFacetFixture()
        let view = AutoChartView(
            table: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite date-domain test"]))
        let domain: ClosedRange<Date>? = reflectedOptionalStoredValue(
            named: "sharedXDateDomain",
            in: view)
        #expect(domain == nil)
        #expect(
            AutoChartEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).issues.contains {
                $0.message == "Temporal field date spans a range too large to render safely."
            })
    }

    @Test @MainActor func extremeTemporalSpanDisablesZoom() {
        AutoChartRenderCache.removeAll()
        defer { AutoChartRenderCache.removeAll() }
        let fixture = extremeTemporalFacetFixture()
        let line = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id))
        let view = AutoChartView(
            table: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: line,
                score: 0,
                rationale: ["Finite date-zoom test"]))
        let timeZoomCount: Int? = reflectedStoredValue(
            named: "timeZoomValueCount",
            in: view)
        let timeZoomSpan: TimeInterval? = reflectedStoredValue(
            named: "timeZoomSpan",
            in: view)
        #expect(timeZoomCount == 0)
        #expect(timeZoomSpan?.isFinite == true)
    }
    #endif

    @Test func valueSortsUseCanonicalIdentityAndSourceOrderForTies() {
        let nominalNumber = AutoChartColumn(
            id: "nominal-number", name: "nominal_number",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [nominalNumber, measure],
            rows: [
                [.double(2), .double(1)],
                [.integer(2), .double(1)],
                [.double(2), .double(1)],
            ])
        func prepared(_ sort: AutoChartSort) -> [AutoChartDatum] {
            AutoChartDataPreparation.data(
                snapshot: AutoChartSnapshot(input),
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: nominalNumber.id, y: measure.id),
                    sort: sort))
        }

        // Value ties keep the canonical identity tie-breaker ascending for both sort
        // directions, so these expectations are intentionally equal.
        let expectedTieOrder = ["row-0-r0", "row-2-r2", "row-1-r1"]
        #expect(prepared(.ascending).map(\.id) == expectedTieOrder)
        #expect(prepared(.descending).map(\.id) == expectedTieOrder)
    }

    @Test func valueSortTiesOrderByVisibleLabelBeforeIdentity() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(5)],
                [.text("Zoo"), .double(5)],
                [.text("Alpha"), .double(5)],
            ])
        func prepared(_ sort: AutoChartSort) -> [String?] {
            AutoChartDataPreparation.data(
                snapshot: AutoChartSnapshot(input),
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: category.id, y: measure.id),
                    sort: sort)
            ).map(\.xLabel)
        }

        // Identity strings are length prefixed, so ordering ties by identity alone
        // would sort these by name length and read as arbitrary.
        #expect(prepared(.ascending) == ["A", "Alpha", "Zoo"])
        #expect(prepared(.descending) == ["A", "Alpha", "Zoo"])
    }

    @Test func familySpecificChannelsAreRejectedWhenTheRendererWouldIgnoreThem() {
        let input = table(
            columns: [category, measure, date],
            rows: [[.text("A"), .double(1), .text("2026-01-01")]])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(
                x: category.id,
                y: measure.id,
                size: measure.id,
                start: date.id,
                end: date.id),
            binCount: 5)
        let messages = AutoChartEngine.validate(
            specification: specification,
            for: input
        ).issues.map(\.message)

        #expect(messages.contains("Bar does not support a size encoding."))
        #expect(messages.contains("Bar does not support a start encoding."))
        #expect(messages.contains("Bar does not support an end encoding."))
        #expect(messages.contains("Bar does not support a histogram bin count."))
    }

    @Test func nonFiniteNumericStorageStillInfersQuantitativeSemantics() {
        let quantitative = AutoChartColumn(
            id: "quantitative", name: "quantitative",
            hints: AutoChartColumnHints(role: .measure))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [quantitative],
                rows: [[.double(1)], [.double(.infinity)]]))

        #expect(AutoChartProfiler.profiles(snapshot).first?.semanticType == .quantitative)
    }

    @Test func quantitativeValidationIssuesFollowEncodingDeclarationOrder() {
        func quantitative(_ id: String) -> AutoChartColumn {
            AutoChartColumn(
                id: AutoChartColumnID(rawValue: id),
                name: id,
                hints: AutoChartColumnHints(semanticType: .quantitative))
        }
        let x = quantitative("x")
        let y = quantitative("y")
        let size = quantitative("size")
        let input = table(
            columns: [x, y, size],
            rows: [[.text("bad-x"), .text("bad-y"), .text("bad-size")]])
        let specification = AutoChartSpecification(
            family: .bubble,
            encoding: .init(x: x.id, y: y.id, size: size.id))

        let messages = AutoChartEngine.validate(
            specification: specification,
            for: input
        ).issues.map(\.message).filter { $0.contains("contains non-numeric values") }

        #expect(
            messages == [
                "Quantitative field x contains non-numeric values.",
                "Quantitative field y contains non-numeric values.",
                "Quantitative field size contains non-numeric values.",
            ])
    }

    @Test func repeatedTemporalEncodingsProduceOneParseIssue() {
        let temporal = AutoChartColumn(
            id: "temporal", name: "temporal",
            hints: AutoChartColumnHints(semanticType: .temporal))
        let input = table(
            columns: [category, temporal],
            rows: [[.text("A"), .text("not-a-date")]])
        let specification = AutoChartSpecification(
            family: .range,
            encoding: .init(
                x: category.id,
                start: temporal.id,
                end: temporal.id))

        let messages = AutoChartEngine.validate(
            specification: specification,
            for: input
        ).issues.map(\.message).filter { $0.contains("contains unparseable values") }

        #expect(messages == ["Temporal field temporal contains unparseable values."])
    }

    @Test func validationMemoSeparatesSnapshots() {
        let firstSnapshot = AutoChartSnapshot(
            table(
                columns: [category, measure],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("B"), .double(2)],
                ]))
        let secondSnapshot = AutoChartSnapshot(
            table(
                columns: [category, measure],
                rows: [
                    [.text("A"), .double(1)],
                    [.text("A"), .double(2)],
                ]))
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id))
        let memo = AutoChartEngine.AutoChartValidationMemo()
        func profiles(
            _ snapshot: AutoChartSnapshot
        ) -> [AutoChartColumnID: AutoChartColumnProfile] {
            AutoChartProfiler.profileIndex(snapshot)
        }

        let first = AutoChartEngine.validate(
            specification: specification,
            snapshot: firstSnapshot,
            profiles: profiles(firstSnapshot),
            memo: memo)
        let second = AutoChartEngine.validate(
            specification: specification,
            snapshot: secondSnapshot,
            profiles: profiles(secondSnapshot),
            memo: memo)

        #expect(first.isValid)
        #expect(
            second.issues.contains {
                $0.message == "Duplicate marks require an explicit safe aggregation."
            })
    }

    @Test func signedZeroUsesTheSameIdentityForValidationAndRendering() {
        let mixed = AutoChartColumn(
            id: "mixed", name: "mixed",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [mixed, measure],
            rows: [
                [.double(0.0), .double(1)],
                [.double(-0.0), .double(2)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: mixed.id, y: measure.id))
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification)

        #expect(Set(prepared.compactMap(\.xIdentity)).count == 1)
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

    @Test func exactAndFallbackNumericIdentitiesHaveMeaningfulQualifiers() {
        let labels = disambiguatedCategoryLabels([
            (identity: "exact-number:3:1e0", label: "1"),
            (identity: "double:4607182418800017408", label: "1"),
        ])

        #expect(labels["exact-number:3:1e0"] == "1 (Exact Number)")
        #expect(labels["double:4607182418800017408"] == "1 (Double)")
    }

    @Test func disambiguatedLabelsDoNotCollideWithExistingLabels() {
        let labels = disambiguatedCategoryLabels([
            (identity: "integer:1", label: "1"),
            (identity: "text:1:1", label: "1"),
            (identity: "text:11:qualified", label: "1 (Integer)"),
            (identity: "text:13:qualified-2", label: "1 (Integer) 2"),
        ])
        #expect(labels["text:11:qualified"] == "1 (Integer)")
        #expect(labels["text:13:qualified-2"] == "1 (Integer) 2")
        #expect(Set(labels.values).count == labels.count)
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

    @Test func selectionHelpersPreserveBinRangesAndRejectAnglesPastTotal() {
        let bins = [
            AutoChartDatum(
                id: "first", sourceRowIDs: ["r0"], xLabel: "0–10",
                xNumber: 5, yNumber: 1),
            AutoChartDatum(
                id: "second", sourceRowIDs: ["r1"], xLabel: "10–20",
                xNumber: 15, yNumber: 2),
        ]
        #expect(
            AutoChartSelectionPreparation.numberSelectionLabel(
                for: [bins[0]],
                selectedNumber: 5,
                family: .histogram) == "0–10")
        #expect(AutoChartSelectionPreparation.angleMatch(to: 2, in: bins)?.id == "second")
        #expect(AutoChartSelectionPreparation.angleMatch(to: 4, in: bins) == nil)

        let sectors = [
            AutoChartDatum(id: "missing-lineage", sourceRowIDs: [], yNumber: 1),
            AutoChartDatum(id: "selectable", sourceRowIDs: ["r2"], yNumber: 2),
        ]
        #expect(AutoChartSelectionPreparation.angleMatch(to: 0.5, in: sectors) == nil)
        #expect(AutoChartSelectionPreparation.angleMatch(to: 2, in: sectors)?.id == "selectable")
        #expect(
            AutoChartSelectionPreparation.selection(
                for: [], label: "Missing", aggregation: .none) == nil)
        #expect(
            AutoChartSelectionPreparation.selection(
                for: [sectors[0]], label: "Missing", aggregation: .none) == nil)
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
