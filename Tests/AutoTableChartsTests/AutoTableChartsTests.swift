import Dispatch
import Foundation
import Testing

@testable import AutoTableCharts

private let posixCategoryFormatters = AutoChartFormatters(
    locale: Locale(identifier: "en_US_POSIX"),
    timeZone: .gmt)

private func renderedValueSemantics(
    columnID: AutoChartColumnID?,
    rangeStartColumnID: AutoChartColumnID? = nil,
    rangeEndColumnID: AutoChartColumnID? = nil
) -> AutoChartRenderedMeasureSemantics {
    AutoChartRenderedMeasureSemantics(
        columnID: columnID,
        rangeStartColumnID: rangeStartColumnID,
        rangeEndColumnID: rangeEndColumnID,
        kind: .value,
        usesNormalizedMeasureAxis: false)
}

private func renderedAggregationSemantics(
    _ aggregation: AutoChartAggregation,
    columnID: AutoChartColumnID?
) -> AutoChartRenderedMeasureSemantics {
    AutoChartRenderedMeasureSemantics(
        columnID: columnID,
        kind: .aggregated(aggregation),
        usesNormalizedMeasureAxis: false)
}

private func preparedDatumValues(
    snapshot: AutoChartSnapshot,
    specification: AutoChartSpecification,
    profiles: [AutoChartColumnID: AutoChartColumnProfile]? = nil
) -> [AutoChartDatum] {
    AutoChartDataPreparation.preparedData(
        snapshot: snapshot,
        specification: specification,
        profiles: profiles ?? AutoChartProfiler.profileIndex(snapshot)
    ).data
}

private func preparedRenderCore<Table: AutoChartTable>(
    for table: Table,
    specification: AutoChartSpecification
) throws -> AutoChartRenderCore {
    let snapshot = AutoChartSnapshot(table)
    return try AutoChartRenderCore.prepare(
        snapshot: snapshot,
        profiles: AutoChartProfiler.profileIndex(snapshot),
        contentFingerprint: snapshot.contentFingerprint,
        estimatedStorageCost: snapshot.estimatedStorageCost,
        recommendation: AutoChartRecommendation(
            specification: specification,
            score: 0,
            rationale: ["Direct render-core test"]))
}

#if canImport(Charts) && canImport(SwiftUI)
import Charts
import SwiftUI

private func preparedPresentation<Table: AutoChartTable>(
    for table: Table,
    recommendation: AutoChartRecommendation
) -> (data: [AutoChartDatum], presentation: AutoChartRenderPresentation) {
    let snapshot = AutoChartSnapshot(table)
    let profiles = AutoChartProfiler.profileIndex(snapshot)
    let prepared = AutoChartDataPreparation.preparedData(
        snapshot: snapshot,
        specification: recommendation.specification,
        profiles: profiles)
    return (
        prepared.data,
        AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: recommendation.specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics))
}
#endif

private struct TestRow: AutoChartRow {
    var chartRowID: String
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
    var chartRowID: String
    var values: [AutoChartColumnID: AutoChartValue]
    var counter = ChartValueReadCounter()

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

    var chartDataKey: AutoChartDataKey? {
        chartDataIdentity.map {
            AutoChartDataKey(identity: $0, revision: chartDataVersion ?? "")
        }
    }
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
                chartRowID: "r\(index)",
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
        measureSemantics: .init(source: .aggregated(.sum), rollup: .additive)))
private let date = AutoChartColumn(
    id: "date", name: "valuation_date",
    hints: AutoChartColumnHints(semanticType: .temporal, role: .dimension))

@Suite struct ModelTests {
    @Test func erasedRowIDRetainedCostUsesAConsistentBaseline() {
        let baseline = MemoryLayout<AnyHashable>.stride

        #expect(AutoChartErasedRowID(1).estimatedRetainedCost == baseline)
        #expect(AutoChartErasedRowID(UUID()).estimatedRetainedCost == baseline)
        #expect(AutoChartErasedRowID("id").estimatedRetainedCost == baseline + 2)
        #expect(AutoChartErasedRowID(Data([1, 2, 3])).estimatedRetainedCost == baseline + 3)
    }

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

        let accessibleDate = AutoChartFormatters(timeZone: .gmt).format(
            column: nil,
            value: .date(value),
            context: .markAccessibility)
        let label = AutoChartAccessibility.markLabel(
            name: accessibleDate,
            valueDescription: "2")
        #expect(label == "\(accessibleDate), 2")
        #expect(!label.contains("T00:00:00Z"))
    }

    @Test func categoryStringsPreservePrecisionAndUseExplicitPresentationSettings() throws {
        let first = AutoChartValue.double(1_000.0624)
        let second = AutoChartValue.double(1_000.0625)
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")

        #expect(first.categoryString(locale: english) != second.categoryString(locale: english))
        #expect(first.categoryString(locale: english) != first.categoryString(locale: german))
        #expect(first.categoryString(locale: german)?.contains(",") == true)
        #expect(first.categoryString(locale: english) == "1000.0624")
        #expect(AutoChartValue.double(0.0009).categoryString(locale: english) == "0.0009")
        #expect(AutoChartValue.double(1e-30).categoryString(locale: english) == "1E-30")
        let small = 0.000_000_123_456_789_012_345_6
        #expect(
            AutoChartValue.double(small).categoryString(locale: english)
                != AutoChartValue.double(small.nextUp).categoryString(locale: english))
        let decimalFirst = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345678",
                locale: Locale(identifier: "en_US_POSIX")))
        let decimalSecond = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345679",
                locale: Locale(identifier: "en_US_POSIX")))
        #expect(
            AutoChartValue.decimal(decimalFirst).categoryString(locale: english)
                != AutoChartValue.decimal(decimalSecond).categoryString(locale: english))
        #expect(
            AutoChartValue.decimal(decimalFirst).categoryString(locale: english)
                == "0.12345678901234567890123456789012345678")
        #expect(
            AutoChartValue.double(.nan).categoryString(locale: english)
                == AutoChartValue.unrepresentableValuePlaceholder)
        #expect(
            AutoChartValue.decimal(.nan).categoryString(locale: english)
                == AutoChartValue.unrepresentableValuePlaceholder)

        let date = try Date("2026-01-01T00:30:00Z", strategy: .iso8601)
        let pacific = try #require(TimeZone(secondsFromGMT: -8 * 3_600))
        #expect(
            AutoChartValue.date(date).categoryString(
                locale: english,
                timeZone: .gmt)
                != AutoChartValue.date(date).categoryString(
                    locale: english,
                    timeZone: pacific))
        let arabic = Locale(identifier: "ar_EG")
        #expect(AutoChartValue.integer(1_234).categoryString(locale: arabic) == "١٢٣٤")
        #expect(AutoChartValue.double(1_234.5).categoryString(locale: arabic) == "١٢٣٤٫٥")
        let buddhistLocale = Locale(identifier: "en_US@calendar=buddhist")
        let buddhistLabel = AutoChartValue.date(
            Date(timeIntervalSinceReferenceDate: 0)
        ).categoryString(locale: buddhistLocale, timeZone: .gmt)
        let buddhistAccessibilityLabel = AutoChartFormatters(
            locale: buddhistLocale,
            timeZone: .gmt
        ).format(
            column: nil,
            value: .date(Date(timeIntervalSinceReferenceDate: 0)),
            context: .markAccessibility)
        #expect(buddhistLabel?.contains("2544") == true)
        #expect(buddhistLabel?.contains("2001") == false)
        #expect(buddhistAccessibilityLabel.contains("2544"))
        #expect(!buddhistAccessibilityLabel.contains("2001"))
    }

    @Test func categoryPresentationChoosesNumericNotationPerValue() {
        let numericCategory = AutoChartColumn(
            id: "numeric-category",
            name: "Numeric category",
            hints: .init(semanticType: .nominal, role: .dimension))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [numericCategory, measure],
                rows: [
                    [.double(1), .double(1)],
                    [.double(1e-30), .double(2)],
                ]))
        let specification = AutoChartSpecification.bar(
            category: numericCategory.id,
            measure: measure.id)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: AutoChartFormatters(
                locale: Locale(identifier: "en_US"),
                timeZone: .gmt))

        #expect(Set(resolved.xDisplayLabels.values) == ["1", "1E-30"])
    }

    @Test func categoryPresentationUsesTheHostLocaleCalendar() throws {
        let dateCategory = AutoChartColumn(
            id: "date-category",
            name: "Date category",
            hints: .init(semanticType: .nominal, role: .dimension))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [dateCategory, measure],
                rows: [[.date(Date(timeIntervalSinceReferenceDate: 0)), .double(1)]]))
        let specification = AutoChartSpecification.bar(
            category: dateCategory.id,
            measure: measure.id)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: AutoChartFormatters(
                locale: Locale(identifier: "en_US@calendar=buddhist"),
                timeZone: .gmt))
        let label = try #require(resolved.xDisplayLabels.values.first)

        #expect(label.contains("2544"))
        #expect(!label.contains("2001"))
    }

    @Test func conciseCategoryNumbersPreserveTheLengthBoundaryAndRemainLazy() {
        var scientificFormatCount = 0
        func scientific() -> String {
            scientificFormatCount += 1
            return "1E24"
        }
        let limit = AutoChartCategoryNumberPolicy.maximumReadableStandardLength
        let readable = String(repeating: "1", count: limit)
        let oversized = String(repeating: "1", count: limit + 1)

        #expect(
            AutoChartCategoryNumberPolicy.concise(
                standard: readable,
                scientific: scientific) == readable)
        #expect(scientificFormatCount == 0)
        #expect(
            AutoChartCategoryNumberPolicy.concise(
                standard: oversized,
                scientific: scientific) == "1E24")
        #expect(scientificFormatCount == 1)
    }

    @Test func legacyCurrencyFormattingUsesAttributedAmountFields() throws {
        let affixless = AttributedString("123.0")
        #expect(
            AutoChartLegacyCurrencyFormatting.replacingMagnitude(
                in: affixless,
                scientificMagnitude: "1.23E2") == "123.0")
        #expect(
            AutoChartLegacyCurrencyFormatting.replacingMagnitude(
                in: AttributedString("-123.0"),
                scientificMagnitude: "1.23E2") == "-123.0")

        // A numeric currency code deliberately collides with the amount text.
        // The attributed currency field must remain untouched while only the
        // attributed number field is replaced.
        let style = FloatingPointFormatStyle<Double>.Currency(
            code: "123",
            locale: Locale(identifier: "en_US")
        ).precision(.significantDigits(1...17))
        let standard = 123.0.formatted(style.attributed)
        let plainStandard = String(standard.characters)
        let amountRange = try #require(
            plainStandard.range(of: "123", options: .backwards))
        let expected = plainStandard.replacingCharacters(
            in: amountRange,
            with: "1.23E2")

        #expect(
            AutoChartLegacyCurrencyFormatting.replacingMagnitude(
                in: standard,
                scientificMagnitude: "1.23E2") == expected)
        #expect(expected.hasPrefix("123"))

        let signedStyle = FloatingPointFormatStyle<Double>.Currency(
            code: "USD",
            locale: Locale(identifier: "en_US")
        ).precision(.significantDigits(1...17))
        let signedStandard = (-123.0).formatted(signedStyle.attributed)
        #expect(
            AutoChartLegacyCurrencyFormatting.replacingMagnitude(
                in: signedStandard,
                scientificMagnitude: "1.23E2") == "-$1.23E2")
    }

    @Test func categoryDefaultsHonorUnitsWithoutCollapsingExactValues() throws {
        let currencyCategory = AutoChartColumn(
            id: "currency-category",
            name: "Currency category",
            hints: .init(
                semanticType: .nominal,
                role: .dimension,
                unit: .currency(code: "USD")))
        let percentCategory = AutoChartColumn(
            id: "percent-category",
            name: "Percent category",
            hints: .init(
                semanticType: .nominal,
                role: .dimension,
                unit: .percent(fractional: false)))
        let fractionalPercentCategory = AutoChartColumn(
            id: "fractional-percent-category",
            name: "Fractional percent category",
            hints: .init(
                semanticType: .nominal,
                role: .dimension,
                unit: .percent(fractional: true)))
        let areaCategory = AutoChartColumn(
            id: "area-category",
            name: "Area category",
            hints: .init(
                semanticType: .nominal,
                role: .dimension,
                unit: .area(unit: "sq ft")))
        let formatter = AutoChartFormatters(
            locale: Locale(identifier: "en_US"),
            timeZone: .gmt)
        let first = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345678",
                locale: Locale(identifier: "en_US_POSIX")))
        let second = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345679",
                locale: Locale(identifier: "en_US_POSIX")))
        let firstLabel = formatter.formatCategory(
            column: currencyCategory,
            value: .decimal(first),
            context: .axisTick)
        let secondLabel = formatter.formatCategory(
            column: currencyCategory,
            value: .decimal(second),
            context: .axisTick)

        #expect(firstLabel.contains("$"))
        #expect(secondLabel.contains("$"))
        #expect(firstLabel != secondLabel)
        #expect(
            formatter.formatCategory(
                column: percentCategory,
                value: .integer(25),
                context: .axisTick) == "25%")
        #expect(
            formatter.formatCategory(
                column: fractionalPercentCategory,
                value: .integer(1),
                context: .axisTick) == "100%")
        #expect(
            formatter.formatCategory(
                column: percentCategory,
                value: .double(1.1),
                context: .axisTick) == "1.1%")
        #expect(
            formatter.formatCategory(
                column: areaCategory,
                value: .integer(1_000),
                context: .axisTick) == "1000 sq ft")
        let tiny = try #require(
            Decimal(
                string: "0.0000000000000000000000000000012345678",
                locale: Locale(identifier: "en_US_POSIX")))
        let tinyCurrency = formatter.formatCategory(
            column: currencyCategory,
            value: .decimal(tiny),
            context: .axisTick)
        let tinyPercent = formatter.formatCategory(
            column: percentCategory,
            value: .decimal(tiny),
            context: .axisTick)
        let currencyStyle = Decimal.FormatStyle.Currency(
            code: "USD",
            locale: Locale(identifier: "en_US")
        ).precision(.significantDigits(1...38))
        let percentStyle = Decimal.FormatStyle.Percent(
            locale: Locale(identifier: "en_US")
        ).scale(1).precision(.significantDigits(1...38))
        #expect(tinyCurrency.contains("$"))
        #expect(tinyCurrency.contains("E"))
        #expect(
            tinyCurrency.count
                <= AutoChartCategoryNumberPolicy.maximumReadableStandardLength)
        if #available(iOS 18, macOS 15, tvOS 18, watchOS 11, *) {
            #expect(tinyCurrency == tiny.formatted(currencyStyle.notation(.scientific)))
        }
        #expect(tinyCurrency.count < tiny.formatted(currencyStyle).count)
        #expect(tinyPercent.contains("%"))
        #expect(tinyPercent.contains("E"))
        #expect(
            tinyPercent.count
                <= AutoChartCategoryNumberPolicy.maximumReadableStandardLength)
        #expect(tinyPercent == tiny.formatted(percentStyle.notation(.scientific)))
        #expect(tinyPercent.count < tiny.formatted(percentStyle).count)

        for code in ["ZZZ", "USDX"] {
            let column = AutoChartColumn(
                id: AutoChartColumnID(rawValue: "currency-\(code)"),
                name: "Currency \(code)",
                hints: .init(
                    semanticType: .nominal,
                    role: .dimension,
                    unit: .currency(code: code)))
            let style = Decimal.FormatStyle.Currency(
                code: code,
                locale: Locale(identifier: "en_US")
            ).precision(.significantDigits(1...38))
            let formatted = formatter.formatCategory(
                column: column,
                value: .decimal(tiny),
                context: .axisTick)
            if #available(iOS 18, macOS 15, tvOS 18, watchOS 11, *) {
                let standard = tiny.formatted(style)
                let scientific = tiny.formatted(style.notation(.scientific))
                #expect(
                    formatted
                        == (scientific.count < standard.count ? scientific : standard))
            }
            if code == "ZZZ" {
                #expect(formatted.contains("ZZZ"))
                #expect(formatted.count < tiny.formatted(style).count)
            } else {
                #expect(!formatted.contains("$"))
                #expect(!formatted.contains("USD"))
            }
        }

        let specification = AutoChartSpecification.bar(
            category: currencyCategory.id,
            measure: measure.id)
        let selection = AutoChartSelection(
            sourceRowIDs: Set([0]),
            dimensions: [
                AutoChartSelectedDimension(
                    columnID: currencyCategory.id,
                    value: .decimal(first))
            ],
            family: .bar,
            specificationID: specification.id,
            markID: "currency-category")
        #expect(
            selection.presentation(
                columns: [currencyCategory],
                formatters: formatter
            ).label == firstLabel)
    }

    @Test func accessibilityLabelsIncludeSeriesContext() {
        #expect(
            AutoChartAccessibility.markLabel(
                name: "Office",
                series: "North",
                facetTitle: "Region",
                facetValue: "West",
                valueDescription: "2") == "Office, North, Region: West, 2")
        // Absent components drop out rather than leaving empty separators.
        #expect(
            AutoChartAccessibility.markLabel(
                name: "Office",
                series: nil,
                facetTitle: nil,
                facetValue: "",
                valueDescription: "2") == "Office, 2")
    }

    /// A resolver receives the label's pieces, not one pre-joined English
    /// sentence, so a host can translate and reorder them.
    @Test func markAccessibilityMessagesCarryTheirComponentsAsArguments() {
        // The resolver closure is `@Sendable`; these bodies are synchronous
        // and single-threaded, so a reference box is enough to observe it.
        final class Recorder: @unchecked Sendable {
            var message: AutoChartMessage?
        }
        let recorder = Recorder()
        let resolver = AutoChartTextResolver { message in
            recorder.message = message
            return "resolved"
        }
        #expect(
            AutoChartAccessibility.markLabel(
                name: "Office",
                series: "North",
                facetTitle: "Region",
                facetValue: "West",
                valueDescription: "$12,000",
                textResolver: resolver) == "resolved")
        #expect(recorder.message?.code == .markAccessibility)
        #expect(recorder.message?.category == .accessibility)
        #expect(
            recorder.message?.arguments == [
                "name": .string("Office"),
                "series": .string("North"),
                "facet": .string("Region: West"),
                "facetTitle": .string("Region"),
                "facetValue": .string("West"),
                "value": .string("$12,000"),
            ])
        #expect(recorder.message?.defaultText == "Office, North, Region: West, $12,000")
        #expect(
            AutoChartAccessibility.markLabel(
                name: "Office",
                facetTitle: "Region",
                facetValue: "West",
                textResolver: AutoChartTextResolver { message in
                    guard case .string(let facet)? = message.arguments["facet"] else {
                        return nil
                    }
                    return facet
                }) == "Region: West")

        #expect(
            AutoChartAccessibility.heatmapLabel(
                category: "Office",
                secondaryCategory: "Boston",
                valueDescription: "3",
                textResolver: resolver) == "resolved")
        #expect(
            recorder.message?.arguments == [
                "category": .string("Office"),
                "secondaryCategory": .string("Boston"),
                "value": .string("3"),
            ])
    }

    @Test func histogramAccessibilityResolvesEagerlyAndCachesRenderLookups() {
        final class Recorder: @unchecked Sendable {
            var requests: [AutoChartFormattingRequest] = []
            var messages: [AutoChartMessage] = []
        }
        let column = AutoChartColumn(
            id: "histogram-value",
            name: "Histogram value",
            hints: .init(semanticType: .quantitative, role: .measure))
        let recorder = Recorder()
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "de_DE"),
            timeZone: .gmt
        ) { request, _, _ in
            recorder.requests.append(request)
            return nil
        }
        let resolver = AutoChartTextResolver { message in
            recorder.messages.append(message)
            return nil
        }
        let label = AutoChartAccessibility.histogramBinLabel(
            lower: 1.5,
            upper: 2.75,
            column: column,
            formatters: formatters,
            textResolver: resolver)

        #expect(label.contains("1,5"))
        #expect(label.contains("2,75"))
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.allSatisfy { $0.column?.id == column.id })
        #expect(recorder.requests.allSatisfy { $0.context == .markAccessibility })
        #expect(
            recorder.messages.map(\.code) == [
                .histogramBinAccessibility, .markAccessibilityRange,
            ])
        #expect(recorder.messages.first?.arguments["start"] == .string("1,5"))
        #expect(recorder.messages.first?.arguments["end"] == .string("2,75"))
        #expect(
            AutoChartAccessibility.histogramBinLabel(
                lower: 1.5,
                upper: 2.75,
                column: column,
                formatters: formatters,
                textResolver: AutoChartTextResolver { message in
                    message.code == .histogramBinAccessibility ? "Localized bin" : nil
                }) == "Localized bin")
        #expect(
            AutoChartAccessibility.histogramBinLabel(
                lower: 1.5,
                upper: 2.75,
                column: column,
                formatters: formatters,
                textResolver: AutoChartTextResolver { message in
                    message.code == .markAccessibilityRange ? "Legacy localized bin" : nil
                }) == "Legacy localized bin")

        let snapshot = AutoChartSnapshot(
            table(
                columns: [column],
                rows: [[.double(1.5)], [.double(2.75)]]))
        let specification = AutoChartSpecification.histogram(
            value: column.id,
            binCount: 2)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        recorder.requests = []
        recorder.messages = []
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: resolver,
            formatters: formatters)
        let requestCount = recorder.requests.count
        let messageCount = recorder.messages.count
        let histogramMessages = recorder.messages.filter {
            $0.code == .histogramBinAccessibility || $0.code == .markAccessibilityRange
        }
        let labels = prepared.data.map(resolved.histogramBinAccessibilityLabel(for:))

        #expect(labels.count == prepared.data.count)
        #expect(requestCount == prepared.data.count * 2)
        #expect(histogramMessages.count == prepared.data.count * 2)
        #expect(
            histogramMessages.map(\.code) == prepared.data.flatMap { _ in
                [AutoChartMessage.Code.histogramBinAccessibility, .markAccessibilityRange]
            })
        #expect(
            prepared.data.map(resolved.histogramBinAccessibilityLabel(for:)) == labels)
        #expect(recorder.requests.count == requestCount)
        #expect(recorder.messages.count == messageCount)
    }

    @Test func histogramAccessibilityCacheDistinguishesReusedIDsByBounds() {
        let column = AutoChartColumn(
            id: "histogram-value",
            name: "Histogram value",
            hints: .init(semanticType: .quantitative, role: .measure))
        let snapshot = AutoChartSnapshot(
            table(columns: [column], rows: [[.double(1)], [.double(4)]]))
        let specification = AutoChartSpecification.histogram(
            value: column.id,
            binCount: 2)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let data = [
            AutoChartDatum(
                id: "reused-bin",
                sourceRowIDs: [0],
                lower: 1,
                upper: 2),
            AutoChartDatum(
                id: "reused-bin",
                sourceRowIDs: [1],
                lower: 3,
                upper: 4),
        ]
        let resolved = presentation.resolvedPresentation(
            data: data,
            using: .default)

        let first = resolved.histogramBinAccessibilityLabel(for: data[0])
        let second = resolved.histogramBinAccessibilityLabel(for: data[1])

        #expect(first != second)
        #expect(!first.contains(AutoChartValue.unrepresentableValuePlaceholder))
        #expect(!second.contains(AutoChartValue.unrepresentableValuePlaceholder))
        #expect(resolved.histogramBinAccessibilityLabel(for: data[0]) == first)
        #expect(resolved.histogramBinAccessibilityLabel(for: data[1]) == second)
    }

    @Test func histogramAccessibilityCacheDistinguishesSignedZeroBounds() {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var requests = 0

            func recordRequest() {
                lock.lock()
                requests += 1
                lock.unlock()
            }

            var requestCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return requests
            }
        }

        let column = AutoChartColumn(
            id: "histogram-value",
            name: "Histogram value",
            hints: .init(semanticType: .quantitative, role: .measure))
        let snapshot = AutoChartSnapshot(
            table(columns: [column], rows: [[.double(0)], [.double(1)]]))
        let specification = AutoChartSpecification.histogram(
            value: column.id,
            binCount: 1)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let negativeZero = AutoChartDatum(
            id: "signed-zero-bin",
            sourceRowIDs: [0],
            lower: -0.0,
            upper: 1)
        let positiveZero = AutoChartDatum(
            id: "signed-zero-bin",
            sourceRowIDs: [0],
            lower: 0.0,
            upper: 1)
        let recorder = Recorder()
        let resolved = presentation.resolvedPresentation(
            data: [negativeZero, positiveZero],
            using: .default,
            formatters: AutoChartFormatters(request: { request, _, _ in
                recorder.recordRequest()
                guard case .double(let number) = request.value, number == 0 else {
                    return nil
                }
                return number.sign == .minus ? "negative zero" : "positive zero"
            }))

        let first = resolved.histogramBinAccessibilityLabel(for: negativeZero)
        let second = resolved.histogramBinAccessibilityLabel(for: positiveZero)

        #expect(first.contains("negative zero"))
        #expect(second.contains("positive zero"))
        #expect(first != second)
        #expect(recorder.requestCount == 4)
    }

    @Test func histogramAccessibilityConcurrentLookupsReturnEagerPrimaryLabel() {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var requests = 0
            private var messages = 0
            private var labels: [String] = []

            func recordRequest() {
                lock.lock()
                requests += 1
                lock.unlock()
            }

            func recordMessage(_ code: AutoChartMessage.Code) {
                guard code == .histogramBinAccessibility || code == .markAccessibilityRange else {
                    return
                }
                lock.lock()
                messages += 1
                lock.unlock()
            }

            func recordLabel(_ label: String) {
                lock.lock()
                labels.append(label)
                lock.unlock()
            }

            var counts: (requests: Int, messages: Int) {
                lock.lock()
                defer { lock.unlock() }
                return (requests, messages)
            }

            var capturedLabels: [String] {
                lock.lock()
                defer { lock.unlock() }
                return labels
            }
        }

        let column = AutoChartColumn(
            id: "histogram-value",
            name: "Histogram value",
            hints: .init(semanticType: .quantitative, role: .measure))
        let snapshot = AutoChartSnapshot(
            table(columns: [column], rows: [[.double(1.5)], [.double(2.75)]]))
        let specification = AutoChartSpecification.histogram(
            value: column.id,
            binCount: 2)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let recorder = Recorder()
        let formatters = AutoChartFormatters { _, _, _ in
            recorder.recordRequest()
            return "Host endpoint"
        }
        let hostLabel = "Host-resolved histogram bin"
        let resolver = AutoChartTextResolver { message in
            recorder.recordMessage(message.code)
            return message.code == .histogramBinAccessibility ? hostLabel : nil
        }
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: resolver,
            formatters: formatters)
        let datum = prepared.data[0]
        let baselineCounts = recorder.counts

        let observersFinished = DispatchGroup()
        for _ in 0..<32 {
            observersFinished.enter()
            DispatchQueue.global().async {
                recorder.recordLabel(
                    resolved.histogramBinAccessibilityLabel(for: datum))
                observersFinished.leave()
            }
        }
        let observersCompletedBeforeTimeout =
            observersFinished.wait(timeout: .now() + 10) == .success

        #expect(observersCompletedBeforeTimeout)
        guard observersCompletedBeforeTimeout else { return }
        #expect(recorder.capturedLabels.count == 32)
        #expect(Set(recorder.capturedLabels) == Set([hostLabel]))
        #expect(baselineCounts.requests == prepared.data.count * 2)
        #expect(baselineCounts.messages == prepared.data.count)
        #expect(recorder.counts == baselineCounts)
    }

    @Test func histogramAccessibilityEagerResolutionUsesLegacyMessage() {
        final class Recorder: @unchecked Sendable {
            var messages: [AutoChartMessage.Code] = []
        }

        let column = AutoChartColumn(
            id: "histogram-value",
            name: "Histogram value",
            hints: .init(semanticType: .quantitative, role: .measure))
        let snapshot = AutoChartSnapshot(
            table(columns: [column], rows: [[.double(1.5)], [.double(2.75)]]))
        let specification = AutoChartSpecification.histogram(
            value: column.id,
            binCount: 2)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let recorder = Recorder()
        let hostLabel = "Legacy host-resolved histogram bin"
        let resolver = AutoChartTextResolver { message in
            if message.code == .histogramBinAccessibility
                || message.code == .markAccessibilityRange
            {
                recorder.messages.append(message.code)
            }
            return message.code == .markAccessibilityRange ? hostLabel : nil
        }
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: resolver)
        let messageCount = recorder.messages.count

        #expect(
            prepared.data.map(resolved.histogramBinAccessibilityLabel(for:))
                == Array(repeating: hostLabel, count: prepared.data.count))
        #expect(
            recorder.messages == prepared.data.flatMap { _ in
                [AutoChartMessage.Code.histogramBinAccessibility, .markAccessibilityRange]
            })
        #expect(recorder.messages.count == messageCount)
    }

    @Test func quantitativeAccessibilityUsesTheNumericPosition() {
        #expect(
            AutoChartAccessibility.markLabel(
                name: "10",
                valueDescription: "2") == "10, 2")
    }

    @Test func heatmapAccessibilityIncludesBothCategoriesAndCount() {
        let datum = AutoChartDatum(
            id: "heatmap",
            sourceRowIDs: [0, 1, 2],
            yNumber: 3)

        #expect(
            AutoChartAccessibility.heatmapLabel(
                category: "Office",
                secondaryCategory: "Boston",
                valueDescription: "3") == "Office, Boston, 3")
        #expect(datum.sourceRowIDs == [0, 1, 2])
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
            sourceRowIDs: [0],
            xLabel: "Lease",
            startDate: start,
            endDate: end)
        let interval = "From \(start.formatted(style)) to \(end.formatted(style))"
        #expect(datum.startDate == start)
        #expect(datum.endDate == end)
        #expect(
            AutoChartAccessibility.markLabel(
                name: "Lease",
                valueDescription: interval) == "Lease, \(interval)")
    }
}

// The render preparation cache is process-wide, and Swift Testing runs sibling
// suites in parallel, so `.serialized` orders this suite only against itself.
// What keeps the other suites that touch the cache — `ValidationAndLineageTests`
// and `DocumentationExamplesTests` — from mutating it mid-assertion is that
// every touch is main-actor isolated (`AutoChartView.init` inherits SwiftUI's
// `View` isolation) and every body here is a synchronous `@MainActor` function,
// which runs as one job that cannot suspend between a `configure`/`removeAll`
// and the counts it asserts. Keep it that way: making one of these bodies
// `async`, or awaiting anything mid-body, reopens that window and the exact
// counts below start to flake.
@Suite struct AnalyzerCacheTests {
    @Test func configurationClampsNegativeLimits() {
        let configuration = AutoChartAnalyzerConfiguration(
            tables: .init(maximumEntries: -1),
            analyses: .init(maximumEntries: -1),
            preparedCharts: .init(maximumEntries: -1),
            maximumRetainedCost: -1)

        #expect(configuration.tables.maximumEntries == 0)
        #expect(configuration.analyses.maximumEntries == 0)
        #expect(configuration.preparedCharts.maximumEntries == 0)
        #expect(configuration.maximumRetainedCost == 0)
    }

    @Test func keyedAnalysisScansCellsOnceAndReusesEveryLayer() async throws {
        let counter = ChartValueReadCounter()
        let rows = (0..<6).map { index in
            CountingRow(
                chartRowID: "r\(index)",
                values: [
                    category.id: .text(index.isMultiple(of: 2) ? "Office" : "Retail"),
                    measure.id: .double(Double(index + 1)),
                ],
                counter: counter)
        }
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: rows,
            chartDataIdentity: "result",
            chartDataVersion: "revision-1")
        let analyzer = AutoChartAnalyzer()

        let first = try await analyzer.analyze(input)
        let readsAfterFirst = counter.count
        let second = try await analyzer.analyze(input)

        #expect(readsAfterFirst == rows.count * 2)
        #expect(counter.count == readsAfterFirst)
        #expect(first.primaryChart?.recommendation.id == second.primaryChart?.recommendation.id)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.hits == 1)
        #expect(statistics.analyses.hits == 1)
        #expect(statistics.preparedCharts.entries == 1)
    }

    @Test func keyedAnalysisHitKeepsDisabledTableLayerEmpty() async throws {
        let counter = ChartValueReadCounter()
        let rows = (0..<6).map { index in
            CountingRow(
                chartRowID: "r\(index)",
                values: [
                    category.id: .text(index.isMultiple(of: 2) ? "Office" : "Retail"),
                    measure.id: .double(Double(index + 1)),
                ],
                counter: counter)
        }
        let input = VersionedCountingTable(
            chartColumns: [category, measure],
            chartRows: rows,
            chartDataIdentity: "analysis-only",
            chartDataVersion: "revision-1")
        let analyzer = AutoChartAnalyzer(
            configuration: AutoChartAnalyzerConfiguration(
                tables: .init(maximumEntries: 0),
                analyses: .init(maximumEntries: 4),
                preparedCharts: .init(maximumEntries: 0),
                maximumRetainedCost: 1_024 * 1_024))

        _ = try await analyzer.analyze(input)
        let readsAfterFirstAnalysis = counter.count
        let baseline = await analyzer.cacheStatistics
        _ = try await analyzer.analyze(input)

        #expect(readsAfterFirstAnalysis == rows.count * 2)
        #expect(counter.count == readsAfterFirstAnalysis)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.tables.entries == 0)
        #expect(statistics.tables.misses == baseline.tables.misses)
        #expect(statistics.analyses.hits == baseline.analyses.hits + 1)
    }

    @Test func alternativesPrepareExplicitlyAndCacheWithinOneAnalyzer() async throws {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("Office"), .double(20)],
                [.text("Retail"), .double(10)],
                [.text("Industrial"), .double(15)],
            ])
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(input)
        guard case .charts(let recommendations) = analysis.outcome else {
            Issue.record("Expected chart recommendations")
            return
        }
        let alternative = try #require(recommendations.dropFirst().first)

        let afterAnalysis = await analyzer.cacheStatistics
        #expect(afterAnalysis.preparedCharts.entries == 1)
        let first = try await analysis.prepare(alternative.id)
        let second = try await analysis.prepare(alternative.id)

        #expect(first.recommendation.id == alternative.id)
        #expect(second.recommendation.id == alternative.id)
        let afterAlternative = await analyzer.cacheStatistics
        #expect(afterAlternative.preparedCharts.entries == 2)
        #expect(afterAlternative.preparedCharts.hits >= 1)
    }

    @Test func trimDoesNotInvalidateCallerHeldAnalysis() async throws {
        let input = table(
            columns: [category, measure],
            rows: [[.text("Office"), .double(20)], [.text("Retail"), .double(10)]])
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(input)
        let primaryID = try #require(analysis.primaryChart?.recommendation.id)

        await analyzer.trim(to: .minimum)
        let trimmed = await analyzer.cacheStatistics
        #expect(trimmed.tables.entries == 0)
        #expect(trimmed.analyses.entries == 0)
        #expect(trimmed.preparedCharts.entries == 0)

        let preparedAgain = try await analysis.prepare(primaryID)
        #expect(preparedAgain.recommendation.id == primaryID)
    }

    @Test func analyzerInstancesHaveIndependentCaches() async throws {
        let input = table(
            columns: [category, measure],
            rows: [[.text("Office"), .double(20)], [.text("Retail"), .double(10)]])
        let first = AutoChartAnalyzer()
        let second = AutoChartAnalyzer()

        _ = try await first.analyze(input)
        let firstStats = await first.cacheStatistics
        let secondStats = await second.cacheStatistics

        #expect(firstStats.analyses.entries == 1)
        #expect(secondStats.analyses.entries == 0)
    }

    @Test func removeAllResetsRetainedStateAndStatistics() async throws {
        let input = table(
            columns: [category, measure],
            rows: [[.text("Office"), .double(20)]])
        let analyzer = AutoChartAnalyzer()
        _ = try await analyzer.analyze(input)
        await analyzer.removeAll()

        #expect(await analyzer.cacheStatistics == AutoChartCacheStatistics())
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
        #expect(profile.temporalValueCount == 1)
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

    @Test func duplicateColumnIDsAreRejectedAtSnapshotBoundary() {
        let first = AutoChartColumn(
            id: "duplicate", name: "first",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let second = AutoChartColumn(
            id: "duplicate", name: "second",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let input = TestTable(
            chartColumns: [first, second],
            chartRows: [TestRow(chartRowID: "r0", values: ["duplicate": .double(1)])])
        #expect(throws: AutoChartDatasetError.self) {
            try AutoChartSnapshot(validating: input)
        }
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
        let highest = try #require(AutoChartRecommendationEngine.bestCandidatesByID([first, higher]).first)
        #expect(AutoChartRecommendationEngine.bestCandidatesByID([first, higher]).count == 1)
        #expect(highest.specification.title == "Higher title")

        let stableTie = try #require(AutoChartRecommendationEngine.bestCandidatesByID([first, equal]).first)
        #expect(stableTie.specification.title == "First title")
    }

    @Test func scalarUsesKPI() {
        let result = AutoChartRecommendationEngine.recommendations(
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
        let result = AutoChartRecommendationEngine.recommendations(for: input)
        #expect(result.chartRecommendations.first?.specification.family == .kpi)
        #expect(result.chartRecommendations.first?.specification.encoding.y == populated.id)

        let emptyKPI = AutoChartSpecification(
            family: .kpi,
            encoding: .init(y: empty.id))
        #expect(!AutoChartRecommendationEngine.validate(specification: emptyKPI, for: input).isValid)
    }

    @Test func categoryMeasureUsesBarAndDonutAlternatives() {
        let result = AutoChartRecommendationEngine.recommendations(
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
                measureSemantics: .init(source: .aggregated(.sum), rollup: .additive)))
        let input = table(
            columns: [segment, income],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let bar = try #require(
            AutoChartRecommendationEngine.recommendations(for: input).chartRecommendations.first {
                $0.specification.family == .bar
            })
        #expect(bar.specification.title == "NOI by Segment")
    }

    @Test func temporalMeasureUsesLine() {
        let result = AutoChartRecommendationEngine.recommendations(
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

        let result = AutoChartRecommendationEngine.recommendations(for: input)

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
        let result = AutoChartRecommendationEngine.recommendations(
            for: table(
                columns: [measure, second],
                rows: [[.double(10), .double(0.8)], [.double(12), .double(0.9)]]),
            context: AutoChartContext(goal: .relationship))
        #expect(result.chartRecommendations.first?.specification.family == .scatter)
    }

    @Test func singleMeasureOffersHistogramAndBoxPlot() {
        let result = AutoChartRecommendationEngine.recommendations(
            for: table(
                columns: [measure],
                rows: [[.double(1)], [.double(2)], [.double(4)], [.double(8)]]),
            context: AutoChartContext(goal: .distribution))
        let families = Set(result.chartRecommendations.map(\.specification.family))
        #expect(families.contains(.histogram))
        #expect(families.contains(.boxPlot))
    }

    @Test func groupedBoxPlotCategoryLimitIncludesMissingGroup() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("B"), .double(2)],
                [.null, .double(3)],
            ])
        let overLimitOptions = AutoChartOptions(
            maximumRecommendations: 12,
            maximumCategories: 2)
        let withinLimitOptions = AutoChartOptions(
            maximumRecommendations: 12,
            maximumCategories: 3)

        let overLimitRecommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            options: overLimitOptions)
        let withinLimitRecommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            options: withinLimitOptions)

        #expect(
            !overLimitRecommendations.chartRecommendations.contains {
                $0.specification.family == .boxPlot
                    && $0.specification.encoding.x == category.id
            })
        #expect(
            withinLimitRecommendations.chartRecommendations.contains {
                $0.specification.family == .boxPlot
                    && $0.specification.encoding.x == category.id
            })
    }

    @Test func groupedBoxPlotRequiresTwoRenderableCategories() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.null, .double(2)],
            ])
        let options = AutoChartOptions(
            maximumRecommendations: 12,
            maximumCategories: 2)

        let recommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            options: options)

        #expect(
            !recommendations.chartRecommendations.contains {
                $0.specification.family == .boxPlot
                    && $0.specification.encoding.x == category.id
            })
    }

    @Test func groupedBoxPlotCategoryLimitIgnoresRowsWithoutMeasures() {
        let withinLimit = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("B"), .double(2)],
                [.null, .null],
            ])
        let oneContributingCategory = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.null, .null],
            ])
        let options = AutoChartOptions(
            maximumRecommendations: 12,
            maximumCategories: 2)

        let withinLimitRecommendations = AutoChartRecommendationEngine.recommendations(
            for: withinLimit,
            options: options)
        let oneCategoryRecommendations = AutoChartRecommendationEngine.recommendations(
            for: oneContributingCategory,
            options: options)

        #expect(
            withinLimitRecommendations.chartRecommendations.contains {
                $0.specification.family == .boxPlot
                    && $0.specification.encoding.x == category.id
            })
        #expect(
            !oneCategoryRecommendations.chartRecommendations.contains {
                $0.specification.family == .boxPlot
                    && $0.specification.encoding.x == category.id
            })
    }

    @Test func categoricalPairOffersHeatmap() {
        let second = AutoChartColumn(
            id: "market", name: "market",
            hints: AutoChartColumnHints(semanticType: .nominal, role: .dimension))
        let result = AutoChartRecommendationEngine.recommendations(
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
        let result = AutoChartRecommendationEngine.recommendations(
            for: table(
                columns: [category, date, end],
                rows: [[.text("Lease A"), .text("2026-01-01"), .text("2026-12-31")]]),
            context: AutoChartContext(goal: .range))
        #expect(result.chartRecommendations.contains { $0.specification.family == .range })
    }

    @Test func datedEventsWithMeasuresOfferRangeInsteadOfInvalidBubble() {
        let result = AutoChartRecommendationEngine.recommendations(
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
        let result = AutoChartRecommendationEngine.recommendations(
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
        let recommendations = AutoChartRecommendationEngine.recommendations(for: input)
        #expect(
            recommendations.chartRecommendations.map(\.specification.family) == [
                .bar, .rankedDot, .boxPlot, .histogram, .donut,
            ])
    }

    @Test func unknownAggregationBlocksDuplicateCategoryBars() {
        let unsafeMeasure = AutoChartColumn(
            id: "raw", name: "raw_value",
            hints: AutoChartColumnHints(semanticType: .quantitative, role: .measure))
        let result = AutoChartRecommendationEngine.recommendations(
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
                measureSemantics: .init(
                    source: .aggregated(.mean), rollup: .nonAdditive,
                    preferredTransform: .mean)))
        let result = AutoChartRecommendationEngine.recommendations(
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
                measureSemantics: .init(
                    source: .rowLevel, rollup: .safe(.mean),
                    preferredTransform: .mean)))
        let result = AutoChartRecommendationEngine.recommendations(
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
                measureSemantics: .init(
                    source: .aggregated(.count), rollup: .additive,
                    preferredTransform: .count)))
        let input = table(
            columns: [category, count],
            rows: [
                [.text("A"), .double(2)],
                [.text("A"), .double(3)],
            ])
        let recommendation = AutoChartRecommendationEngine.recommendations(for: input)
            .chartRecommendations.first { $0.specification.family == .bar }
        #expect(recommendation?.specification.aggregation == .sum)
        let data = recommendation.map {
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: $0.specification)
        }
        #expect(data?.first?.yNumber == 5)

        let wrongCount = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: count.id),
            aggregation: .count)
        #expect(!AutoChartRecommendationEngine.validate(specification: wrongCount, for: input).isValid)

        let donut = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: count.id),
            aggregation: .sum)
        #expect(AutoChartRecommendationEngine.validate(specification: donut, for: input).isValid)
    }

    @Test func distinctCountsAreNotCompositionSafeOrImplicitlyRollable() {
        let distinctCount = AutoChartColumn(
            id: "distinct", name: "distinct",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                measureSemantics: .init(
                    source: .aggregated(.countDistinct), rollup: .nonAdditive,
                    preferredTransform: .countDistinct)))
        let input = table(
            columns: [category, distinctCount],
            rows: [
                [.text("A"), .double(2)],
                [.text("A"), .double(3)],
                [.text("B"), .double(4)],
            ])
        let result = AutoChartRecommendationEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition))
        #expect(!result.chartRecommendations.isEmpty)
        #expect(!result.chartRecommendations.contains { $0.specification.family == .donut })
        #expect(!result.chartRecommendations.contains { $0.specification.family == .bar })
    }

    /// Counting rows partitions a whole even when the measure's own values do
    /// not, so a safe count is the one honest composition available to a
    /// measure containing negatives.
    @Test func rowLevelSafeCountsProduceCountAggregatedDonuts() {
        let count = AutoChartColumn(
            id: "count", name: "count",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                measureSemantics: .init(
                    source: .rowLevel, rollup: .safe(.count),
                    preferredTransform: .count)))
        let input = table(
            columns: [category, count],
            rows: [
                [.text("A"), .double(-10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let recommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition)
        ).chartRecommendations
        #expect(
            recommendations.first { $0.specification.family == .bar }?
                .specification.aggregation == .count)
        let donut = recommendations.first { $0.specification.family == .donut }
        #expect(donut?.specification.aggregation == .count)
        let data = donut.map {
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: $0.specification)
        }
        let sectors = data?.compactMap { datum -> (label: String, value: Double)? in
            guard let label = datum.xLabel, let value = datum.yNumber else { return nil }
            return (label, value)
        } ?? []
        let valuesByLabel = Dictionary(grouping: sectors) { $0.label }
            .mapValues { sectors in sectors.map { $0.value } }
        #expect(valuesByLabel == ["A": [2], "B": [1]])
    }

    /// A distinct count does not partition — per-category distinct counts
    /// overlap — so it must not reach a composition family.
    @Test func safeDistinctCountRollupsDoNotEnableComposition() {
        let distinct = AutoChartColumn(
            id: "distinct", name: "distinct",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                measureSemantics: .init(
                    source: .rowLevel, rollup: .safe(.countDistinct))))
        let input = table(
            columns: [category, distinct],
            rows: [
                [.text("A"), .double(10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let recommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            context: AutoChartContext(goal: .composition)
        ).chartRecommendations
        #expect(!recommendations.isEmpty)
        #expect(!recommendations.contains { $0.specification.family == .donut })
        #expect(!recommendations.contains { $0.specification.family == .stackedBar })
    }

    /// A named safe operation cannot make an upstream summary summable: only
    /// summation combines values additively, so the source must vouch for it.
    @Test func safeSumRollupsCannotSumUpstreamMeans() {
        let mean = AutoChartColumn(
            id: "mean", name: "average_price",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                measureSemantics: .init(
                    source: .aggregated(.mean), rollup: .safe(.sum))))
        let input = table(
            columns: [category, mean],
            rows: [
                [.text("A"), .double(10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let validation = AutoChartRecommendationEngine.validate(
            specification: AutoChartSpecification.bar(
                category: category.id, measure: mean.id, aggregation: .sum),
            snapshot: AutoChartSnapshot(input))
        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.severity == .error
                    && $0.messageValue.code == .nonAdditiveSourceSummation
            })
        #expect(
            !AutoChartRecommendationEngine.recommendations(for: input)
                .chartRecommendations
                .contains { $0.specification.aggregation == .sum })
    }

    @Test func nonSumRequestsDoNotReportTheSummationDiagnostic() {
        let mean = AutoChartColumn(
            id: "mean", name: "average_price",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                measureSemantics: .init(
                    source: .aggregated(.mean), rollup: .additive)))
        let input = table(
            columns: [category, mean],
            rows: [
                [.text("A"), .double(10)],
                [.text("A"), .double(20)],
                [.text("B"), .double(30)],
            ])
        let validation = AutoChartRecommendationEngine.validate(
            specification: AutoChartSpecification.bar(
                category: category.id, measure: mean.id, aggregation: .mean),
            snapshot: AutoChartSnapshot(input))

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.severity == .error
                    && $0.messageValue.code == .unsafeAggregation
                    && $0.message == "Aggregation requires an explicitly safe measure."
            })
        #expect(
            !validation.issues.contains {
                $0.messageValue.code == .nonAdditiveSourceSummation
            })
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
        let range = AutoChartRecommendationEngine.recommendations(
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
        let result = AutoChartRecommendationEngine.recommendations(
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
        let scatter = AutoChartRecommendationEngine.recommendations(
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
        let result = AutoChartRecommendationEngine.recommendations(
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
            AutoChartRecommendationEngine.recommendations(
                for: input,
                options: AutoChartOptions(maximumRecommendations: 12)
            ).chartRecommendations.first { $0.specification.family == .faceted })
        #expect(recommendation.specification.encoding.series == series.id)
        #expect(recommendation.specification.encoding.facet == facet.id)
        #expect(recommendation.specification.facetBaseFamily == .line)
        #expect(!recommendation.diagnostics.isEmpty)
        #expect(recommendation.diagnostics.allSatisfy { $0.family == .faceted })
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
            AutoChartRecommendationEngine.recommendations(
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
    @Test func everyDeclaredFamilyValidatesPreparesAndOwnsRenderedSemantics() {
        struct FamilyCase {
            var specification: AutoChartSpecification
            var kind: AutoChartRenderedMeasureKind
            var columnID: AutoChartColumnID?
            var rangeStartColumnID: AutoChartColumnID?
            var rangeEndColumnID: AutoChartColumnID?
            var formattingPurpose: AutoChartFormattingPurpose
            var usesNormalizedMeasureAxis: Bool
        }

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
                measureSemantics: .init(source: .rowLevel, rollup: .unknown)))
        let size = AutoChartColumn(
            id: "size", name: "rentable_sqft",
            hints: AutoChartColumnHints(
                semanticType: .quantitative, role: .measure,
                measureSemantics: .init(source: .rowLevel, rollup: .unknown)))
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
        let inputSnapshot = AutoChartSnapshot(input)
        let inputProfiles = AutoChartProfiler.profileIndex(inputSnapshot)
        let kpiSnapshot = AutoChartSnapshot(
            table(columns: [measure], rows: [[.double(20)]]))
        let kpiProfiles = AutoChartProfiler.profileIndex(kpiSnapshot)
        let xy = AutoChartEncoding(x: category.id, y: measure.id)
        let grouped = AutoChartEncoding(
            x: category.id, y: measure.id, series: series.id)
        func valueCase(
            _ specification: AutoChartSpecification,
            columnID: AutoChartColumnID?,
            rangeStartColumnID: AutoChartColumnID? = nil,
            rangeEndColumnID: AutoChartColumnID? = nil,
            usesNormalizedMeasureAxis: Bool = false
        ) -> FamilyCase {
            FamilyCase(
                specification: specification,
                kind: .value,
                columnID: columnID,
                rangeStartColumnID: rangeStartColumnID,
                rangeEndColumnID: rangeEndColumnID,
                formattingPurpose: .value,
                usesNormalizedMeasureAxis: usesNormalizedMeasureAxis)
        }
        func aggregateCase(
            _ specification: AutoChartSpecification,
            aggregation: AutoChartAggregation,
            columnID: AutoChartColumnID?,
            usesNormalizedMeasureAxis: Bool = false
        ) -> FamilyCase {
            FamilyCase(
                specification: specification,
                kind: .aggregated(aggregation),
                columnID: columnID,
                rangeStartColumnID: nil,
                rangeEndColumnID: nil,
                formattingPurpose: .renderedMeasure(aggregation),
                usesNormalizedMeasureAxis: usesNormalizedMeasureAxis)
        }
        let cases: [FamilyCase] = [
            valueCase(.init(family: .kpi, encoding: .init(y: measure.id)), columnID: measure.id),
            aggregateCase(
                .init(family: .bar, encoding: xy, aggregation: .sum),
                aggregation: .sum, columnID: measure.id),
            aggregateCase(
                .init(family: .rankedDot, encoding: xy, aggregation: .sum),
                aggregation: .sum, columnID: measure.id),
            aggregateCase(
                .init(family: .groupedBar, encoding: grouped, aggregation: .sum),
                aggregation: .sum, columnID: measure.id),
            aggregateCase(
                .init(
                    family: .stackedBar, encoding: grouped,
                    aggregation: .sum, stacking: .standard),
                aggregation: .sum, columnID: measure.id),
            aggregateCase(
                .init(
                    family: .normalizedBar, encoding: grouped,
                    aggregation: .sum, stacking: .normalized),
                aggregation: .sum, columnID: measure.id,
                usesNormalizedMeasureAxis: true),
            valueCase(.init(family: .bar, encoding: xy), columnID: measure.id),
            valueCase(.init(family: .rankedDot, encoding: xy), columnID: measure.id),
            valueCase(.init(family: .groupedBar, encoding: grouped), columnID: measure.id),
            valueCase(
                .init(family: .stackedBar, encoding: grouped, stacking: .standard),
                columnID: measure.id),
            valueCase(
                .init(family: .normalizedBar, encoding: grouped, stacking: .normalized),
                columnID: measure.id,
                usesNormalizedMeasureAxis: true),
            valueCase(
                .init(family: .line, encoding: .init(x: date.id, y: measure.id)),
                columnID: measure.id),
            valueCase(
                .init(family: .pointLine, encoding: .init(x: date.id, y: measure.id)),
                columnID: measure.id),
            valueCase(
                .init(family: .area, encoding: .init(x: date.id, y: measure.id)),
                columnID: measure.id),
            valueCase(
                .init(
                    family: .scatter,
                    encoding: .init(x: measure.id, y: secondMeasure.id)),
                columnID: secondMeasure.id),
            valueCase(
                .init(
                    family: .bubble,
                    encoding: .init(
                        x: measure.id, y: secondMeasure.id, size: size.id)),
                columnID: secondMeasure.id),
            aggregateCase(
                .init(
                    family: .histogram, encoding: .init(x: measure.id),
                    aggregation: .count, binCount: 5),
                aggregation: .count, columnID: nil),
            valueCase(.init(family: .boxPlot, encoding: xy), columnID: measure.id),
            aggregateCase(
                .init(
                    family: .heatmap,
                    encoding: .init(x: category.id, y: series.id),
                    aggregation: .count),
                aggregation: .count, columnID: nil),
            aggregateCase(
                .init(family: .donut, encoding: xy, aggregation: .sum),
                aggregation: .sum, columnID: measure.id),
            valueCase(
                .init(
                    family: .range,
                    encoding: .init(
                        x: category.id, start: date.id, end: end.id)),
                columnID: nil,
                rangeStartColumnID: date.id,
                rangeEndColumnID: end.id),
            valueCase(
                .init(
                    family: .faceted,
                    encoding: .init(
                        x: date.id, y: measure.id, facet: facet.id)),
                columnID: measure.id),
        ]

        #expect(Set(cases.map(\.specification.family)) == Set(AutoChartFamily.allCases))
        for testCase in cases {
            let specification = testCase.specification
            let isKPI = specification.family == .kpi
            let snapshot = isKPI ? kpiSnapshot : inputSnapshot
            let profiles = isKPI ? kpiProfiles : inputProfiles
            let prepared = AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
            #expect(
                AutoChartRecommendationEngine.validate(
                    specification: specification,
                    snapshot: snapshot,
                    profiles: profiles,
                    preparedData: prepared.data
                ).isValid,
                "\(specification.family) should validate")
            #expect(!prepared.data.isEmpty, "\(specification.family) should prepare data")
            #expect(prepared.measureSemantics.kind == testCase.kind)
            #expect(prepared.measureSemantics.columnID == testCase.columnID)
            #expect(
                prepared.measureSemantics.rangeStartColumnID
                    == testCase.rangeStartColumnID)
            #expect(
                prepared.measureSemantics.rangeEndColumnID
                    == testCase.rangeEndColumnID)
            #expect(
                prepared.measureSemantics.formattingPurpose
                    == testCase.formattingPurpose)
            #expect(
                prepared.measureSemantics.usesNormalizedMeasureAxis
                    == testCase.usesNormalizedMeasureAxis)
        }
    }

    @Test func renderCorePreservesValidationWarningsOnSuccess() throws {
        let input = table(
            columns: [date, measure],
            rows: [[.text("2026-01-01"), .double(1)]],
            truncated: true)
        let specification = AutoChartSpecification.line(
            x: date.id,
            measure: measure.id)

        let core = try preparedRenderCore(for: input, specification: specification)
        let expected = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)

        #expect(core.validation == expected)
        #expect(core.validation.isValid)
        #expect(core.validation.issues.contains { $0.severity == .warning })
        #expect(!core.data.isEmpty)
    }

    @Test func renderCoreRejectsStructuralErrorsBeforePreparation() {
        let input = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)], [.text("A"), .double(2)]])
        let specification = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: measure.id))

        do {
            _ = try preparedRenderCore(for: input, specification: specification)
            Issue.record("Expected structural validation to reject the specification.")
        } catch AutoChartPreparationError.invalidSpecification(let validation) {
            #expect(
                validation
                    == AutoChartRecommendationEngine.validate(
                        specification: specification,
                        for: input))
            #expect(validation.issues.contains { $0.messageValue.code == .unsafeAggregation })
        } catch {
            Issue.record("Unexpected preparation error: \(error)")
        }
    }

    @Test func renderCoreRejectsPreparedNumericOverflow() {
        let halfExtreme = Double.greatestFiniteMagnitude / 2
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
                [.text("A"), .double(halfExtreme)],
            ])
        let specification = AutoChartSpecification.bar(
            category: category.id,
            measure: measure.id,
            aggregation: .sum)

        do {
            _ = try preparedRenderCore(for: input, specification: specification)
            Issue.record("Expected prepared numeric-domain validation to reject overflow.")
        } catch AutoChartPreparationError.invalidSpecification(let validation) {
            #expect(
                validation.issues.contains {
                    $0.messageValue.code == .nonFiniteValueOmitted
                        && $0.message.contains("produces non-finite values")
                })
        } catch {
            Issue.record("Unexpected preparation error: \(error)")
        }
    }

    @Test func preparationDerivesNormalizedMeasureAxisFromFamilyAndStacking() {
        let encoding = AutoChartEncoding(x: category.id, y: measure.id)
        let snapshot = AutoChartSnapshot(
            table(columns: [category, measure], rows: [[.text("A"), .double(1)]]))
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        func usesNormalizedAxis(
            family: AutoChartFamily,
            stacking: AutoChartStacking
        ) -> Bool {
            AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: AutoChartSpecification(
                    family: family,
                    encoding: encoding,
                    stacking: stacking),
                profiles: profiles
            ).measureSemantics.usesNormalizedMeasureAxis
        }

        #expect(usesNormalizedAxis(family: .normalizedBar, stacking: .normalized))
        #expect(!usesNormalizedAxis(family: .normalizedBar, stacking: .standard))
        #expect(!usesNormalizedAxis(family: .bar, stacking: .normalized))
    }

    @Test func unaggregatedCategoricalFamiliesRejectDuplicateMarks() {
        let series = AutoChartColumn(
            id: "series", name: "Series",
            hints: .init(semanticType: .nominal, role: .series))
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(1)],
                [.text("A"), .text("One"), .double(2)],
            ])
        let xy = AutoChartEncoding(x: category.id, y: measure.id)
        let grouped = AutoChartEncoding(
            x: category.id, y: measure.id, series: series.id)
        let specifications = [
            AutoChartSpecification(family: .bar, encoding: xy),
            AutoChartSpecification(family: .rankedDot, encoding: xy),
            AutoChartSpecification(family: .donut, encoding: xy),
            AutoChartSpecification(family: .groupedBar, encoding: grouped),
            AutoChartSpecification(
                family: .stackedBar, encoding: grouped, stacking: .standard),
            AutoChartSpecification(
                family: .normalizedBar, encoding: grouped, stacking: .normalized),
        ]

        for specification in specifications {
            #expect(
                AutoChartRecommendationEngine.validate(
                    specification: specification,
                    for: input
                ).issues.contains(where: { $0.messageValue.code == .duplicateMark }),
                "\(specification.family) should reject duplicate marks")
        }
    }

    @Test func invalidManualSpecificationReportsErrors() {
        let input = table(columns: [category], rows: [[.text("A")]])
        let spec = AutoChartSpecification(
            family: .scatter,
            encoding: AutoChartEncoding(x: category.id, y: category.id))
        let validation = AutoChartRecommendationEngine.validate(specification: spec, for: input)
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
        #expect(!AutoChartRecommendationEngine.validate(specification: bubble, for: input).isValid)
        #expect(!AutoChartRecommendationEngine.validate(specification: range, for: input).isValid)
        #expect(!AutoChartRecommendationEngine.validate(specification: faceted, for: input).isValid)
        #expect(
            AutoChartRecommendationEngine.validate(
                specification: barWithFacet, for: input
            ).issues.contains {
                $0.message == "Bar does not support a facet encoding."
            })
        #expect(
            AutoChartRecommendationEngine.validate(
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
        let prepared = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)

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
        let prepared = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)

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
        let prepared = preparedDatumValues(
            snapshot: snapshot,
            specification: specification)
        let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)
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
        let prepared = preparedDatumValues(
            snapshot: snapshot,
            specification: specification)
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(prepared.count == 2)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 2)
        #expect(profile.renderableDistinctCount == 2)
        #expect(profile.isUniqueAtRowGrain)
        #expect(AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
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
        let prepared = preparedDatumValues(
            snapshot: snapshot,
            specification: specification)
        let profile = AutoChartProfiler.profiles(snapshot)[0]

        #expect(prepared.count == 4)
        #expect(Set(prepared.compactMap(\.xIdentity)).count == 2)
        #expect(profile.renderableDistinctCount == 2)
        #expect(!profile.isUniqueAtRowGrain)
        #expect(
            AutoChartRecommendationEngine.validate(
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
        let issues = AutoChartRecommendationEngine.validate(
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
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: spec)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == 3)
        #expect(data.allSatisfy { $0.xLabel == nil })
    }

    @Test func renderPresentationCountsOnlyCategoricalXValues() {
        let categoricalInput = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)], [.text("B"), .double(2)]])
        let categoricalSpecification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id))
        let categoricalSnapshot = AutoChartSnapshot(categoricalInput)
        let categoricalProfiles = AutoChartProfiler.profileIndex(categoricalSnapshot)
        let categoricalPrepared = AutoChartDataPreparation.preparedData(
            snapshot: categoricalSnapshot,
            specification: categoricalSpecification,
            profiles: categoricalProfiles)
        let categoricalPresentation = AutoChartRenderPresentation(
            snapshot: categoricalSnapshot,
            specification: categoricalSpecification,
            profiles: categoricalProfiles,
            data: categoricalPrepared.data,
            measureSemantics: categoricalPrepared.measureSemantics)

        let histogramInput = table(
            columns: [measure],
            rows: [[.double(1)], [.double(2)], [.double(3)]])
        let histogramSpecification = AutoChartSpecification(
            family: .histogram,
            encoding: .init(x: measure.id),
            aggregation: .count,
            binCount: 2)
        let histogramSnapshot = AutoChartSnapshot(histogramInput)
        let histogramProfiles = AutoChartProfiler.profileIndex(histogramSnapshot)
        let histogramPrepared = AutoChartDataPreparation.preparedData(
            snapshot: histogramSnapshot,
            specification: histogramSpecification,
            profiles: histogramProfiles)
        let histogramPresentation = AutoChartRenderPresentation(
            snapshot: histogramSnapshot,
            specification: histogramSpecification,
            profiles: histogramProfiles,
            data: histogramPrepared.data,
            measureSemantics: histogramPrepared.measureSemantics)

        #expect(categoricalPresentation.xCategoryCount == 2)
        #expect(histogramPresentation.xCategoryCount == 0)
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
        let data = preparedDatumValues(
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
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: spec)
        #expect(data.count == 1)
        #expect(data[0].yNumber == 3)
        #expect(data[0].sourceRowIDs == [0, 1])
    }

    @Test func distinctCountPreservesExactNumericSourceIdentity() throws {
        let firstDecimal = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345678",
                locale: Locale(identifier: "en_US_POSIX")))
        let secondDecimal = try #require(
            Decimal(
                string: "0.12345678901234567890123456789012345679",
                locale: Locale(identifier: "en_US_POSIX")))
        let firstInteger: Int64 = 9_007_199_254_740_992
        let fractionalDecimal = try #require(
            Decimal(
                string: "0.1",
                locale: Locale(identifier: "en_US_POSIX")))
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("Integers"), .integer(firstInteger)],
                [.text("Integers"), .integer(firstInteger + 1)],
                [.text("Decimals"), .decimal(firstDecimal)],
                [.text("Decimals"), .decimal(secondDecimal)],
                [.text("Equivalent"), .integer(1)],
                [.text("Equivalent"), .double(1)],
                [.text("Equivalent"), .decimal(1)],
                // Binary 0.1 and exact decimal 0.1 are different source values.
                [.text("Fractional"), .double(0.1)],
                [.text("Fractional"), .decimal(fractionalDecimal)],
            ])
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .countDistinct)
        let prepared = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        let counts = Dictionary(
            uniqueKeysWithValues: prepared.compactMap { datum in
                datum.xLabel.map { ($0, datum.yNumber) }
            })

        #expect(counts["Integers"] == 2)
        #expect(counts["Decimals"] == 2)
        #expect(counts["Equivalent"] == 1)
        #expect(counts["Fractional"] == 2)
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
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        #expect(data.first?.sourceRowIDs == [0, 2])
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
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(data.map(\.xLabel) == ["B", "A"])
        #expect(data.map(\.yNumber) == [4, 2])
    }

    @Test func normalizedNumericCategoryLabelsStayStableAcrossPreparationPaths() {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let forward = table(
            columns: [ordinal, measure],
            rows: [[.integer(1_000), .double(1)], [.double(1_000), .double(3)]])
        let reversed = table(
            columns: [ordinal, measure],
            rows: [[.double(1_000), .double(3)], [.integer(1_000), .double(1)]])
        func data(
            _ input: some AutoChartTable,
            aggregation: AutoChartAggregation
        ) -> [AutoChartDatum] {
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: ordinal.id, y: measure.id),
                    aggregation: aggregation))
        }

        let forwardRaw = data(forward, aggregation: .none)
        let reversedRaw = data(reversed, aggregation: .none)
        let forwardGrouped = data(forward, aggregation: .sum)
        let reversedGrouped = data(reversed, aggregation: .sum)

        #expect(forwardRaw.compactMap(\.xLabel) == ["1000", "1000"])
        #expect(reversedRaw.compactMap(\.xLabel) == ["1000", "1000"])
        #expect(forwardGrouped.count == 1)
        #expect(reversedGrouped.count == 1)
        #expect(forwardGrouped.first?.xLabel == "1000")
        #expect(reversedGrouped.first?.xLabel == "1000")
        #expect(forwardGrouped.first?.yNumber == 4)
        #expect(reversedGrouped.first?.yNumber == 4)
    }

    @Test func histogramHandlesOverflowingFiniteRanges() {
        let input = table(
            columns: [measure], rows: [[.double(-1e308)], [.double(1e308)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 10)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: specification)
        #expect(data.count == 10)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == 2)
        #expect(data.compactMap(\.lower).allSatisfy { $0.isFinite })
        #expect(data.compactMap(\.upper).allSatisfy { $0.isFinite })
    }

    @Test func histogramReportsBoundsThatContainEveryAssignedValue() throws {
        let values = [
            -5.409559967935998e-252,
            6.554786997215165e-237,
            1.3109573994430337e-236,
        ]
        let input = table(
            columns: [measure],
            rows: values.map { [.double($0)] })
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 2)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        for (rowID, value) in values.enumerated() {
            let bin = try #require(data.first { $0.sourceRowIDs.contains(rowID) })
            #expect(try #require(bin.lower) <= value)
            #expect(value <= (try #require(bin.upper)))
        }
    }

    @Test func histogramMergesCollapsedBinsAndKeepsMidpointsDistinct() throws {
        var values = [1.0]
        for _ in 0..<8 {
            values.append(try #require(values.last).nextUp)
        }
        let input = table(
            columns: [measure],
            rows: values.map { [.double($0)] })
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 20)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(data.count < 20)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == values.count)
        #expect(
            data.allSatisfy { datum in
                guard let lower = datum.lower, let upper = datum.upper,
                    let midpoint = datum.xNumber
                else { return false }
                return lower < upper && lower <= midpoint && midpoint < upper
            })
        #expect(
            zip(data, data.dropFirst()).allSatisfy { pair in
                guard let left = pair.0.xNumber, let right = pair.1.xNumber else {
                    return false
                }
                return left < right
            })

        let maximumBin = try #require(
            data.first { $0.sourceRowIDs.contains(values.count - 1) })
        #expect(try #require(maximumBin.lower) < (try #require(maximumBin.upper)))
    }

    @Test func histogramClampsAsymmetricExtremeBoundsToFiniteInputExtrema() throws {
        let maximum = Double.greatestFiniteMagnitude
        let minimum = -0.991 * maximum
        let input = table(
            columns: [measure],
            rows: [[.double(minimum)], [.double(maximum)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 3)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: specification)

        #expect(data.count == 3)
        #expect(data.reduce(0) { $0 + $1.sourceRowIDs.count } == 2)
        #expect(data.compactMap(\.lower).allSatisfy { $0.isFinite })
        #expect(data.compactMap(\.upper).allSatisfy { $0.isFinite })
        #expect(data.compactMap(\.xNumber).allSatisfy { $0.isFinite })
        #expect(try #require(data.first?.lower) == minimum)
        #expect(try #require(data.last?.upper) == maximum)
        #expect(
            zip(data, data.dropFirst()).allSatisfy { pair in
                pair.0.upper == pair.1.lower
            })
    }

    @Test func histogramSingletonUsesReadableFiniteBounds() throws {
        let input = table(columns: [measure], rows: [[.double(1_000)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 10)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input), specification: specification)
        let bin = try #require(data.first)
        let lower = try #require(bin.lower)
        let upper = try #require(bin.upper)
        let formatters = AutoChartFormatters(locale: Locale(identifier: "en_US"))

        #expect(data.count == 1)
        #expect(lower == 950)
        #expect(upper == 1_050)
        #expect(bin.xNumber == 1_000)
        #expect(
            formatters.format(
                column: measure,
                value: .double(lower),
                context: .markAccessibility)
                != formatters.format(
                    column: measure,
                    value: .double(upper),
                    context: .markAccessibility))
    }

    @Test func histogramSingletonPaddingPreservesSmallValueScale() throws {
        let value = 0.001
        let input = table(columns: [measure], rows: [[.double(value)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 10)
        let bin = try #require(
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: specification
            ).first)
        let lower = try #require(bin.lower)
        let upper = try #require(bin.upper)

        #expect(0 < lower)
        #expect(lower < value)
        #expect(value < upper)
        #expect(upper < 0.002)
        #expect(bin.xNumber == value)
    }

    @Test func histogramKeepsSingletonExtremeBoundsFinite() {
        let input = table(
            columns: [measure],
            rows: [[.double(.greatestFiniteMagnitude)]])
        let specification = AutoChartSpecification(
            family: .histogram,
            encoding: AutoChartEncoding(x: measure.id),
            aggregation: .count,
            binCount: 10)
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(data.count == 1)
        #expect(data.first?.sourceRowIDs == [0])
        #expect(data.first?.lower?.isFinite == true)
        #expect(data.first?.upper?.isFinite == true)
        #expect(data.first?.xNumber?.isFinite == true)
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
        #expect(AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
        let data = preparedDatumValues(
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
        #expect(AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
        let data = preparedDatumValues(
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
            !AutoChartRecommendationEngine.validate(
                specification: donutCount, for: categoryInput
            ).isValid)
        #expect(
            !AutoChartRecommendationEngine.validate(
                specification: normalizedBar, for: categoryInput
            ).isValid)
        #expect(
            !AutoChartRecommendationEngine.validate(
                specification: rangeAggregation,
                for: table(
                    columns: [category, date],
                    rows: [[.text("A"), .text("2026-01-01")]])
            ).isValid)
        #expect(
            !AutoChartRecommendationEngine.validate(
                specification: bubbleAggregation,
                for: table(columns: [measure], rows: [[.double(1)]])
            ).isValid)
    }

    @Test func familySafetyRulesApplyToCallerSpecifications() {
        let kpiInput = table(
            columns: [measure], rows: (0..<5).map { [.double(Double($0))] })
        let kpi = AutoChartSpecification(
            family: .kpi, encoding: AutoChartEncoding(y: measure.id))
        #expect(!AutoChartRecommendationEngine.validate(specification: kpi, for: kpiInput).isValid)

        let negativeAreaInput = table(
            columns: [date, measure],
            rows: [
                [.text("2026-01-01"), .double(-1)],
                [.text("2026-01-02"), .double(2)],
            ])
        let area = AutoChartSpecification(
            family: .area, encoding: AutoChartEncoding(x: date.id, y: measure.id))
        #expect(
            !AutoChartRecommendationEngine.validate(
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
            AutoChartRecommendationEngine.validate(
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
            !AutoChartRecommendationEngine.validate(specification: categorical, for: categoricalInput).isValid)

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
        #expect(AutoChartRecommendationEngine.validate(specification: temporal, for: temporalInput).isValid)
    }

    @Test func nullGroupsDoNotMergeWithRealLabels() {
        let input = table(
            columns: [category, measure],
            rows: [[.null, .double(1)], [.text("All"), .double(2)]])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: AutoChartEncoding(x: category.id, y: measure.id))
        #expect(AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
        let data = preparedDatumValues(
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
            !AutoChartRecommendationEngine.validate(
                specification: faceted, for: facetedInput
            ).isValid)
        let facetData = preparedDatumValues(
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
        #expect(!AutoChartRecommendationEngine.validate(specification: duplicate, for: input).isValid)
        #expect(AutoChartRecommendationEngine.validate(specification: separated, for: input).isValid)
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
        #expect(!AutoChartRecommendationEngine.validate(specification: heatmap, for: input).isValid)
        #expect(!AutoChartRecommendationEngine.validate(specification: facetEqualsX, for: input).isValid)
        #expect(!AutoChartRecommendationEngine.validate(specification: facetEqualsSeries, for: input).isValid)

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
        #expect(AutoChartRecommendationEngine.validate(specification: discreteEvent, for: events).isValid)
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
        let legacyValidation = AutoChartRecommendationEngine.validate(specification: legacy, for: input)
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
        #expect(AutoChartRecommendationEngine.validate(specification: line, for: input).isValid)
        #expect(!AutoChartRecommendationEngine.validate(specification: scatter, for: input).isValid)
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
        #expect(!AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
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
        let validation = AutoChartRecommendationEngine.validate(
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
            AutoChartRecommendationEngine.recommendations(for: input).chartRecommendations.first {
                $0.specification.family == .bar
            })
        let validation = AutoChartRecommendationEngine.validate(
            specification: recommendation.specification,
            for: input)
        let prepared = preparedDatumValues(
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
        let positionValidation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: positionsInput)
        let prepared = preparedDatumValues(
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
        let sizeValidation = AutoChartRecommendationEngine.validate(
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
            let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)
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
            AutoChartRecommendationEngine.validate(
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

        let positiveIssue = AutoChartRecommendationEngine.validate(
            specification: AutoChartSpecification(
                family: .donut,
                encoding: .init(x: category.id, y: measure.id),
                aggregation: .sum),
            for: table(
                columns: [category, measure],
                rows: [[.text("A"), .double(1)], [.text("B"), .double(0)]]
            )
        ).issues.first { $0.message == positive }
        #expect(positiveIssue?.messageValue.code == .unsafeAggregation)
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
        let validation = AutoChartRecommendationEngine.validate(specification: heatmap, for: input)

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
        let prepared = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)

        #expect(AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
        #expect(prepared.count == 1)
        #expect(prepared.first?.sourceRowIDs == [2])
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
        #expect(profiles[date.id]?.temporalValueCount == 1)
        #expect(profiles[date.id]?.renderableValueCount == 1)
        #expect(profiles[nominalDate.id]?.renderableValueCount == 1)

        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id))
        let validation = AutoChartRecommendationEngine.validate(
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
        let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)
        let prepared = preparedDatumValues(
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
        let validation = AutoChartRecommendationEngine.validate(specification: specification, for: input)

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
            let validation = AutoChartRecommendationEngine.validate(
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

    @Test func invalidDonutAggregationIsRejectedBeforePreparedDomainValidation() {
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
        let validation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.messageValue.code == .unsafeAggregation
            })
        #expect(validation.issues.contains { $0.messageValue.code == .duplicateMark })
        #expect(!validation.issues.contains { $0.messageValue.code == .nonFiniteValueOmitted })
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
        let validation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)

        #expect(!validation.isValid)
        #expect(
            validation.issues.contains {
                $0.message
                    == "Composition of quantitative field measure produces a non-finite total."
            })
    }

    @Test func eachStackIsTotalledOnItsOwn() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        // Every stack reaches two thirds of the representable range, so each one
        // lands on the axis while the two of them added together would not.
        let thirdExtreme = Double.greatestFiniteMagnitude / 3
        let input = table(
            columns: [category, series, measure],
            rows: [
                [.text("A"), .text("One"), .double(thirdExtreme)],
                [.text("A"), .text("Two"), .double(thirdExtreme)],
                [.text("B"), .text("One"), .double(thirdExtreme)],
                [.text("B"), .text("Two"), .double(thirdExtreme)],
            ])
        let specification = AutoChartSpecification(
            family: .stackedBar,
            encoding: .init(x: category.id, y: measure.id, series: series.id),
            stacking: .standard)
        let validation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)

        #expect(validation.isValid)
        #expect(
            !validation.issues.contains {
                $0.message
                    == "Stacking quantitative field measure produces non-finite totals."
            })
    }

    // Every ordering of the same segments, so that a subtotal cannot depend on
    // the order preparation happened to emit them in.
    private static let segmentOrders: [[Int]] = [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ]

    @Test func stackSubtotalsDoNotDependOnSegmentOrder() {
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        // These three segments total a quarter of an ulp beyond the representable
        // range, which rounds back onto its largest value, so the stack lands on
        // the axis and every ordering has to say so. Adding them in the order they
        // arrive does not: two of them round up to a subtotal whose own last bit
        // then carries the third past the range.
        let extreme = Double.greatestFiniteMagnitude
        let segments = [0.4 * extreme, 0.4 * extreme, 0.2 * extreme]
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

        for order in Self.segmentOrders {
            let input = table(
                columns: [category, series, measure],
                rows: order.map { segment in
                    [.text("A"), .text("Segment \(segment)"), .double(segments[segment])]
                })
            for specification in specifications {
                let validation = AutoChartRecommendationEngine.validate(
                    specification: specification,
                    for: input)

                #expect(validation.isValid, "order \(order) rejected \(specification.family)")
                #expect(
                    !validation.issues.contains {
                        $0.message
                            == "Stacking quantitative field measure produces non-finite totals."
                    })
            }
        }
    }

    @Test func donutCompositionDoesNotDependOnSectorOrder() {
        // The same total as the stacked segments above, in sectors this time.
        let extreme = Double.greatestFiniteMagnitude
        let sectors = [0.4 * extreme, 0.4 * extreme, 0.2 * extreme]
        var verdicts: Set<Bool> = []

        for order in Self.segmentOrders {
            let input = table(
                columns: [category, measure],
                rows: order.map { sector in
                    [.text("Sector \(sector)"), .double(sectors[sector])]
                })
            let specification = AutoChartSpecification(
                family: .donut,
                encoding: .init(x: category.id, y: measure.id),
                aggregation: .sum)
            let validation = AutoChartRecommendationEngine.validate(
                specification: specification,
                for: input)

            verdicts.insert(validation.isValid)
            #expect(
                !validation.issues.contains {
                    $0.message
                        == "Composition of quantitative field measure produces a non-finite total."
                }, "order \(order) reported a non-finite composition")
        }

        #expect(verdicts == [true])
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
        let recommendations = AutoChartRecommendationEngine.recommendations(
            for: input,
            options: .init(maximumRecommendations: 10, includesDecisionTrace: true))

        #expect(!recommendations.chartRecommendations.isEmpty)
        for recommendation in recommendations.chartRecommendations {
            #expect(
                AutoChartRecommendationEngine.validate(
                    specification: recommendation.specification,
                    for: input
                ).isValid)
        }
        #expect(
            !recommendations.chartRecommendations.contains {
                [.stackedBar, .normalizedBar].contains($0.specification.family)
            })
        #expect(
            recommendations.decisions.contains { decision in
                guard decision.family == .stackedBar,
                    case .rejected(let codes) = decision.disposition
                else { return false }
                return codes.contains(.nonFiniteValueOmitted)
            })

        let limitedTrace = AutoChartRecommendationEngine.recommendations(
            for: input,
            options: .init(maximumRecommendations: 1, includesDecisionTrace: true))
        #expect(
            limitedTrace.decisions.contains { decision in
                guard decision.family == .stackedBar,
                    case .pruned(.candidateLimit) = decision.disposition
                else { return false }
                return true
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
        let prepared = preparedDatumValues(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let validation = AutoChartRecommendationEngine.validate(
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
                    && $0.messageValue.code == .chartUnavailable
            })
    }

    #if canImport(Charts) && canImport(SwiftUI)
    @Test func nonFiniteDatesCannotBoundASharedFacetAxis() throws {
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
        let prepared = preparedPresentation(
            for: input,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Non-finite date test"]))
        #expect(prepared.data.count == 1)
        let domain = prepared.presentation.sharedXDateDomain
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

    @Test func extremeQuantitativeFacetSpanIsRejectedAndHasNoDomain() {
        let fixture = extremeNumericFacetFixture()
        let prepared = preparedPresentation(
            for: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite-domain test"]))
        let domain = prepared.presentation.sharedXNumberDomain
        #expect(domain == nil)
        #expect(
            AutoChartRecommendationEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).issues.contains {
                $0.message
                    == "Quantitative field quantitative-x spans a range too large to render safely."
            })
    }

    @Test func oneSidedExtremeQuantitativeFacetDomainRemainsFinite() {
        let fixture = extremeNumericFacetFixture(oneSided: true)
        let prepared = preparedPresentation(
            for: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite unpadded-domain test"]))
        let domain = prepared.presentation.sharedXNumberDomain
        #expect(domain != nil)
        #expect(domain.map { ($0.upperBound - $0.lowerBound).isFinite } == true)
        #expect(
            AutoChartRecommendationEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).isValid)
    }

    @Test func singletonQuantitativeFacetDomainsPreserveSmallValueScale() throws {
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let quantitativeX = AutoChartColumn(
            id: "quantitative-x", name: "quantitative_x",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .dimension))
        let xValue = 0.001
        let yValue = 0.002
        let input = table(
            columns: [facet, quantitativeX, measure],
            rows: [[.text("West"), .double(xValue), .double(yValue)]])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: quantitativeX.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .scatter)
        let prepared = preparedPresentation(
            for: input,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Small singleton-domain test"]))
        let xDomain = try #require(prepared.presentation.sharedXNumberDomain)
        let yDomain = try #require(prepared.presentation.sharedYDomain)

        #expect(0 < xDomain.lowerBound)
        #expect(xDomain.lowerBound < xValue)
        #expect(xValue < xDomain.upperBound)
        #expect(xDomain.upperBound < 0.002)
        #expect(0 < yDomain.lowerBound)
        #expect(yDomain.lowerBound < yValue)
        #expect(yValue < yDomain.upperBound)
        #expect(yDomain.upperBound < 0.004)
    }

    @Test func quantitativeFacetYDomainPadsBySpanInsteadOfMagnitude() throws {
        let facet = AutoChartColumn(
            id: "facet", name: "region",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let quantitativeX = AutoChartColumn(
            id: "quantitative-x", name: "quantitative_x",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .dimension))
        let input = table(
            columns: [facet, quantitativeX, measure],
            rows: [
                [.text("West"), .double(1), .double(1_000)],
                [.text("East"), .double(2), .double(1_000.1)],
            ])
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: quantitativeX.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .scatter)
        let prepared = preparedPresentation(
            for: input,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Tight nonzero Y-domain test"]))
        let domain = try #require(prepared.presentation.sharedYDomain)

        #expect(domain.lowerBound < 1_000)
        #expect(domain.upperBound > 1_000.1)
        #expect(domain.lowerBound > 999.9)
        #expect(domain.upperBound < 1_000.2)
        #expect(domain.upperBound - domain.lowerBound < 0.2)
    }

    @Test func extremeQuantitativeSpanDisablesZoom() {
        let fixture = extremeNumericFacetFixture()
        let scatter = AutoChartSpecification(
            family: .scatter,
            encoding: .init(x: fixture.quantitativeX.id, y: measure.id))
        let prepared = preparedPresentation(
            for: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: scatter,
                score: 0,
                rationale: ["Finite-zoom test"]))
        let zoomCount = prepared.presentation.numberZoomValueCount
        let zoomSpan = prepared.presentation.numberZoomSpan
        #expect(zoomCount == 0)
        #expect(zoomSpan.isFinite)
    }

    @Test func extremeTemporalFacetSpanIsRejectedAndHasNoDomain() {
        let fixture = extremeTemporalFacetFixture()
        let prepared = preparedPresentation(
            for: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: fixture.specification,
                score: 0,
                rationale: ["Finite date-domain test"]))
        let domain = prepared.presentation.sharedXDateDomain
        #expect(domain == nil)
        #expect(
            AutoChartRecommendationEngine.validate(
                specification: fixture.specification,
                for: fixture.input
            ).issues.contains {
                $0.message == "Temporal field date spans a range too large to render safely."
            })
    }

    @Test func extremeTemporalSpanDisablesZoom() {
        let fixture = extremeTemporalFacetFixture()
        let line = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id))
        let prepared = preparedPresentation(
            for: fixture.input,
            recommendation: AutoChartRecommendation(
                specification: line,
                score: 0,
                rationale: ["Finite date-zoom test"]))
        let timeZoomCount = prepared.presentation.timeZoomValueCount
        let timeZoomSpan = prepared.presentation.timeZoomSpan
        #expect(timeZoomCount == 0)
        #expect(timeZoomSpan.isFinite)
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
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: nominalNumber.id, y: measure.id),
                    sort: sort))
        }

        // Value ties keep the canonical identity tie-breaker ascending for both sort
        // directions, so these expectations are intentionally equal.
        let expectedTieOrder = ["row-0-0", "row-2-2", "row-1-1"]
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
            preparedDatumValues(
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

    @Test func renderedValueSortTiesFollowHostCategoryLabels() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(5)],
                [.text("Zoo"), .double(5)],
                [.text("Alpha"), .double(5)],
            ])
        let snapshot = AutoChartSnapshot(input)
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            sort: .ascending)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US"),
            timeZone: .gmt
        ) { request, _, _ in
            guard request.context == .axisTick,
                case .text(let value) = request.value
            else { return nil }
            return ["A": "Zulu", "Zoo": "Beta", "Alpha": "Alpha"][value]
        }
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: formatters)
        let ordered = orderedPresentedData(
            prepared.data,
            specification: specification,
            xLabels: resolved.xDisplayLabels,
            yLabels: resolved.yDisplayLabels,
            missingValue: resolved.missingValue,
            locale: formatters.locale)

        #expect(ordered.compactMap(\.xLabel) == ["Alpha", "Zoo", "A"])
    }

    @Test func presentedMeasureOrderingPlacesNaNAndMissingLastDeterministically() {
        let data = [
            AutoChartDatum(
                id: "zero", sourceRowIDs: [0],
                xIdentity: "zero", xLabel: "Zero", yNumber: 0),
            AutoChartDatum(
                id: "one", sourceRowIDs: [1],
                xIdentity: "one", xLabel: "One", yNumber: 1),
            AutoChartDatum(
                id: "nan", sourceRowIDs: [2],
                xIdentity: "nan", xLabel: "NaN", yNumber: .nan),
            AutoChartDatum(
                id: "missing", sourceRowIDs: [3],
                xIdentity: "missing", xLabel: "Missing", yNumber: nil),
            AutoChartDatum(
                id: "two", sourceRowIDs: [4],
                xIdentity: "two", xLabel: "Two", yNumber: 2),
        ]
        func ordered(_ sort: AutoChartSort) -> [String] {
            orderedPresentedData(
                data,
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: category.id, y: measure.id),
                    sort: sort),
                xLabels: [
                    "zero": "Zero",
                    "one": "One",
                    "nan": "NaN",
                    "missing": "Missing",
                    "two": "Two",
                ],
                yLabels: [:],
                missingValue: "Missing",
                locale: Locale(identifier: "en_US"))
                .map(\.id)
        }

        #expect(ordered(.ascending) == ["zero", "one", "two", "nan", "missing"])
        #expect(ordered(.descending) == ["two", "one", "zero", "nan", "missing"])
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
        let messages = AutoChartRecommendationEngine.validate(
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

        let messages = AutoChartRecommendationEngine.validate(
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

        let messages = AutoChartRecommendationEngine.validate(
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
        let memo = AutoChartRecommendationEngine.AutoChartValidationMemo()
        func profiles(
            _ snapshot: AutoChartSnapshot
        ) -> [AutoChartColumnID: AutoChartColumnProfile] {
            AutoChartProfiler.profileIndex(snapshot)
        }

        let first = AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: firstSnapshot,
            profiles: profiles(firstSnapshot),
            memo: memo)
        let second = AutoChartRecommendationEngine.validate(
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

    @Test func indexedValidationMemoAnswersMatchingSnapshot() {
        let snapshot = AutoChartSnapshot(
            table(
                columns: [category, measure],
                rows: [
                    [.text("A"), .double(1)],
                    [.null, .double(2)],
                ]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        let memo = AutoChartRecommendationEngine.AutoChartValidationMemo(
            snapshot: snapshot,
            categories: profiles.filter(\.isCategorical),
            measures: profiles.filter(\.isQuantitative),
            maximumCategoryCount: 10)

        #expect(
            memo.boundedBoxPlotCategoryCount(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: measure.id) == 2)
        #expect(
            memo.boxPlotIncludesMissing(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: measure.id) == true)
    }

    @Test func indexedValidationMemoRejectsDifferentSnapshot() {
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
                    [.null, .double(2)],
                ]))
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: category.id, y: measure.id))
        let firstProfiles = AutoChartProfiler.profiles(firstSnapshot)
        let memo = AutoChartRecommendationEngine.AutoChartValidationMemo(
            snapshot: firstSnapshot,
            categories: firstProfiles.filter(\.isCategorical),
            measures: firstProfiles.filter(\.isQuantitative),
            maximumCategoryCount: 10)

        let first = AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: firstSnapshot,
            profiles: AutoChartProfiler.profileIndex(firstProfiles),
            memo: memo)
        let second = AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: secondSnapshot,
            profiles: AutoChartProfiler.profileIndex(secondSnapshot),
            memo: memo)

        #expect(
            !first.issues.contains {
                $0.messageValue.code == .boxPlotMissingCategoryGroup
            })
        #expect(
            second.issues.contains {
                $0.severity == .warning
                    && $0.messageValue.code == .boxPlotMissingCategoryGroup
                    && $0.message
                        == "Unrenderable box-plot categories are combined into one missing-value group."
                    && $0.family == .boxPlot
                    && $0.columnIDs == [category.id]
            })
    }

    @Test func indexedValidationMemoBoundsEveryMeasureAndRetainsMissingFlags() {
        let secondMeasure = AutoChartColumn(
            id: "second-measure", name: "second-measure",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [category, measure, secondMeasure],
                rows: [
                    [.text("A"), .double(1), .double(1)],
                    [.text("B"), .double(2), .null],
                    [.text("C"), .double(3), .null],
                    [.text("D"), .double(4), .double(2)],
                    [.text("E"), .double(5), .double(3)],
                    [.null, .null, .double(4)],
                ]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        let memo = AutoChartRecommendationEngine.AutoChartValidationMemo(
            snapshot: snapshot,
            categories: profiles.filter(\.isCategorical),
            measures: profiles.filter(\.isQuantitative),
            maximumCategoryCount: 2)

        #expect(
            memo.boundedBoxPlotCategoryCount(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: measure.id) == 3)
        #expect(
            memo.boundedBoxPlotCategoryCount(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: secondMeasure.id) == 3)
        #expect(
            memo.boxPlotIncludesMissing(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: measure.id) == false)
        #expect(
            memo.boxPlotIncludesMissing(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: secondMeasure.id) == true)
    }

    @Test func indexedValidationMemoHandlesMeasuresAcrossWordBoundaries() {
        let measures = (0..<65).map { index in
            AutoChartColumn(
                id: AutoChartColumnID(rawValue: "measure-\(index)"),
                name: "measure-\(index)",
                hints: AutoChartColumnHints(semanticType: .quantitative))
        }
        let populatedMeasures = Array(
            repeating: AutoChartValue.double(1),
            count: measures.count)
        let lastMeasureOnly =
            Array(repeating: AutoChartValue.null, count: measures.count - 1)
            + [.double(3)]
        let snapshot = AutoChartSnapshot(
            table(
                columns: [category] + measures,
                rows: [
                    [.text("A")] + populatedMeasures,
                    [.text("B")] + populatedMeasures,
                    [.null] + lastMeasureOnly,
                ]))
        let profiles = AutoChartProfiler.profiles(snapshot)
        let memo = AutoChartRecommendationEngine.AutoChartValidationMemo(
            snapshot: snapshot,
            categories: profiles.filter(\.isCategorical),
            measures: profiles.filter(\.isQuantitative),
            maximumCategoryCount: 1)
        let firstMeasure = measures[0]
        let lastMeasure = measures[64]

        #expect(
            memo.boundedBoxPlotCategoryCount(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: firstMeasure.id) == 2)
        #expect(
            memo.boundedBoxPlotCategoryCount(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: lastMeasure.id) == 2)
        #expect(
            memo.boxPlotIncludesMissing(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: firstMeasure.id) == false)
        #expect(
            memo.boxPlotIncludesMissing(
                snapshotIdentity: snapshot.validationIdentity,
                categoryID: category.id,
                measureID: lastMeasure.id) == true)
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
        let prepared = preparedDatumValues(
            snapshot: snapshot,
            specification: specification)

        #expect(Set(prepared.compactMap(\.xIdentity)).count == 1)
        #expect(!AutoChartRecommendationEngine.validate(specification: specification, for: input).isValid)
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
        let compositionIssues = AutoChartRecommendationEngine.validate(
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
            AutoChartRecommendationEngine.validate(
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
            AutoChartRecommendationEngine.validate(
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
                measureSemantics: .init(
                    source: .rowLevel, rollup: .safe(.mean),
                    preferredTransform: .mean)))
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
        #expect(!AutoChartRecommendationEngine.validate(specification: sum, for: input).isValid)
        #expect(AutoChartRecommendationEngine.validate(specification: mean, for: input).isValid)
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

        let typed = preparedDatumValues(
            snapshot: AutoChartSnapshot(
                table(
                    columns: [x, y],
                    rows: [[.integer(1), .text("A")], [.text("1"), .text("A")]])),
            specification: specification)
        #expect(typed.count == 2)
        #expect(Set(typed.compactMap(\.xLabel)) == ["1"])
        #expect(Set(typed.compactMap(\.xIdentity)).count == 2)
        #expect(Set(typed.map(\.id)).count == 2)

        let hyphenated = preparedDatumValues(
            snapshot: AutoChartSnapshot(
                table(
                    columns: [x, y],
                    rows: [[.text("a-b"), .text("c")], [.text("a"), .text("b-c")]])),
            specification: specification)
        #expect(hyphenated.count == 2)
        #expect(Set(hyphenated.map(\.id)).count == 2)
    }

    @Test func typedIdentityDisplayLabelsRemainVisuallyDistinct() {
        let labels = disambiguatedCategoryLabels(
            [
                (identity: "integer:1", label: "1"),
                (identity: "text:1:1", label: "1"),
            ],
            textResolver: .default)
        let integer = disambiguatedCategoryValue(
            identity: "integer:1", label: "1", labels: labels, fallback: "Missing")
        let text = disambiguatedCategoryValue(
            identity: "text:1:1", label: "1", labels: labels, fallback: "Missing")
        #expect(integer == "1 (Integer)")
        #expect(text == "1 (Text)")
        #expect(integer != text)
    }

    @Test func typedIdentityQualifiersAreLocalizable() {
        final class Recorder: @unchecked Sendable {
            var messages: [AutoChartMessage] = []
        }
        let recorder = Recorder()
        let labels = disambiguatedCategoryLabels(
            [
                (identity: "integer:1", label: "1"),
                (identity: "text:1:1", label: "1"),
            ],
            textResolver: AutoChartTextResolver { message in
                recorder.messages.append(message)
                guard case .string(let label) = message.arguments["label"],
                    case .string(let kind) = message.arguments["kind"]
                else { return nil }
                return "\(label) [\(kind)]"
            })

        #expect(labels["integer:1"] == "1 [integer]")
        #expect(labels["text:1:1"] == "1 [text]")
        #expect(recorder.messages.allSatisfy { $0.code == .categoryDisambiguation })
        #expect(recorder.messages.allSatisfy { $0.arguments["index"] == nil })
    }

    @Test func exactAndFallbackNumericIdentitiesHaveMeaningfulQualifiers() {
        let labels = disambiguatedCategoryLabels(
            [
                (identity: "exact-number:3:1e0", label: "1"),
                (identity: "double:4607182418800017408", label: "1"),
            ],
            textResolver: .default)

        #expect(labels["exact-number:3:1e0"] == "1 (Exact Number)")
        #expect(labels["double:4607182418800017408"] == "1 (Double)")
    }

    @Test func disambiguatedLabelsDoNotCollideWithExistingLabels() {
        let labels = disambiguatedCategoryLabels(
            [
                (identity: "integer:1", label: "1"),
                (identity: "text:1:1", label: "1"),
                (identity: "text:11:qualified", label: "1 (Integer)"),
                (identity: "text:13:qualified-2", label: "1 (Integer) 2"),
            ],
            textResolver: .default)
        #expect(labels["text:11:qualified"] == "1 (Integer)")
        #expect(labels["text:13:qualified-2"] == "1 (Integer) 2")
        #expect(Set(labels.values).count == labels.count)
    }

    @Test func localizedDisambiguationCannotClaimAnotherSourceLabelGroup() {
        let labels = disambiguatedCategoryLabels(
            [
                (identity: "integer:1", label: "A"),
                (identity: "text:1:1", label: "A"),
                (identity: "boolean:1", label: "B"),
                (identity: "text:1:B", label: "B"),
            ],
            textResolver: AutoChartTextResolver { message in
                message.arguments["label"] == .string("A") ? "B" : nil
            })

        #expect(!labels.values.contains("A"))
        #expect(!labels.values.contains("B"))
        #expect(Set(labels.values).count == labels.count)
    }

    @Test func nearestAxisSelectionIncludesEverySeriesAtTheNearestPosition() throws {
        let selectedDate = try Date("2026-01-01T00:00:00Z", strategy: .iso8601)
        let matches = [
            AutoChartDatum(
                id: "first", sourceRowIDs: [0], xDate: selectedDate,
                yNumber: 10, series: "First"),
            AutoChartDatum(
                id: "second", sourceRowIDs: [1], xDate: selectedDate,
                yNumber: 20, series: "Second"),
            AutoChartDatum(
                id: "later", sourceRowIDs: [2],
                xDate: selectedDate.addingTimeInterval(86_400),
                yNumber: 30, series: "First"),
        ]
        let nearest = AutoChartSelectionPreparation.nearestDateMatches(
            to: selectedDate.addingTimeInterval(60),
            in: matches)
        #expect(Set(nearest.map(\.id)) == ["first", "second"])
        #expect(AutoChartSelectionPreparation.sourceRowOffsets(for: nearest) == [0, 1])

        // Two marks share the position, so `.none` cannot report one measure
        // value and the rendered summary falls back to the source-row count.
        let specification = AutoChartSpecification(
            family: .line,
            encoding: .init(x: date.id, y: measure.id, series: category.id))
        let semantics = AutoChartSelectionPreparation.semanticValues(
            for: nearest,
            specification: specification,
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        #expect(semantics.measure == nil)
        let presentation = AutoChartSelection(
            sourceRowIDs: Set(["r0", "r1"]),
            dimensions: semantics.dimensions,
            rangeDimensions: semantics.rangeDimensions,
            measure: semantics.measure,
            family: .line,
            specificationID: specification.id,
            markID: nearest.map(\.id).joined(separator: "|"))
            .presentation(columns: [date, measure, category])
        #expect(presentation.valueDescription == "2 source rows")
    }

    @Test func selectionHelpersPreserveBinRangesAndRejectAnglesPastTotal() throws {
        let bins = [
            AutoChartDatum(
                id: "first", sourceRowIDs: [0], xLabel: "0–10",
                xNumber: 5, yNumber: 1, lower: 0, upper: 10),
            AutoChartDatum(
                id: "second", sourceRowIDs: [1], xLabel: "10–20",
                xNumber: 15, yNumber: 2, lower: 10, upper: 20),
        ]
        #expect(AutoChartSelectionPreparation.angleMatch(to: 2, in: bins)?.id == "second")
        #expect(AutoChartSelectionPreparation.angleMatch(to: 4, in: bins) == nil)

        let specification = AutoChartSpecification.histogram(value: measure.id)
        let semantics = AutoChartSelectionPreparation.semanticValues(
            for: [bins[0]],
            specification: specification,
            measureSemantics: renderedAggregationSemantics(.count, columnID: nil))
        #expect(
            semantics.rangeDimensions
                == [
                    AutoChartSelectedRangeDimension(
                        columnID: measure.id,
                        value: .numeric(lower: 0, upper: 10))
                ])
        #expect(
            semantics.measure
                == AutoChartSelectedMeasure(
                    columnID: nil,
                    aggregation: .count,
                    value: .scalar(.double(1))))

        let selection = AutoChartSelection(
            sourceRowIDs: Set(["r0"]),
            dimensions: semantics.dimensions,
            rangeDimensions: semantics.rangeDimensions,
            measure: semantics.measure,
            family: .histogram,
            specificationID: specification.id,
            markID: bins[0].id)
        let presentation = selection.presentation(columns: [measure])
        #expect(presentation.label.contains("0"))
        #expect(presentation.label.contains("10"))
        #expect(presentation.valueDescription.contains("1"))
        #expect(
            try JSONDecoder().decode(
                AutoChartSelection<String>.self,
                from: JSONEncoder().encode(selection)) == selection)

        let sectors = [
            AutoChartDatum(id: "missing-lineage", sourceRowIDs: [], yNumber: 1),
            AutoChartDatum(id: "selectable", sourceRowIDs: [2], yNumber: 2),
        ]
        #expect(AutoChartSelectionPreparation.angleMatch(to: 0.5, in: sectors) == nil)
        #expect(AutoChartSelectionPreparation.angleMatch(to: 2, in: sectors)?.id == "selectable")
        #expect(AutoChartSelectionPreparation.sourceRowOffsets(for: []) == nil)
        #expect(AutoChartSelectionPreparation.sourceRowOffsets(for: [sectors[0]]) == nil)
    }

    @Test func rangeSelectionPreservesSeparateEndpointLineage() throws {
        let startColumn = AutoChartColumn(
            id: "start", name: "Start",
            hints: .init(semanticType: .temporal, role: .intervalStart))
        let endColumn = AutoChartColumn(
            id: "end", name: "End",
            hints: .init(semanticType: .temporal, role: .intervalEnd))
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 86_400)
        let input = table(
            columns: [category, startColumn, endColumn],
            rows: [[.text("A"), .date(start), .date(end)]])
        let snapshot = AutoChartSnapshot(input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let specification = AutoChartSpecification.range(
            label: category.id,
            start: startColumn.id,
            end: endColumn.id)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        var conflictingSpecification = specification
        conflictingSpecification.encoding.start = "conflicting-start"
        conflictingSpecification.encoding.end = "conflicting-end"
        let semantics = AutoChartSelectionPreparation.semanticValues(
            for: prepared.data,
            specification: conflictingSpecification,
            measureSemantics: prepared.measureSemantics)
        let measure = try #require(semantics.measure)

        #expect(measure.rangeStartColumnID == startColumn.id)
        #expect(measure.rangeEndColumnID == endColumn.id)
        #expect(measure.value == .temporalRange(start: start, end: end))

        let selection = AutoChartSelection(
            sourceRowIDs: Set(["r0"]),
            dimensions: semantics.dimensions,
            rangeDimensions: semantics.rangeDimensions,
            measure: measure,
            family: .range,
            specificationID: specification.id,
            markID: "range")
        let formatter = AutoChartFormatters { request, _, _ in
            request.column?.id.rawValue ?? "nil"
        }
        let datum = try #require(prepared.data.first)
        var collapsedDatum = datum
        collapsedDatum.endDate = start
        #expect(
            AutoChartAccessibility.rangeValueDescription(
                for: datum,
                measureSemantics: prepared.measureSemantics,
                profiles: profiles,
                formatters: formatter) == "From start to end")
        #expect(
            AutoChartAccessibility.rangeValueDescription(
                for: collapsedDatum,
                measureSemantics: prepared.measureSemantics,
                profiles: profiles,
                formatters: formatter) == "Date: start")
        let accessibilityResolver = AutoChartTextResolver { message in
            switch message.code {
            case .markAccessibilityRange:
                guard message.arguments["start"] == .string("start"),
                    message.arguments["end"] == .string("end")
                else { return nil }
                return "Localized range"
            case .markAccessibilityDate:
                guard message.arguments["date"] == .string("start") else { return nil }
                return "Localized date"
            default:
                return nil
            }
        }
        #expect(
            AutoChartAccessibility.rangeValueDescription(
                for: datum,
                measureSemantics: prepared.measureSemantics,
                profiles: profiles,
                formatters: formatter,
                textResolver: accessibilityResolver) == "Localized range")
        #expect(
            AutoChartAccessibility.rangeValueDescription(
                for: collapsedDatum,
                measureSemantics: prepared.measureSemantics,
                profiles: profiles,
                formatters: formatter,
                textResolver: accessibilityResolver) == "Localized date")
        #expect(
            selection.presentation(
                columns: [category, startColumn, endColumn],
                formatters: formatter
            ).valueDescription == "start–end")
        #expect(
            try JSONDecoder().decode(
                AutoChartSelection<String>.self,
                from: JSONEncoder().encode(selection)) == selection)
    }

    @Test func selectionSummariesRespectNonadditiveAggregations() {
        let matches = [
            AutoChartDatum(id: "first", sourceRowIDs: [0], yNumber: 10),
            AutoChartDatum(id: "second", sourceRowIDs: [1, 2], yNumber: 20),
        ]
        #expect(
            AutoChartSelectionPreparation.aggregatedNumericValue(
                for: matches,
                aggregation: .mean) == 50.0 / 3.0)
        // A mean weights by source rows and reaches the summary as one value;
        // a distinct count over several marks has no combinable value, so the
        // summary reports rows instead of inventing a number.
        let meanSpecification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .mean)
        let meanSemantics = AutoChartSelectionPreparation.semanticValues(
            for: matches,
            specification: meanSpecification,
            measureSemantics: renderedAggregationSemantics(
                .mean,
                columnID: measure.id))
        #expect(
            meanSemantics.measure
                == AutoChartSelectedMeasure(
                    columnID: measure.id,
                    aggregation: .mean,
                    value: .scalar(.double(50.0 / 3.0))))
        let distinctSpecification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .countDistinct)
        let distinctMeasureSemantics = renderedAggregationSemantics(
            .countDistinct,
            columnID: measure.id)
        let distinctSemantics = AutoChartSelectionPreparation.semanticValues(
            for: matches,
            specification: distinctSpecification,
            measureSemantics: distinctMeasureSemantics)
        #expect(distinctSemantics.measure == nil)
        #expect(
            AutoChartSelection(
                sourceRowIDs: Set(["r0", "r1", "r2"]),
                dimensions: distinctSemantics.dimensions,
                rangeDimensions: distinctSemantics.rangeDimensions,
                measure: distinctSemantics.measure,
                family: .bar,
                specificationID: distinctSpecification.id,
                markID: "first|second"
            ).presentation(columns: [category, measure]).valueDescription
                == "3 source rows")
        #expect(AutoChartSelectionPreparation.identicalValue(in: ["A", "A"]) == "A")
        #expect(AutoChartSelectionPreparation.identicalValue(in: ["A", "B"]) == nil)

        let semantics = AutoChartSelectionPreparation.semanticValues(
            for: [
                AutoChartDatum(
                    id: "distinct", sourceRowIDs: [0, 1], xLabel: "A", yNumber: 2)
            ],
            specification: distinctSpecification,
            measureSemantics: distinctMeasureSemantics)
        #expect(semantics.measure?.columnID == measure.id)
        #expect(semantics.measure?.aggregation == .countDistinct)
        #expect(semantics.measure?.value == .scalar(.double(2)))
        #expect(
            AutoChartSelection(
                sourceRowIDs: Set(["r0", "r1"]),
                measure: semantics.measure,
                family: .bar,
                specificationID: distinctSpecification.id,
                markID: "distinct"
            ).presentation(columns: [category, measure]).valueDescription == "2")
    }

    @Test func distinctCountAxisTitleIsTypedAndLocalizable() {
        let distinctMeasure = AutoChartColumn(
            id: "distinct-measure",
            name: "customer_id",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .measure,
                unit: .currency(code: "USD"),
                measureSemantics: .init(
                    source: .rowLevel,
                    rollup: .safe(.countDistinct))))
        let input = table(
            columns: [category, distinctMeasure],
            rows: [
                [.text("A"), .integer(1)],
                [.text("A"), .integer(2)],
                [.text("B"), .integer(2)],
            ])
        let snapshot = AutoChartSnapshot(input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: distinctMeasure.id),
            aggregation: .countDistinct)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)

        #expect(
            presentation.yTitle
                == "Distinct count of \(AutoChartProfiler.displayName(distinctMeasure))")
        #expect(presentation.yTitleMessage?.category == .interface)
        #expect(presentation.yTitleMessage?.code == .distinctCountTitle)
        #expect(
            presentation.yTitleMessage?.arguments["column"]
                == .string(AutoChartProfiler.displayName(distinctMeasure)))
        #expect(
            presentation.resolvedYTitle(
                using: AutoChartTextResolver { message in
                    message.code == .distinctCountTitle ? "Localized distinct count" : nil
                }) == "Localized distinct count")
    }

    @Test func generatedChartTitlesAreTypedAndLocalizable() {
        final class Recorder: @unchecked Sendable {
            var codes: [AutoChartMessage.Code] = []
        }
        let emptySnapshot = AutoChartSnapshot(
            table(columns: [], rows: []))
        let fallbackSpecification = AutoChartSpecification(
            family: .bar,
            encoding: .init())
        let fallbackPresentation = AutoChartRenderPresentation(
            snapshot: emptySnapshot,
            specification: fallbackSpecification,
            profiles: [:],
            data: [],
            measureSemantics: renderedValueSemantics(columnID: nil))

        #expect(fallbackPresentation.xTitleMessage?.code == .categoryTitle)
        #expect(fallbackPresentation.yTitleMessage?.code == .valueTitle)
        #expect(fallbackPresentation.seriesTitleMessage?.code == .seriesTitle)
        #expect(fallbackPresentation.facetTitleMessage?.code == .facetTitle)
        #expect(AutoChartRenderPresentation.countTitleMessage.code == .countTitle)
        #expect(AutoChartRenderPresentation.medianTitleMessage.code == .medianTitle)

        let recorder = Recorder()
        let resolved = fallbackPresentation.resolvedPresentation(
            data: [],
            using: AutoChartTextResolver { message in
                recorder.codes.append(message.code)
                return "localized:\(message.code.rawValue)"
            })
        #expect(resolved.x == "localized:categoryTitle")
        #expect(resolved.y == "localized:valueTitle")
        #expect(resolved.series == "Series")
        #expect(resolved.facet == "Facet")
        #expect(resolved.count == "Count")
        #expect(resolved.median == "Median")
        #expect(recorder.codes == [.categoryTitle, .valueTitle])

        let countInput = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)]])
        let countSnapshot = AutoChartSnapshot(countInput)
        let countSpecification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .count)
        var countPresentation = AutoChartRenderPresentation(
            snapshot: countSnapshot,
            specification: countSpecification,
            profiles: AutoChartProfiler.profileIndex(countSnapshot),
            data: [],
            measureSemantics: renderedAggregationSemantics(.count, columnID: nil))
        countPresentation.yTitle = "Row count"
        countPresentation.yTitleMessage = AutoChartMessage(
            category: .interface,
            code: .countTitle,
            arguments: ["scope": .string("rows")],
            defaultText: "Row count")
        let resolvedCount = countPresentation.resolvedPresentation(
            data: [],
            using: AutoChartTextResolver { message in
                guard message.arguments["scope"] == .string("rows"),
                    message.defaultText == "Row count"
                else { return nil }
                return "Localized row count"
            })
        #expect(resolvedCount.y == "Localized row count")
    }

    @Test func generatedRangeAndMissingLabelsAreTypedAndLocalizable() {
        let resolver = AutoChartTextResolver { "localized:\($0.code.rawValue)" }
        let emptySnapshot = AutoChartSnapshot(table(columns: [], rows: []))
        let rangeSpecification = AutoChartSpecification(
            family: .range,
            encoding: .init(x: "category", start: "start", end: "end"))
        let rangePresentation = AutoChartRenderPresentation(
            snapshot: emptySnapshot,
            specification: rangeSpecification,
            profiles: [:],
            data: [],
            measureSemantics: renderedValueSemantics(
                columnID: nil,
                rangeStartColumnID: "start",
                rangeEndColumnID: "end"))
        let resolvedRange = rangePresentation.resolvedPresentation(
            data: [],
            using: resolver)
        #expect(resolvedRange.rangeStart == "localized:rangeStartTitle")
        #expect(resolvedRange.rangeEnd == "localized:rangeEndTitle")
        #expect(resolvedRange.date == "localized:dateTitle")

        let boxData = [
            AutoChartDatum(
                id: "all", sourceRowIDs: [], xIdentity: "all", xLabel: "All"),
            AutoChartDatum(
                id: "missing", sourceRowIDs: [], xSourceValue: .null,
                xLabel: "Missing value"),
        ]
        let boxSpecification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: category.id, y: measure.id))
        let boxSnapshot = AutoChartSnapshot(
            table(columns: [category, measure], rows: []))
        let boxPresentation = AutoChartRenderPresentation(
            snapshot: boxSnapshot,
            specification: boxSpecification,
            profiles: AutoChartProfiler.profileIndex(boxSnapshot),
            data: boxData,
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        let resolvedBox = boxPresentation.resolvedPresentation(
            data: boxData,
            using: resolver)
        #expect(
            disambiguatedCategoryValue(
                identity: boxData[1].xIdentity,
                label: boxData[1].xLabel,
                labels: resolvedBox.xDisplayLabels,
                fallback: resolvedBox.missingValue)
                == "localized:missingValueLabel")

        let ungroupedBoxSpecification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(y: measure.id))
        let ungroupedBoxPresentation = AutoChartRenderPresentation(
            snapshot: boxSnapshot,
            specification: ungroupedBoxSpecification,
            profiles: AutoChartProfiler.profileIndex(boxSnapshot),
            data: [boxData[0]],
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        let resolvedUngroupedBox = ungroupedBoxPresentation.resolvedPresentation(
            data: [boxData[0]],
            using: resolver)
        #expect(resolvedUngroupedBox.xDisplayLabels["all"] == "localized:allValuesLabel")

        let series = AutoChartColumn(
            id: "series", name: "Series",
            hints: .init(semanticType: .nominal, role: .dimension))
        let facet = AutoChartColumn(
            id: "facet", name: "Facet",
            hints: .init(semanticType: .nominal, role: .dimension))
        let facetedSpecification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(
                x: category.id,
                y: measure.id,
                series: series.id,
                facet: facet.id))
        let facetedSnapshot = AutoChartSnapshot(
            table(columns: [category, measure, series, facet], rows: []))
        let missingDimensionData = [
            AutoChartDatum(
                id: "missing-dimensions",
                sourceRowIDs: [],
                xIdentity: "text:1:A",
                xLabel: "A",
                yNumber: 1)
        ]
        let facetedPresentation = AutoChartRenderPresentation(
            snapshot: facetedSnapshot,
            specification: facetedSpecification,
            profiles: AutoChartProfiler.profileIndex(facetedSnapshot),
            data: missingDimensionData,
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        let resolvedFaceted = facetedPresentation.resolvedPresentation(
            data: missingDimensionData,
            using: resolver)
        #expect(resolvedFaceted.missingSeries == "localized:missingSeriesLabel")
        #expect(resolvedFaceted.missingFacet == "localized:missingFacetLabel")
    }

    @Test func localizedFacetedDomainsAndPanelOrderUseResolvedCategoryValues() {
        let facet = AutoChartColumn(
            id: "facet", name: "Facet",
            hints: .init(semanticType: .nominal, role: .dimension))
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: category.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .bar,
            sort: .ascending)
        let snapshot = AutoChartSnapshot(
            table(columns: [category, measure, facet], rows: []))
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let data = [
            AutoChartDatum(
                id: "integer", sourceRowIDs: [],
                xIdentity: "integer:1", xLabel: "1", yNumber: 1,
                facetIdentity: "integer:1", facet: "1"),
            AutoChartDatum(
                id: "text", sourceRowIDs: [],
                xIdentity: "text:1:1", xLabel: "1", yNumber: 1,
                facetIdentity: "text:1:1", facet: "1"),
        ]
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: data,
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        let resolved = presentation.resolvedPresentation(
            data: data,
            using: AutoChartTextResolver { message in
                guard message.code == .categoryDisambiguation,
                    case .string(let kind) = message.arguments["kind"]
                else { return nil }
                return kind == "integer" ? "Zulu" : "Alpha"
            })
        let presented = orderedPresentedData(
            data,
            specification: specification,
            xLabels: resolved.xDisplayLabels,
            yLabels: resolved.yDisplayLabels,
            missingValue: resolved.missingValue,
            locale: Locale(identifier: "en_US"))

        #expect(
            resolvedXCategoryDomain(
                in: presented,
                labels: resolved.xDisplayLabels,
                fallback: resolved.missingValue)
                == ["Alpha", "Zulu"])
        #expect(
            orderedFacetPanels(
                in: data,
                labels: resolved.facetDisplayLabels,
                fallback: resolved.missingFacet,
                locale: Locale(identifier: "en_US"))
                .map(\.key)
                == ["text:1:1", "integer:1"])
    }

    @Test func facetPanelOrderingUsesLocaleAwareCollation() {
        let data = [
            AutoChartDatum(
                id: "z", sourceRowIDs: [0], yNumber: 1,
                facetIdentity: "text:1:z", facet: "z"),
            AutoChartDatum(
                id: "umlaut", sourceRowIDs: [1], yNumber: 2,
                facetIdentity: "text:2:ä", facet: "ä"),
        ]
        let panels = orderedFacetPanels(
            in: data,
            labels: ["text:1:z": "z", "text:2:ä": "ä"],
            fallback: "Missing",
            locale: Locale(identifier: "de_DE"))

        #expect(panels.map(\.key) == ["text:2:ä", "text:1:z"])
    }

    @Test func preparedNilDimensionIdentitiesUseLocalizedMissingLabelsAcrossSurfaces() throws {
        let series = AutoChartColumn(
            id: "series", name: "Series",
            hints: .init(semanticType: .nominal, role: .dimension))
        let facet = AutoChartColumn(
            id: "facet", name: "Facet",
            hints: .init(semanticType: .nominal, role: .dimension))
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(
                x: category.id,
                y: measure.id,
                series: series.id,
                facet: facet.id),
            facetBaseFamily: .bar)
        let invalidDate = Date(timeIntervalSinceReferenceDate: .nan)
        let snapshot = AutoChartSnapshot(
            table(
                columns: [category, measure, series, facet],
                rows: [
                    [.text("A"), .double(1), .date(invalidDate), .date(invalidDate)],
                    [
                        .text("B"), .double(2), .text("Localized missing series"),
                        .text("Localized missing facet"),
                    ],
                ]))
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let data = prepared.data
        let missing = try #require(data.first { $0.facetIdentity == nil })
        #expect(missing.seriesIdentity == nil)
        #expect(missing.series == nil)
        #expect(missing.facet == nil)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: data,
            measureSemantics: prepared.measureSemantics)
        let resolved = presentation.resolvedPresentation(
            data: data,
            using: AutoChartTextResolver { message in
                switch message.code {
                case .missingSeriesLabel: "Localized missing series"
                case .missingFacetLabel: "Localized missing facet"
                default: nil
                }
            })

        let panels = orderedFacetPanels(
            in: data,
            labels: resolved.facetDisplayLabels,
            fallback: resolved.missingFacet,
            locale: Locale(identifier: "en_US"))

        #expect(resolved.missingSeries == "Localized missing series")
        #expect(resolved.missingFacet == "Localized missing facet")
        #expect(panels.count == 2)
        #expect(Set(panels.map(\.displayValue)).count == 2)
        #expect(panels.first { $0.key == nil }?.displayValue == "Localized missing facet")
        #expect(resolved.seriesDisplayLabels.count == 1)
        #expect(
            resolved.seriesDisplayLabels.values.allSatisfy {
                $0 != "Localized missing series"
            })
        #expect(
            disambiguatedCategoryValue(
                identity: missing.seriesIdentity,
                label: missing.series,
                labels: resolved.seriesDisplayLabels,
                fallback: resolved.missingSeries)
                == "Localized missing series")
        #expect(
            disambiguatedCategoryValue(
                identity: missing.facetIdentity,
                label: missing.facet,
                labels: resolved.facetDisplayLabels,
                fallback: resolved.missingFacet)
                == "Localized missing facet")
    }

    @Test func missingFacetDefaultTextRemainsFacetSpecific() {
        let facet = AutoChartColumn(
            id: "facet", name: "Facet",
            hints: .init(semanticType: .nominal, role: .dimension))
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: category.id, y: measure.id, facet: facet.id),
            facetBaseFamily: .bar)
        let snapshot = AutoChartSnapshot(
            table(columns: [category, measure, facet], rows: []))
        let data = [
            AutoChartDatum(
                id: "missing-facet", sourceRowIDs: [],
                xIdentity: "text:1:A", xLabel: "A", yNumber: 1)
        ]
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: AutoChartProfiler.profileIndex(snapshot),
            data: data,
            measureSemantics: renderedValueSemantics(columnID: measure.id))
        let resolved = presentation.resolvedPresentation(
            data: data,
            using: .default)

        #expect(resolved.missingFacet == "Missing facet")
    }

    @Test func preparationDerivesValueAndAggregationLineage() {
        let input = table(
            columns: [category, measure],
            rows: [[.text("A"), .double(1)], [.text("A"), .double(2)]])
        let snapshot = AutoChartSnapshot(input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        func semantics(
            for aggregation: AutoChartAggregation
        ) -> AutoChartRenderedMeasureSemantics {
            AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: category.id, y: measure.id),
                    aggregation: aggregation),
                profiles: profiles
            ).measureSemantics
        }

        #expect(semantics(for: .none).kind == .value)
        #expect(semantics(for: .none).columnID == measure.id)
        #expect(semantics(for: .mean).kind == .aggregated(.mean))
        #expect(semantics(for: .mean).columnID == measure.id)
        #expect(semantics(for: .countDistinct).kind == .aggregated(.countDistinct))
        #expect(semantics(for: .countDistinct).columnID == measure.id)
        #expect(semantics(for: .count).kind == .aggregated(.count))
        #expect(semantics(for: .count).columnID == nil)
    }

    @Test func emptyMeasureGroupsDoNotFabricateStatisticalZeros() {
        let input = table(columns: [category], rows: [[.text("A")], [.text("B")]])
        let snapshot = AutoChartSnapshot(input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)

        for aggregation in [
            AutoChartAggregation.mean,
            .minimum,
            .maximum,
        ] {
            let prepared = AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: AutoChartSpecification(
                    family: .bar,
                    encoding: .init(x: category.id),
                    aggregation: aggregation),
                profiles: profiles)
            #expect(prepared.data.isEmpty)
        }
    }

    @Test func preparedSemanticsDrivePresentationAndSelectionAcrossFamilies() throws {
        let heatmapY = AutoChartColumn(
            id: "heatmap-y", name: "Region",
            hints: .init(semanticType: .nominal, role: .dimension))
        let heatmapInput = table(
            columns: [category, heatmapY],
            rows: [[.text("A"), .text("West")]])
        let heatmapSnapshot = AutoChartSnapshot(heatmapInput)
        let heatmapProfiles = AutoChartProfiler.profileIndex(heatmapSnapshot)
        let heatmap = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: category.id, y: heatmapY.id),
            aggregation: .count)
        let heatmapPrepared = AutoChartDataPreparation.preparedData(
            snapshot: heatmapSnapshot,
            specification: heatmap,
            profiles: heatmapProfiles)
        let heatmapPresentation = AutoChartRenderPresentation(
            snapshot: heatmapSnapshot,
            specification: heatmap,
            profiles: heatmapProfiles,
            data: heatmapPrepared.data,
            measureSemantics: heatmapPrepared.measureSemantics)
        let heatmapSelection = AutoChartSelectionPreparation.semanticValues(
            for: heatmapPrepared.data,
            specification: heatmap,
            measureSemantics: heatmapPrepared.measureSemantics)

        #expect(heatmapPresentation.yTitle == AutoChartProfiler.displayName(heatmapY))
        #expect(heatmapPrepared.measureSemantics.kind == .aggregated(.count))
        #expect(heatmapSelection.measure?.aggregation == .count)
        #expect(heatmapSelection.measure?.columnID == nil)

        let boxInput = table(
            columns: [category, measure],
            rows: (1...5).map { [.text("A"), .double(Double($0))] })
        let boxSnapshot = AutoChartSnapshot(boxInput)
        let boxProfiles = AutoChartProfiler.profileIndex(boxSnapshot)
        let boxPlot = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: category.id, y: measure.id))
        let boxPrepared = AutoChartDataPreparation.preparedData(
            snapshot: boxSnapshot,
            specification: boxPlot,
            profiles: boxProfiles)
        let boxSelection = AutoChartSelectionPreparation.semanticValues(
            for: boxPrepared.data,
            specification: boxPlot,
            measureSemantics: boxPrepared.measureSemantics)

        #expect(boxPrepared.data.count == 1)
        #expect(boxPrepared.measureSemantics.kind == .value)
        #expect(boxSelection.measure?.aggregation == AutoChartAggregation.none)
        #expect(boxSelection.measure?.columnID == measure.id)
        #expect(
            boxSelection.measure?.value
                == .distribution(
                    lower: 1, quartile1: 2, median: 3, quartile3: 4, upper: 5))

        let donutInput = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.text("A"), .double(2)],
                [.text("B"), .double(4)],
            ])
        let donutSnapshot = AutoChartSnapshot(donutInput)
        let donut = AutoChartSpecification(
            family: .donut,
            encoding: .init(x: category.id, y: measure.id),
            aggregation: .sum)
        let donutPrepared = AutoChartDataPreparation.preparedData(
            snapshot: donutSnapshot,
            specification: donut,
            profiles: AutoChartProfiler.profileIndex(donutSnapshot))
        let donutA = try #require(
            donutPrepared.data.first { $0.xLabel == "A" })
        let donutSelection = AutoChartSelectionPreparation.semanticValues(
            for: [donutA],
            specification: donut,
            measureSemantics: donutPrepared.measureSemantics)

        #expect(donutA.yNumber == 3)
        #expect(donutPrepared.measureSemantics.kind == .aggregated(.sum))
        #expect(donutSelection.measure?.aggregation == .sum)
        #expect(donutSelection.measure?.value == .scalar(.double(3)))

        let kpiInput = table(columns: [measure], rows: [[.double(42)]])
        let kpiSnapshot = AutoChartSnapshot(kpiInput)
        let kpi = AutoChartSpecification(
            family: .kpi,
            encoding: .init(y: measure.id))
        let kpiPrepared = AutoChartDataPreparation.preparedData(
            snapshot: kpiSnapshot,
            specification: kpi,
            profiles: AutoChartProfiler.profileIndex(kpiSnapshot))

        #expect(kpiPrepared.data.first?.yNumber == 42)
        #expect(kpiPrepared.measureSemantics.kind == .value)
        #expect(kpiPrepared.measureSemantics.columnID == measure.id)
    }

    @Test func heatmapMergedIdentitiesDoNotExposeTheFirstStoredSourceValue() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let secondary = AutoChartColumn(
            id: "secondary", name: "secondary",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let specification = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(x: ordinal.id, y: secondary.id),
            aggregation: .count)
        func datum(_ xValues: [AutoChartValue]) throws -> AutoChartDatum {
            let snapshot = AutoChartSnapshot(
                table(
                    columns: [ordinal, secondary],
                    rows: xValues.map { [$0, .text("A")] }))
            let data = preparedDatumValues(
                snapshot: snapshot,
                specification: specification)
            #expect(data.count == 1)
            return try #require(data.first)
        }

        let forward = try datum([.integer(1_000), .double(1_000)])
        let reversed = try datum([.double(1_000), .integer(1_000)])
        let selection = AutoChartSelectionPreparation.semanticValues(
            for: [forward],
            specification: specification,
            measureSemantics: renderedAggregationSemantics(.count, columnID: nil))

        #expect(forward.sourceRowIDs == [0, 1])
        #expect(forward.xIdentity == reversed.xIdentity)
        #expect(forward.xSourceValue == nil)
        #expect(reversed.xSourceValue == nil)
        #expect(forward.ySourceValue == .text("A"))
        #expect(
            selection.dimensions
                == [.init(columnID: secondary.id, value: .text("A"))])
    }

    @Test func groupedMergedDimensionsUseConsensusSourcesAndStableMissingLabels() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(
                x: ordinal.id,
                y: measure.id,
                series: series.id,
                facet: facet.id),
            aggregation: .sum,
            facetBaseFamily: .bar)
        func datum(_ rows: [[AutoChartValue]]) throws -> AutoChartDatum {
            let snapshot = AutoChartSnapshot(
                table(
                    columns: [ordinal, measure, series, facet],
                    rows: rows))
            let data = preparedDatumValues(
                snapshot: snapshot,
                specification: specification)
            #expect(data.count == 1)
            return try #require(data.first)
        }

        let firstRow: [AutoChartValue] = [
            .integer(1_000), .double(1), .null, .integer(2_000),
        ]
        let secondRow: [AutoChartValue] = [
            .double(1_000), .double(3), .double(.nan), .double(2_000),
        ]
        let forward = try datum([firstRow, secondRow])
        let reversed = try datum([secondRow, firstRow])
        let selection = AutoChartSelectionPreparation.semanticValues(
            for: [forward],
            specification: specification,
            measureSemantics: renderedAggregationSemantics(.sum, columnID: measure.id))

        #expect(forward.sourceRowIDs == [0, 1])
        #expect(forward.xSourceValue == nil)
        #expect(forward.seriesSourceValue == nil)
        #expect(forward.facetSourceValue == nil)
        #expect(forward.series == nil)
        #expect(reversed.series == nil)
        #expect(forward.xLabel == reversed.xLabel)
        #expect(forward.facet == reversed.facet)
        #expect(selection.dimensions.isEmpty)
        #expect(forward.yNumber == 4)
    }

    @Test func selectionDimensionsPreserveTypedSourceValuesInsteadOfLabels() {
        let heatmapY = AutoChartColumnID(rawValue: "heatmap-y")
        let series = AutoChartColumnID(rawValue: "series")
        let facet = AutoChartColumnID(rawValue: "facet")
        let specification = AutoChartSpecification(
            family: .heatmap,
            encoding: .init(
                x: category.id,
                y: heatmapY,
                series: series,
                facet: facet),
            aggregation: .count)
        let typed = AutoChartDatum(
            id: "typed",
            sourceRowIDs: [0],
            xIdentity: "integer:1",
            xSourceValue: .integer(1),
            xLabel: "1",
            yIdentity: "boolean:true",
            ySourceValue: .boolean(true),
            yLabel: "true",
            seriesIdentity: "integer:2",
            seriesSourceValue: .integer(2),
            series: "2",
            facetIdentity: "boolean:false",
            facetSourceValue: .boolean(false),
            facet: "false")
        let semantics = AutoChartSelectionPreparation.semanticValues(
            for: [typed],
            specification: specification,
            measureSemantics: renderedAggregationSemantics(.count, columnID: nil))
        #expect(
            semantics.dimensions
                == [
                    .init(columnID: category.id, value: .integer(1)),
                    .init(columnID: heatmapY, value: .boolean(true)),
                    .init(columnID: series, value: .integer(2)),
                    .init(columnID: facet, value: .boolean(false)),
                ])

        let duplicateLabelsWithDifferentValues = AutoChartDatum(
            id: "different-values",
            sourceRowIDs: [1],
            xIdentity: "text:1:1",
            xSourceValue: .text("1"),
            xLabel: "1",
            yIdentity: "text:4:true",
            ySourceValue: .text("true"),
            yLabel: "true",
            seriesIdentity: "text:1:2",
            seriesSourceValue: .text("2"),
            series: "2",
            facetIdentity: "text:5:false",
            facetSourceValue: .text("false"),
            facet: "false")
        let mixed = AutoChartSelectionPreparation.semanticValues(
            for: [typed, duplicateLabelsWithDifferentValues],
            specification: specification,
            measureSemantics: renderedAggregationSemantics(.count, columnID: nil))
        #expect(mixed.dimensions.isEmpty)
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
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: specification)
        #expect(data.compactMap(\.xLabel) == ["1", "1"])
        #expect(data.compactMap(\.xIdentity) == ["integer:1", "text:1:1"])
    }

    @Test func boxPlotMergesEquivalentNumericRepresentationsByIdentity() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let input = table(
            columns: [ordinal, measure],
            rows: [[.integer(1_000), .double(1)], [.double(1_000), .double(3)]])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: ordinal.id, y: measure.id))
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: AutoChartProfiler.profileIndex(snapshot))
        let datum = try #require(prepared.data.first)
        let reversedSnapshot = AutoChartSnapshot(
            table(
                columns: [ordinal, measure],
                rows: [[.double(1_000), .double(3)], [.integer(1_000), .double(1)]]))
        let reversed = AutoChartDataPreparation.preparedData(
            snapshot: reversedSnapshot,
            specification: specification,
            profiles: AutoChartProfiler.profileIndex(reversedSnapshot))
        let selection = AutoChartSelectionPreparation.semanticValues(
            for: [datum],
            specification: specification,
            measureSemantics: prepared.measureSemantics)

        #expect(prepared.data.count == 1)
        #expect(datum.sourceRowIDs == [0, 1])
        #expect(datum.xIdentity == "exact-number:3:1e3")
        #expect(datum.xSourceValue == nil)
        #expect(datum.xLabel == "1000")
        #expect(reversed.data.first?.xLabel == datum.xLabel)
        #expect(selection.dimensions.isEmpty)
        #expect(datum.median == 2)
    }

    @Test func boxPlotPreservesNearbyNumericCategoryLabelPrecision() {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let sourceValues: [AutoChartValue] = [
            .double(1_000.0624),
            .double(1_000.0625),
        ]
        let input = table(
            columns: [ordinal, measure],
            rows: [
                [sourceValues[0], .double(1)],
                [sourceValues[1], .double(3)],
            ])
        let snapshot = AutoChartSnapshot(input)
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: ordinal.id, y: measure.id))
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: posixCategoryFormatters)
        let germanFormatters = AutoChartFormatters(
            locale: Locale(identifier: "de_DE"),
            timeZone: .gmt)
        let germanResolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: germanFormatters)
        let overridden = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: AutoChartFormatters { request, _, _ in
                guard request.column?.id == ordinal.id,
                    request.context == .axisTick
                else { return nil }
                return "category:\(request.value.categoryString() ?? "missing")"
            })

        let labelPairs: [(sourceValue: AutoChartValue, label: String)] =
            prepared.data.compactMap { datum in
                guard let sourceValue = datum.xSourceValue,
                    let label = datum.xLabel
                else { return nil }
                return (sourceValue: sourceValue, label: label)
            }

        #expect(prepared.data.count == 2)
        #expect(labelPairs.count == sourceValues.count)
        let expectedLabels = [
            sourceValues[0]: "1000.0624",
            sourceValues[1]: "1000.0625",
        ]
        #expect(
            Dictionary(uniqueKeysWithValues: labelPairs.map { ($0.sourceValue, $0.label) })
                == expectedLabels)
        #expect(Set(labelPairs.map(\.label)).count == sourceValues.count)
        let displayLabelsBySourceValue: [AutoChartValue: String] = Dictionary(
            uniqueKeysWithValues: prepared.data.compactMap { datum in
                guard let sourceValue = datum.xSourceValue,
                    let identity = datum.xIdentity,
                    let label = resolved.xDisplayLabels[identity]
                else { return nil }
                return (sourceValue, label)
            })
        #expect(
            displayLabelsBySourceValue
                == expectedLabels)
        #expect(
            Set(germanResolved.xDisplayLabels.values)
                == Set(sourceValues.compactMap {
                    $0.categoryString(locale: germanFormatters.locale)
                }))
        #expect(germanResolved.xDisplayLabels.values.allSatisfy { $0.contains(",") })
        #expect(overridden.xDisplayLabels.values.allSatisfy { $0.hasPrefix("category:") })
    }

    @Test func categoryPresentationUsesSurfaceContextsForHostOverrides() {
        final class Recorder: @unchecked Sendable {
            var requests: [AutoChartFormattingRequest] = []
        }
        let x = AutoChartColumn(
            id: "x", name: "x",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let series = AutoChartColumn(
            id: "series", name: "series",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let midnight = Date(timeIntervalSinceReferenceDate: 0)
        let withSeconds = midnight.addingTimeInterval(30 * 60 + 1)
        let snapshot = AutoChartSnapshot(
            table(
                columns: [x, measure, series, facet],
                rows: [
                    [.text("A"), .double(1), .text("S"), .date(midnight)],
                    [.text("A"), .double(2), .text("S"), .date(midnight)],
                    [.text("B"), .double(3), .text("T"), .date(withSeconds)],
                ]))
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(
                x: x.id,
                y: measure.id,
                series: series.id,
                facet: facet.id),
            facetBaseFamily: .bar)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let recorder = Recorder()
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: .gmt
        ) { request, _, _ in
            recorder.requests.append(request)
            return "custom:\(request.column?.id.rawValue ?? "none")"
        }
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: formatters)

        let xRequests = recorder.requests.filter { $0.column?.id == x.id }
        let seriesRequests = recorder.requests.filter { $0.column?.id == series.id }
        let facetRequests = recorder.requests.filter { $0.column?.id == facet.id }
        #expect(xRequests.count == 2)
        #expect(xRequests.allSatisfy { $0.context == .axisTick })
        #expect(seriesRequests.count == 2)
        #expect(seriesRequests.allSatisfy { $0.context == .legend })
        #expect(facetRequests.count == 2)
        #expect(facetRequests.allSatisfy { $0.context == .facetHeader })
        #expect(resolved.facetDisplayLabels.count == 2)
        #expect(
            resolved.facetDisplayLabels.values.allSatisfy {
                $0.hasPrefix("custom:facet")
            })
    }

    @Test func accessibilityCategoryFormattingCanOverrideResolvedSurfaceLabels() {
        let column = AutoChartColumn(
            id: "region",
            name: "Region",
            hints: .init(semanticType: .nominal, role: .dimension))
        let formatters = AutoChartFormatters { request, _, _ in
            guard request.context == .markAccessibility else { return nil }
            return "spoken:\(request.value.displayString)"
        }

        #expect(
            categoryValueForSurface(
                identity: "text:5:North",
                value: .text("North"),
                label: "North",
                labels: ["text:5:North": "N"],
                fallback: "Missing region",
                column: column,
                context: .markAccessibility,
                formatters: formatters) == "spoken:North")
        #expect(
            categoryValueForSurface(
                identity: "text:5:North",
                value: .text("North"),
                label: "North",
                labels: ["text:5:North": "N"],
                fallback: "Missing region",
                column: column,
                context: .selectionSummary,
                formatters: formatters) == "N")
    }

    @Test func categorySelectionSummaryReusesResolvedDatePrecision() throws {
        let dateCategory = AutoChartColumn(
            id: "date-category",
            name: "Date category",
            hints: .init(semanticType: .nominal, role: .dimension))
        let midnight = Date(timeIntervalSinceReferenceDate: 0)
        let withSeconds = midnight.addingTimeInterval(30 * 60 + 1)
        let snapshot = AutoChartSnapshot(
            table(
                columns: [dateCategory, measure],
                rows: [
                    [.date(midnight), .double(1)],
                    [.date(withSeconds), .double(2)],
                ]))
        let specification = AutoChartSpecification.bar(
            category: dateCategory.id,
            measure: measure.id)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: prepared.data,
            measureSemantics: prepared.measureSemantics)
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: .gmt)
        let resolved = presentation.resolvedPresentation(
            data: prepared.data,
            using: .default,
            formatters: formatters)
        let categoryIdentity = AutoChartProfiler.identity(
            .date(midnight),
            semanticType: profiles[dateCategory.id]?.semanticType)
        let identity = try #require(categoryIdentity.stringValue)
        let categoryLabel = try #require(resolved.xDisplayLabels[identity])
        let selection = AutoChartSelection<Int>(
            sourceRowIDs: [0],
            dimensions: [.init(columnID: dateCategory.id, value: .date(midnight))],
            family: .bar,
            specificationID: specification.id,
            markID: "midnight")
        let summary = selection.presentation(
            columns: snapshot.columns,
            formatters: formatters,
            textResolver: .default,
            resolvedDimensionLabel: { _ in categoryLabel })
        let overriddenSummary = selection.presentation(
            columns: snapshot.columns,
            formatters: AutoChartFormatters { request, _, _ in
                request.context == .selectionSummary ? "selection override" : nil
            },
            textResolver: .default,
            resolvedDimensionLabel: { _ in categoryLabel })

        #expect(categoryLabel.contains(":"))
        #expect(summary.label == categoryLabel)
        #expect(overriddenSummary.label == "selection override")
    }

    @Test func boxPlotBoundsExtremeNumericCategoryLabels() {
        let nominal = AutoChartColumn(
            id: "nominal", name: "nominal",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [nominal, measure],
            rows: [
                [.double(.greatestFiniteMagnitude), .double(1)],
                [.double(.leastNonzeroMagnitude), .double(2)],
            ])
        let data = preparedDatumValues(
            snapshot: AutoChartSnapshot(input),
            specification: AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: nominal.id, y: measure.id)))

        let expectedLabels: Set<String> = ["1.7976931348623157E308", "5E-324"]
        #expect(Set(data.compactMap(\.xLabel)) == expectedLabels)
        #expect(data.compactMap(\.xLabel).allSatisfy { $0.count <= 24 })
    }

    @Test func boxPlotDerivesMergedTemporalLabelWithoutExposingIdentity() throws {
        let temporal = AutoChartColumn(
            id: "temporal", name: "temporal",
            hints: AutoChartColumnHints(semanticType: .temporal))
        let input = table(
            columns: [temporal, measure],
            rows: [
                [.date(Date(timeIntervalSinceReferenceDate: 0)), .double(1)],
                [.text("2001-01-01T00:00:00Z"), .double(3)],
            ])
        let datum = try #require(
            preparedDatumValues(
                snapshot: AutoChartSnapshot(input),
                specification: AutoChartSpecification(
                    family: .boxPlot,
                    encoding: .init(x: temporal.id, y: measure.id)
                )
            ).first)

        #expect(datum.xSourceValue == nil)
        #expect(datum.xLabel != datum.xIdentity)
        #expect(datum.xLabel?.hasPrefix("date:") == false)
    }

    @Test func boxPlotUsesOneNumericLabelConventionForMergedAndUnmergedGroups() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let input = table(
            columns: [ordinal, measure],
            rows: [
                [.integer(1_000), .double(1)],
                [.double(1_000), .double(3)],
                [.double(2_000), .double(2)],
                [.double(2_000), .double(4)],
            ])
        let snapshot = AutoChartSnapshot(input)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: ordinal.id, y: measure.id)),
            profiles: AutoChartProfiler.profileIndex(snapshot))

        let merged = try #require(prepared.data.first { $0.xSourceValue == nil })
        let unmerged = try #require(
            prepared.data.first { $0.xSourceValue == .double(2_000) })

        #expect(prepared.data.count == 2)
        #expect(merged.xLabel == "1000")
        #expect(unmerged.xLabel == "2000")
    }

    @Test func boxPlotNumericLabelsNormalizeSignedZeroAcrossMembershipAndSemantics() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let nominal = AutoChartColumn(
            id: "nominal", name: "nominal",
            hints: AutoChartColumnHints(semanticType: .nominal))
        func datum(
            _ categoryValues: [AutoChartValue],
            category: AutoChartColumn
        ) throws -> AutoChartDatum {
            let snapshot = AutoChartSnapshot(
                table(
                    columns: [category, measure],
                    rows: categoryValues.enumerated().map { index, value in
                        [value, .double(Double(index + 1))]
                    }))
            let specification = AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: category.id, y: measure.id))
            let prepared = AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: specification,
                profiles: AutoChartProfiler.profileIndex(snapshot))
            #expect(prepared.data.count == 1)
            return try #require(prepared.data.first)
        }

        let negativeOnly = try datum([.double(-0.0)], category: ordinal)
        let positiveOnly = try datum([.double(0.0)], category: ordinal)
        let forward = try datum([.double(0.0), .double(-0.0)], category: ordinal)
        let reversed = try datum([.double(-0.0), .double(0.0)], category: ordinal)
        let nominalMixed = try datum([.double(-0.0), .double(0.0)], category: nominal)
        func isCanonicalZero(_ value: AutoChartValue?) -> Bool {
            guard case .double(let number)? = value else { return false }
            return number.bitPattern == 0.0.bitPattern
        }
        #expect(forward.sourceRowIDs == [0, 1])
        #expect(reversed.sourceRowIDs == forward.sourceRowIDs)
        #expect(
            [negativeOnly, positiveOnly, forward, reversed, nominalMixed]
                .allSatisfy { isCanonicalZero($0.xSourceValue) })
        #expect(
            [negativeOnly, positiveOnly, forward, reversed, nominalMixed]
                .allSatisfy { $0.xLabel == "0" })
        #expect(nominalMixed.xLabel != AutoChartValue.unrepresentableValuePlaceholder)
    }

    @Test func boxPlotCanonicalizesEqualDecimalStorageRepresentations() throws {
        let ordinal = AutoChartColumn(
            id: "ordinal", name: "ordinal",
            hints: AutoChartColumnHints(semanticType: .ordinal))
        let one = Decimal(
            _exponent: 0,
            _length: 1,
            _isNegative: 0,
            _isCompact: 1,
            _reserved: 0,
            _mantissa: (1, 0, 0, 0, 0, 0, 0, 0))
        let onePointZero = Decimal(
            _exponent: -1,
            _length: 1,
            _isNegative: 0,
            _isCompact: 0,
            _reserved: 0,
            _mantissa: (10, 0, 0, 0, 0, 0, 0, 0))
        #expect(one == onePointZero)

        func datum(_ values: [Decimal]) throws -> AutoChartDatum {
            let snapshot = AutoChartSnapshot(
                table(
                    columns: [ordinal, measure],
                    rows: values.enumerated().map { index, value in
                        [.decimal(value), .double(Double(index + 1))]
                    }))
            let specification = AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: ordinal.id, y: measure.id))
            let prepared = AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: specification,
                profiles: AutoChartProfiler.profileIndex(snapshot))
            let datum = try #require(prepared.data.first)
            let selection = AutoChartSelectionPreparation.semanticValues(
                for: [datum],
                specification: specification,
                measureSemantics: prepared.measureSemantics)
            let dimension = try #require(selection.dimensions.first)
            guard case .decimal(let selectedValue) = dimension.value else {
                Issue.record("Expected a Decimal selection dimension.")
                return datum
            }
            #expect(selection.dimensions.count == 1)
            #expect(dimension.columnID == ordinal.id)
            #expect(selectedValue.exponent == 0)
            return datum
        }

        let forward = try datum([one, onePointZero])
        let reversed = try datum([onePointZero, one])
        #expect(forward.xIdentity == reversed.xIdentity)
        guard case .decimal(let forwardValue)? = forward.xSourceValue,
            case .decimal(let reversedValue)? = reversed.xSourceValue
        else {
            Issue.record("Expected canonical Decimal source values.")
            return
        }
        #expect(forwardValue.exponent == 0)
        #expect(reversedValue.exponent == 0)
        #expect(forward.xLabel == reversed.xLabel)
    }

    @Test func boxPlotUsesOneMissingGroupWithoutCollidingWithARealLabel() throws {
        let mixed = AutoChartColumn(
            id: "mixed", name: "mixed",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [mixed, measure],
            rows: [
                [.null, .double(1)],
                [.double(.nan), .double(2)],
                [.double(.infinity), .double(3)],
                [.binary(Data([0x01])), .double(4)],
                [.text("Missing value"), .double(5)],
            ])
        let snapshot = AutoChartSnapshot(input)
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: mixed.id, y: measure.id))
        let validation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let data = prepared.data
        let missing = try #require(data.first { $0.xIdentity == nil })
        let real = try #require(data.first { $0.xIdentity != nil })

        #expect(validation.isValid)
        #expect(
            validation.issues.contains {
                $0.severity == .warning
                    && $0.messageValue.code == .boxPlotMissingCategoryGroup
                    && $0.message
                        == "Unrenderable box-plot categories are combined into one missing-value group."
            })
        #expect(data.count == 2)
        #expect(Set(data.map(\.id)).count == data.count)
        #expect(missing.sourceRowIDs.count == 4)
        #expect(missing.xSourceValue == nil)
        #expect(missing.xLabel == "Missing value")
        #expect(real.xLabel == "Missing value")

        let missingSelection = AutoChartSelectionPreparation.semanticValues(
            for: [missing],
            specification: specification,
            measureSemantics: prepared.measureSemantics)
        #expect(missingSelection.dimensions.isEmpty)

        let presentation = AutoChartRenderPresentation(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles,
            data: data,
            measureSemantics: prepared.measureSemantics)
        let resolved = presentation.resolvedPresentation(data: data, using: .default)
        let missingDisplayValue = disambiguatedCategoryValue(
            identity: missing.xIdentity,
            label: missing.xLabel,
            labels: resolved.xDisplayLabels,
            fallback: resolved.missingValue)
        let realDisplayValue = disambiguatedCategoryValue(
            identity: real.xIdentity,
            label: real.xLabel,
            labels: resolved.xDisplayLabels,
            fallback: resolved.missingValue)

        #expect(missingDisplayValue == "Missing value")
        #expect(realDisplayValue != missingDisplayValue)
    }

    @Test func boxPlotDoesNotWarnForMissingCategoriesWithoutMeasures() {
        let input = table(
            columns: [category, measure],
            rows: [
                [.text("A"), .double(1)],
                [.null, .null],
            ])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: category.id, y: measure.id))
        let validation = AutoChartRecommendationEngine.validate(
            specification: specification,
            for: input)

        #expect(validation.isValid)
        #expect(
            !validation.issues.contains {
                $0.messageValue.code == .boxPlotMissingCategoryGroup
            })
    }

    @Test func invalidBoxPlotEncodingsDoNotEmitMissingCategoryWarning() {
        let invalidCategory = AutoChartColumn(
            id: "invalid-category", name: "invalid-category",
            hints: AutoChartColumnHints(semanticType: .quantitative))
        let invalidCategoryInput = table(
            columns: [invalidCategory, measure],
            rows: [
                [.null, .double(1)],
                [.double(2), .double(3)],
            ])
        let invalidCategoryValidation = AutoChartRecommendationEngine.validate(
            specification: AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: invalidCategory.id, y: measure.id)),
            for: invalidCategoryInput)

        let invalidMeasure = AutoChartColumn(
            id: "invalid-measure", name: "invalid-measure",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let invalidMeasureInput = table(
            columns: [category, invalidMeasure],
            rows: [
                [.null, .double(1)],
                [.text("A"), .double(3)],
            ])
        let invalidMeasureValidation = AutoChartRecommendationEngine.validate(
            specification: AutoChartSpecification(
                family: .boxPlot,
                encoding: .init(x: category.id, y: invalidMeasure.id)),
            for: invalidMeasureInput)

        for validation in [invalidCategoryValidation, invalidMeasureValidation] {
            #expect(!validation.isValid)
            #expect(
                !validation.issues.contains {
                    $0.messageValue.code == .boxPlotMissingCategoryGroup
                })
        }
    }

    @Test func missingBoxPlotCategoriesReachPublicPreparation() async throws {
        let mixed = AutoChartColumn(
            id: "mixed", name: "mixed",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let input = table(
            columns: [mixed, measure],
            rows: [
                [.null, .double(1)],
                [.double(.nan), .double(2)],
                [.text("A"), .double(3)],
            ])
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: mixed.id, y: measure.id))
        let analysis = try await AutoChartAnalyzer().analyze(input)
        let prepared = try await analysis.prepare(specification)

        #expect(prepared.validation.isValid)
        #expect(prepared.marks.count == 2)
        #expect(Set(prepared.marks.map(\.identity)).count == prepared.marks.count)
        #expect(
            prepared.marks.first { $0.identity == "box-missing" }?.sourceRowIDs
                == ["r0", "r1"])
    }

    @Test func boxPlotPreservesNullSelectionOnlyForAnAllNullGroup() throws {
        let mixed = AutoChartColumn(
            id: "mixed", name: "mixed",
            hints: AutoChartColumnHints(semanticType: .nominal))
        let snapshot = AutoChartSnapshot(
            table(
                columns: [mixed, measure],
                rows: [[.null, .double(1)], [.null, .double(2)]]))
        let specification = AutoChartSpecification(
            family: .boxPlot,
            encoding: .init(x: mixed.id, y: measure.id))
        let prepared = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: AutoChartProfiler.profileIndex(snapshot))
        let missing = try #require(prepared.data.first)
        let selection = AutoChartSelectionPreparation.semanticValues(
            for: [missing],
            specification: specification,
            measureSemantics: prepared.measureSemantics)

        #expect(missing.xSourceValue == .null)
        #expect(
            selection.dimensions
                == [.init(columnID: mixed.id, value: .null)])
    }

    @Test func boxPlotOrderingUsesResolvedDisplayValues() {
        let data = [
            AutoChartDatum(
                id: "missing", sourceRowIDs: [0], xLabel: "Missing value",
                median: 1),
            AutoChartDatum(
                id: "real", sourceRowIDs: [1],
                xIdentity: "text:8:November", xLabel: "November", median: 2),
        ]
        let ordered = orderedBoxPlotData(
            data,
            labels: ["text:8:November": "November"],
            fallback: "Zulu",
            locale: Locale(identifier: "en_US"))
        let displayValues = ordered.map {
            disambiguatedCategoryValue(
                identity: $0.xIdentity,
                label: $0.xLabel,
                labels: ["text:8:November": "November"],
                fallback: "Zulu")
        }

        #expect(ordered.map(\.id) == ["real", "missing"])
        #expect(displayValues == ["November", "Zulu"])
        #expect(!displayValues.contains("all"))
    }

    @Test func boxPlotOrderingUsesLocaleAwareCollation() {
        let data = [
            AutoChartDatum(
                id: "z", sourceRowIDs: [0],
                xIdentity: "text:1:z", xLabel: "z", median: 1),
            AutoChartDatum(
                id: "umlaut", sourceRowIDs: [1],
                xIdentity: "text:2:ä", xLabel: "ä", median: 2),
        ]
        let ordered = orderedBoxPlotData(
            data,
            labels: ["text:1:z": "z", "text:2:ä": "ä"],
            fallback: "Missing",
            locale: Locale(identifier: "de_DE"))

        #expect(ordered.map(\.id) == ["umlaut", "z"])
    }

}
