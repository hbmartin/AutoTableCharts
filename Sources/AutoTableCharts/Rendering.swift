import Foundation

#if canImport(Charts) && canImport(SwiftUI)
import Charts
import SwiftUI
#endif

struct AutoChartDatum: Identifiable, Sendable {
    var id: String
    var sourceRowIDs: Set<AutoChartRowID>
    var xIdentity: String? = nil
    var xLabel: String?
    var xNumber: Double?
    var xDate: Date?
    var yIdentity: String? = nil
    var yLabel: String?
    var yNumber: Double?
    var seriesIdentity: String? = nil
    var series: String?
    var size: Double?
    var facetIdentity: String? = nil
    var facet: String?
    var startDate: Date?
    var endDate: Date?
    var lower: Double?
    var quartile1: Double?
    var median: Double?
    var quartile3: Double?
    var upper: Double?

    var accessibilityLabel: String {
        let name =
            xDate?.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: .shortened,
                    timeZone: TimeZone.gmt)) ?? xLabel
            ?? xNumber?.formatted() ?? yLabel ?? "Value"
        let value =
            yNumber?.formatted(.number.precision(.fractionLength(0...3)))
            ?? median?.formatted(.number.precision(.fractionLength(0...3))) ?? ""
        return value.isEmpty ? name : "\(name), \(value)"
    }
}

enum AutoChartDataPreparation {
    static func data(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        let profiles = Dictionary(
            AutoChartProfiler.profiles(snapshot).map { ($0.column.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return data(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
    }

    static func data(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        switch specification.family {
        case .histogram:
            return histogram(snapshot: snapshot, specification: specification)
        case .boxPlot:
            return boxPlot(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        case .heatmap:
            return heatmap(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        case .donut:
            return grouped(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles,
                forceSum: true)
        default:
            if specification.aggregation != .none {
                return grouped(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles,
                    forceSum: false)
            }
            return sorted(
                raw(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles),
                specification: specification)
        }
    }

    private static func raw(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        let encoding = specification.encoding
        return snapshot.rows.enumerated().compactMap { index, row in
            let xValue = encoding.x.flatMap { row.values[$0] }
            let yValue = encoding.y.flatMap { row.values[$0] }
            let start = encoding.start.flatMap { row.values[$0] }
            let end = encoding.end.flatMap { row.values[$0] }
            if specification.family == .range {
                guard start.flatMap(AutoChartProfiler.dateValue) != nil,
                    end.flatMap(AutoChartProfiler.dateValue) != nil
                else { return nil }
            } else if specification.family != .table,
                specification.family != .kpi,
                let x = encoding.x
            {
                let isRenderable: Bool =
                    switch profiles[x]?.semanticType {
                    case .temporal:
                        xValue.flatMap(AutoChartProfiler.dateValue) != nil
                    case .quantitative:
                        xValue?.numericValue != nil
                    default: xValue?.categoryString() != nil
                    }
                guard isRenderable else { return nil }
            }
            if specification.family != .table,
                specification.family != .kpi,
                encoding.y != nil,
                yValue?.numericValue == nil
            {
                return nil
            }
            return AutoChartDatum(
                id: "row-\(index)-\(row.id.rawValue)",
                sourceRowIDs: [row.id],
                xIdentity: AutoChartProfiler.identityString(
                    xValue, semanticType: encoding.x.flatMap { profiles[$0]?.semanticType }),
                xLabel: xValue?.categoryString(),
                xNumber: xValue?.numericValue,
                xDate: xValue.flatMap(AutoChartProfiler.dateValue),
                yLabel: yValue?.categoryString(),
                yNumber: yValue?.numericValue,
                seriesIdentity: encoding.series.flatMap { id in
                    AutoChartProfiler.identityString(
                        row.values[id], semanticType: profiles[id]?.semanticType)
                },
                series: encoding.series.flatMap { row.values[$0]?.categoryString() },
                size: encoding.size.flatMap { row.values[$0]?.numericValue },
                facetIdentity: encoding.facet.flatMap { id in
                    AutoChartProfiler.identityString(
                        row.values[id], semanticType: profiles[id]?.semanticType)
                },
                facet: encoding.facet.flatMap { row.values[$0]?.categoryString() },
                startDate: start.flatMap(AutoChartProfiler.dateValue),
                endDate: end.flatMap(AutoChartProfiler.dateValue))
        }
    }

    private struct GroupKey: Hashable {
        var x: String
        var series: String
        var facet: String
    }

    private static func grouped(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        forceSum: Bool
    ) -> [AutoChartDatum] {
        let rawData = raw(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let groups = Dictionary(grouping: rawData.enumerated()) { indexedDatum in
            let datum = indexedDatum.element
            return GroupKey(
                x: datum.xIdentity ?? "missing",
                series: datum.seriesIdentity ?? "missing",
                facet: datum.facetIdentity ?? "missing")
        }
        let aggregated = groups.sorted {
            $0.value[0].offset < $1.value[0].offset
        }.map { key, indexedGroup -> AutoChartDatum in
            let group = indexedGroup.map { $0.element }
            let values = group.compactMap { $0.yNumber }
            let aggregation = forceSum ? AutoChartAggregation.sum : specification.aggregation
            let result: Double =
                switch aggregation {
                case .none, .sum: values.reduce(0, +)
                case .mean: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                case .minimum: values.min() ?? 0
                case .maximum: values.max() ?? 0
                case .count: Double(group.count)
                case .countDistinct: Double(Set(values).count)
                }
            let first = group[0]
            return AutoChartDatum(
                id: "group-\(first.id)",
                sourceRowIDs: group.reduce(into: []) {
                    $0.formUnion($1.sourceRowIDs)
                },
                xIdentity: first.xIdentity,
                xLabel: first.xLabel,
                xNumber: first.xNumber,
                xDate: first.xDate,
                yNumber: result,
                seriesIdentity: first.seriesIdentity,
                series: first.series,
                facetIdentity: first.facetIdentity,
                facet: first.facet)
        }
        return sorted(aggregated, specification: specification)
    }

    private static func histogram(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x else { return [] }
        let values = snapshot.rows.compactMap { row -> (Double, AutoChartRowID)? in
            guard let value = row.values[x]?.numericValue, value.isFinite else { return nil }
            return (value, row.id)
        }
        guard let minimum = values.map(\.0).min(), let maximum = values.map(\.0).max() else {
            return []
        }
        let count = min(1_000, max(1, specification.binCount ?? 10))
        let scale = maximum > minimum ? max(abs(minimum), abs(maximum)) : 1
        let scaledMinimum = minimum / scale
        let scaledMaximum = maximum / scale
        let scaledWidth =
            scaledMaximum > scaledMinimum
            ? (scaledMaximum - scaledMinimum) / Double(count) : 1
        var bins: [[(Double, AutoChartRowID)]] = Array(repeating: [], count: count)
        for value in values {
            let scaledValue = value.0 / scale
            let position = (scaledValue - scaledMinimum) / scaledWidth
            let rawIndex = position.isFinite ? Int(position.rounded(.down)) : 0
            bins[min(max(rawIndex, 0), count - 1)].append(value)
        }
        return bins.enumerated().map { index, bin in
            let scaledStart = scaledMinimum + Double(index) * scaledWidth
            let scaledEnd = scaledStart + scaledWidth
            let start = scaledStart * scale
            let end = scaledEnd * scale
            let midpoint = (scaledStart + scaledWidth / 2) * scale
            return AutoChartDatum(
                id: "bin-\(index)",
                sourceRowIDs: Set(bin.map(\.1)),
                xLabel:
                    "\(start.formatted(.number.precision(.fractionLength(0...2))))–\(end.formatted(.number.precision(.fractionLength(0...2))))",
                xNumber: midpoint,
                yNumber: Double(bin.count),
                lower: start,
                upper: end)
        }
    }

    private static func boxPlot(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let y = specification.encoding.y else { return [] }
        let x = specification.encoding.x
        struct BoxGroupKey: Hashable {
            var identity: String
            var label: String
        }
        let semanticType = x.flatMap { profiles[$0]?.semanticType }
        let grouped = Dictionary(grouping: snapshot.rows) { row in
            guard let x else {
                return BoxGroupKey(identity: "all", label: "All")
            }
            let value = row.values[x]
            return BoxGroupKey(
                identity: AutoChartProfiler.identityString(
                    value, semanticType: semanticType) ?? "missing",
                label: value?.categoryString() ?? "Missing value")
        }
        return grouped.compactMap { key, rows in
            let sortedValues = rows.compactMap { $0.values[y]?.numericValue }.sorted()
            guard !sortedValues.isEmpty else { return nil }
            func quantile(_ p: Double) -> Double {
                guard sortedValues.count > 1 else { return sortedValues[0] }
                let position = p * Double(sortedValues.count - 1)
                let lower = Int(position.rounded(.down))
                let upper = Int(position.rounded(.up))
                if lower == upper { return sortedValues[lower] }
                let fraction = position - Double(lower)
                return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
            }
            return AutoChartDatum(
                id: "box-\(key.identity)",
                sourceRowIDs: Set(rows.map(\.id)),
                xIdentity: key.identity,
                xLabel: key.label,
                lower: sortedValues.first,
                quartile1: quantile(0.25),
                median: quantile(0.5),
                quartile3: quantile(0.75),
                upper: sortedValues.last)
        }.sorted {
            ($0.xLabel ?? "", $0.xIdentity ?? "")
                < ($1.xLabel ?? "", $1.xIdentity ?? "")
        }
    }

    private static func heatmap(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x, let y = specification.encoding.y else {
            return []
        }
        struct Key: Hashable {
            var xIdentity: String
            var yIdentity: String
            var xLabel: String
            var yLabel: String
        }
        var groups: [Key: [AutoChartSnapshot.Row]] = [:]
        for row in snapshot.rows {
            guard let xLabel = row.values[x]?.categoryString(),
                let yLabel = row.values[y]?.categoryString(),
                let xIdentity = AutoChartProfiler.identityString(
                    row.values[x], semanticType: profiles[x]?.semanticType),
                let yIdentity = AutoChartProfiler.identityString(
                    row.values[y], semanticType: profiles[y]?.semanticType)
            else { continue }
            groups[
                Key(
                    xIdentity: xIdentity,
                    yIdentity: yIdentity,
                    xLabel: xLabel,
                    yLabel: yLabel),
                default: []
            ].append(row)
        }
        return groups.map { key, rows in
            AutoChartDatum(
                id:
                    "heat-\(key.xIdentity.utf8.count):\(key.xIdentity)\(key.yIdentity.utf8.count):\(key.yIdentity)",
                sourceRowIDs: Set(rows.map(\.id)),
                xIdentity: key.xIdentity,
                xLabel: key.xLabel,
                yIdentity: key.yIdentity,
                yLabel: key.yLabel,
                yNumber: Double(rows.count))
        }.sorted {
            ($0.xLabel ?? "", $0.yLabel ?? "", $0.xIdentity ?? "", $0.yIdentity ?? "")
                < ($1.xLabel ?? "", $1.yLabel ?? "", $1.xIdentity ?? "", $1.yIdentity ?? "")
        }
    }

    private static func sorted(
        _ data: [AutoChartDatum],
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        if [.line, .pointLine, .area, .faceted].contains(specification.family) {
            if data.contains(where: { $0.xDate != nil }) {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xDate ?? .distantPast
                    let right = rhs.element.xDate ?? .distantPast
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
            if [.line, .pointLine, .area].contains(specification.family),
                data.contains(where: { $0.xNumber != nil })
            {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xNumber ?? -.infinity
                    let right = rhs.element.xNumber ?? -.infinity
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
        }
        return switch specification.sort {
        case .source: data
        case .ascending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") < ($1.yNumber ?? 0, $1.xLabel ?? "") }
        case .descending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") > ($1.yNumber ?? 0, $1.xLabel ?? "") }
        }
    }
}

#if canImport(Charts) && canImport(SwiftUI)
private func disambiguatedCategoryLabels(
    _ pairs: [(identity: String, label: String)]
) -> [String: String] {
    var labels: [String: String] = [:]
    for (label, pairs) in Dictionary(grouping: pairs, by: \.label) {
        let identities = Array(Set(pairs.map(\.identity))).sorted()
        guard identities.count > 1 else {
            if let identity = identities.first { labels[identity] = label }
            continue
        }
        let kinds = identities.map { identity -> String in
            switch identity.split(separator: ":", maxSplits: 1).first {
            case "boolean": "Boolean"
            case "integer": "Integer"
            case "double": "Number"
            case "decimal": "Decimal"
            case "text": "Text"
            case "date": "Date"
            default: "Value"
            }
        }
        let kindCounts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        var kindIndexes: [String: Int] = [:]
        for (identity, kind) in zip(identities, kinds) {
            kindIndexes[kind, default: 0] += 1
            let qualifier =
                kindCounts[kind, default: 0] == 1
                ? kind : "\(kind) \(kindIndexes[kind, default: 0])"
            labels[identity] = "\(label) (\(qualifier))"
        }
    }
    return labels
}

/// A native Swift Charts view for an AutoTableCharts recommendation or specification.
///
/// The view snapshots the supplied table, prepares marks without mutating source
/// storage, validates the specification, and preserves contributing
/// ``AutoChartRowID`` values in bound selection state.
public struct AutoChartView: View {
    private let snapshot: AutoChartSnapshot
    private let recommendation: AutoChartRecommendation
    private let validation: AutoChartValidationResult
    private let data: [AutoChartDatum]
    private let sizeBounds: (minimum: Double, maximum: Double)?
    private let sharedYDomain: ClosedRange<Double>?
    private let interaction: AutoChartInteraction
    private let chartHeight: CGFloat
    private let snapshotFingerprint: Int
    private let xTitle: String
    private let yTitle: String
    private let seriesTitle: String
    private let uniqueXCount: Int
    @Binding private var selection: AutoChartSelection?

    @State private var selectedCategory: String?
    @State private var selectedDate: Date?
    @State private var selectedNumber: Double?
    @State private var selectedAngle: Double?
    @State private var zoomScale = 1.0
    @State private var zoomAnchor = 1.0

    /// Creates a chart from an engine-generated recommendation.
    ///
    /// Use this initializer when you want the recommendation's explanation and
    /// warnings to remain attached to the rendered chart.
    ///
    /// - Parameters:
    ///   - table: The same typed table used to generate the recommendation.
    ///   - recommendation: A validated engine result.
    ///   - selection: Optional linked selection state containing source-row IDs.
    ///   - interaction: Compact preview or exploratory interaction behavior.
    ///   - height: The requested chart height in points.
    public init<Table: AutoChartTable>(
        table: Table,
        recommendation: AutoChartRecommendation,
        selection: Binding<AutoChartSelection?> = .constant(nil),
        interaction: AutoChartInteraction = .explore,
        height: CGFloat = 280
    ) {
        let snapshot = AutoChartSnapshot(table)
        let profiles = Dictionary(
            AutoChartProfiler.profiles(snapshot).map { ($0.column.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let specification = recommendation.specification
        let data = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let sizes = data.compactMap(\.size).filter(\.isFinite)
        let yValues = data.compactMap(\.yNumber).filter(\.isFinite)
        self.snapshot = snapshot
        self.recommendation = recommendation
        validation = AutoChartEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles)
        self.data = data
        if let minimum = sizes.min(), let maximum = sizes.max() {
            sizeBounds = (minimum, maximum)
        } else {
            sizeBounds = nil
        }
        if let minimum = yValues.min(), let maximum = yValues.max() {
            let includesCategoricalX = specification.encoding.x.flatMap {
                profiles[$0]?.isCategorical
            } ?? false
            let lower = includesCategoricalX ? min(0, minimum) : minimum
            let upper = includesCategoricalX ? max(0, maximum) : maximum
            if lower == upper {
                let padding = max(1, abs(lower) * 0.05)
                sharedYDomain = (lower - padding)...(upper + padding)
            } else if includesCategoricalX {
                sharedYDomain = lower...upper
            } else {
                let padding = max(abs(lower), abs(upper)) * 0.05
                sharedYDomain = (lower - padding)...(upper + padding)
            }
        } else {
            sharedYDomain = nil
        }
        self._selection = selection
        self.interaction = interaction
        chartHeight = height
        snapshotFingerprint = snapshot.contentFingerprint
        xTitle = specification.encoding.x.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Category"
        yTitle = specification.encoding.y.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Value"
        seriesTitle = specification.encoding.series.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Series"
        uniqueXCount = Set(data.compactMap { $0.xIdentity ?? $0.xLabel }).count
    }

    /// Creates a chart from a caller-provided specification.
    ///
    /// The view validates the specification and displays diagnostics instead of
    /// an invalid chart. Call ``AutoChartEngine/validate(specification:for:)``
    /// first when the surrounding UI needs to react to errors.
    ///
    /// - Parameters:
    ///   - table: The typed table represented by the specification.
    ///   - specification: A caller-authored chart description.
    ///   - selection: Optional linked selection state containing source-row IDs.
    ///   - interaction: Compact preview or exploratory interaction behavior.
    ///   - height: The requested chart height in points.
    public init<Table: AutoChartTable>(
        table: Table,
        specification: AutoChartSpecification,
        selection: Binding<AutoChartSelection?> = .constant(nil),
        interaction: AutoChartInteraction = .explore,
        height: CGFloat = 280
    ) {
        let warnings =
            table.chartMetadata.isTruncated
            ? ["Based on the first returned rows; totals and composition are suppressed."]
            : []
        self.init(
            table: table,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Caller-provided specification."],
                warnings: warnings),
            selection: selection,
            interaction: interaction,
            height: height)
    }

    private var specification: AutoChartSpecification { recommendation.specification }

    /// The validated chart, warnings, selection summary, and exploration controls.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !specification.title.isEmpty {
                Text(specification.title)
                    .font(interaction == .preview ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(interaction == .preview ? 2 : nil)
            }
            if validation.isValid {
                chartBody
                    .frame(minHeight: interaction == .explore ? chartHeight : 180)
                if interaction == .explore, let selection {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.label).font(.subheadline.weight(.semibold))
                            Text(selection.valueDescription).font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        Button("Clear") { clearSelection() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("auto-chart-clear-selection")
                    }
                    .accessibilityElement(children: .combine)
                }
                if interaction == .explore, zoomScale > 1.01 {
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise") {
                        zoomScale = 1
                        zoomAnchor = 1
                    }
                    .font(.caption)
                    .accessibilityIdentifier("auto-chart-reset-zoom")
                }
            } else {
                ContentUnavailableView(
                    "Chart unavailable",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        validation.issues.map(\.message).joined(separator: " ")))
            }
            ForEach(recommendation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            specification.title.isEmpty ? specification.family.displayName : specification.title
        )
        .accessibilityIdentifier("auto-chart-\(specification.family.rawValue)")
        .onChange(of: recommendation.id) { _, _ in
            resetInteractionState()
        }
        .onChange(of: snapshotFingerprint) { _, _ in
            resetInteractionState()
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch specification.family {
        case .table:
            ContentUnavailableView(
                "Use the table view",
                systemImage: "tablecells",
                description: Text(
                    recommendation.rationale.first ?? "No safe chart is available."))
        case .kpi:
            kpiView
        case .bar, .groupedBar, .stackedBar, .normalizedBar:
            barChart
        case .rankedDot:
            rankedDotChart
        case .line, .pointLine, .area:
            lineChart
        case .scatter, .bubble:
            scatterChart
        case .histogram:
            histogramChart
        case .boxPlot:
            boxPlotChart
        case .heatmap:
            heatmapChart
        case .donut:
            donutChart
        case .range:
            rangeChart
        case .faceted:
            facetedChart
        }
    }

    private var kpiView: some View {
        let value = specification.encoding.y.flatMap { id in
            snapshot.rows.first?.values[id]
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(value.map(formatted) ?? "—")
                .font(
                    .system(
                        size: interaction == .preview ? 34 : 52, weight: .bold, design: .rounded
                    )
                )
                .minimumScaleFactor(0.6)
            Text(
                specification.encoding.y.flatMap { snapshot.column($0)?.name }
                    .map(AutoChartProfiler.humanized) ?? "Value"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var barChart: some View {
        if specification.orientation == .horizontal {
            let chart = Chart(data) { datum in
                if specification.family == .groupedBar {
                    BarMark(
                        x: .value(yTitle, datum.yNumber ?? 0),
                        y: .value(xTitle, datum.xLabel ?? ""),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .position(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .accessibilityLabel(datum.accessibilityLabel)
                } else {
                    BarMark(
                        x: .value(yTitle, datum.yNumber ?? 0),
                        y: .value(xTitle, datum.xLabel ?? ""),
                        stacking: stackingMethod
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .accessibilityLabel(datum.accessibilityLabel)
                }
            }
            .chartXAxisLabel(yTitle)
            .chartYAxisLabel(xTitle)
            selectableCategoryY(verticalZoom(chart, categoryCount: uniqueXCount))
        } else {
            let chart = Chart(data) { datum in
                if specification.family == .groupedBar {
                    BarMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .position(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .accessibilityLabel(datum.accessibilityLabel)
                } else {
                    BarMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: stackingMethod
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .accessibilityLabel(datum.accessibilityLabel)
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
        }
    }

    private var rankedDotChart: some View {
        let chart = Chart(data) { datum in
            RuleMark(
                xStart: .value(yTitle, 0),
                xEnd: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, datum.xLabel ?? "")
            )
            .foregroundStyle(.secondary.opacity(0.45))
            PointMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, datum.xLabel ?? "")
            )
            .symbol(.circle)
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(yTitle)
        .chartYAxisLabel(xTitle)
        return selectableCategoryY(verticalZoom(chart, categoryCount: uniqueXCount))
    }

    @ViewBuilder
    private var lineChart: some View {
        if data.contains(where: { $0.xDate != nil }) {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, datum.xDate ?? .distantPast),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .opacity(0.45)
                }
                LineMark(
                    x: .value(xTitle, datum.xDate ?? .distantPast),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                )
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .lineStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xDate ?? .distantPast),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else if data.contains(where: { $0.xNumber != nil }) {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, datum.xNumber ?? 0),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .opacity(0.45)
                }
                LineMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                )
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .lineStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xNumber ?? 0),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .opacity(0.45)
                }
                LineMark(
                    x: .value(xTitle, datum.xLabel ?? ""),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                )
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .lineStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, datum.series ?? primarySeriesLabel)
                    )
                    .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
        }
    }

    @ViewBuilder
    private var scatterChart: some View {
        if data.contains(where: { $0.xDate != nil }) {
            let chart = Chart(data) { datum in
                PointMark(
                    x: .value(xTitle, datum.xDate ?? .distantPast),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize(for: datum.size))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .accessibilityLabel(datum.accessibilityLabel)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                PointMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize(for: datum.size))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .accessibilityLabel(datum.accessibilityLabel)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        }
    }

    private var histogramChart: some View {
        let chart = Chart(data) { datum in
            BarMark(
                xStart: .value(xTitle, datum.lower ?? 0),
                xEnd: .value(xTitle, datum.upper ?? 0),
                y: .value("Count", datum.yNumber ?? 0)
            )
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel("Count")
        return selectableNumberX(numberZoom(chart))
    }

    private var boxPlotChart: some View {
        let labels = disambiguatedCategoryLabels(
            data.compactMap { datum -> (String, String)? in
                guard let identity = datum.xIdentity, let label = datum.xLabel else { return nil }
                return (identity, label)
            })
        let chart = Chart(data) { datum in
            RuleMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                yStart: .value(yTitle, datum.lower ?? 0),
                yEnd: .value(yTitle, datum.upper ?? 0))
            BarMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                yStart: .value(yTitle, datum.quartile1 ?? 0),
                yEnd: .value(yTitle, datum.quartile3 ?? 0),
                width: .fixed(28))
            PointMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                y: .value("Median", datum.median ?? 0)
            )
            .symbol(.square)
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(xTitle)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(labels[identity] ?? identity)
                    }
                }
            }
        }
        .chartYAxisLabel(yTitle)
        return selectableCategoryIdentityX(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var heatmapChart: some View {
        let xLabels = disambiguatedCategoryLabels(
            data.compactMap { datum -> (String, String)? in
                guard let identity = datum.xIdentity, let label = datum.xLabel else { return nil }
                return (identity, label)
            })
        let yLabels = disambiguatedCategoryLabels(
            data.compactMap { datum -> (String, String)? in
                guard let identity = datum.yIdentity, let label = datum.yLabel else { return nil }
                return (identity, label)
            })
        let chart = Chart(data) { datum in
            RectangleMark(
                x: .value(xTitle, datum.xIdentity ?? ""),
                y: .value(yTitle, datum.yIdentity ?? "")
            )
            .foregroundStyle(by: .value("Count", datum.yNumber ?? 0))
            .accessibilityLabel(
                "\(datum.xLabel ?? "Value"), \(datum.yLabel ?? "Value"), \((datum.yNumber ?? 0).formatted())"
            )
        }
        .chartXAxisLabel(xTitle)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(xLabels[identity] ?? identity)
                    }
                }
            }
        }
        .chartYAxisLabel(yTitle)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(yLabels[identity] ?? identity)
                    }
                }
            }
        }
        return selectableHeatmap(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var donutChart: some View {
        let chart = Chart(data) { datum in
            SectorMark(
                angle: .value(yTitle, datum.yNumber ?? 0),
                innerRadius: .ratio(0.56),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value(xTitle, datum.xLabel ?? ""))
            .accessibilityLabel(datum.accessibilityLabel)
            .annotation(position: .overlay) {
                Text(datum.xLabel ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        return selectableAngle(chart)
    }

    private var rangeChart: some View {
        let chart = Chart(data) { datum in
            BarMark(
                xStart: .value("Start", datum.startDate ?? .distantPast),
                xEnd: .value("End", datum.endDate ?? .distantPast),
                y: .value(xTitle, datum.xLabel ?? "")
            )
            .accessibilityLabel(datum.accessibilityLabel)
            if datum.startDate == datum.endDate {
                PointMark(
                    x: .value("Date", datum.startDate ?? .distantPast),
                    y: .value(xTitle, datum.xLabel ?? "")
                )
                .symbol(.diamond)
            }
        }
        .chartXAxisLabel("Date")
        .chartYAxisLabel(xTitle)
        .environment(\.timeZone, .gmt)
        return selectableCategoryY(timeZoom(chart))
    }

    private var facetedChart: some View {
        let facets = Dictionary(grouping: data) { $0.facetIdentity }
        let facetKeys = facets.keys.sorted {
            let left = facets[$0]?.first?.facet ?? "\u{10FFFF}"
            let right = facets[$1]?.first?.facet ?? "\u{10FFFF}"
            if left != right { return left < right }
            return ($0 ?? "") < ($1 ?? "")
        }
        let facetTitles = disambiguatedCategoryLabels(
            facetKeys.compactMap { key -> (String, String)? in
                guard let key else { return nil }
                return (key, facets[key]?.first?.facet ?? "Missing value")
            })
        let yDomain = sharedYDomain ?? 0...1
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(facetKeys, id: \.self) { facetKey in
                    let facetData = facets[facetKey] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Text(facetKey.flatMap { facetTitles[$0] } ?? "Missing value")
                            .font(.caption.weight(.semibold))
                        if facetData.contains(where: { $0.xDate != nil }) {
                            let chart = Chart(facetData) { datum in
                                LineMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0),
                                    series: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel)
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel)
                                )
                                .lineStyle(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel))
                                PointMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0)
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel)
                                )
                                .symbol(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel))
                                .accessibilityLabel(datum.accessibilityLabel)
                            }
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, .gmt)
                            selectableFacetX(chart, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                        } else if facetData.contains(where: { $0.xNumber != nil }) {
                            let chart = Chart(facetData) { datum in
                                PointMark(
                                    x: .value(xTitle, datum.xNumber ?? 0),
                                    y: .value(yTitle, datum.yNumber ?? 0)
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel)
                                )
                                .symbol(
                                    by: .value(
                                        seriesTitle, datum.series ?? primarySeriesLabel))
                                .accessibilityLabel(datum.accessibilityLabel)
                            }
                            .chartYScale(domain: yDomain)
                            selectableFacetX(chart, as: Double.self) { value in
                                select(number: value, in: facetData)
                            }
                        } else {
                            let chart = Chart(facetData) { datum in
                                if specification.encoding.series != nil {
                                    BarMark(
                                        x: .value(xTitle, datum.xLabel ?? ""),
                                        y: .value(yTitle, datum.yNumber ?? 0),
                                        stacking: .unstacked
                                    )
                                    .foregroundStyle(
                                        by: .value(
                                            seriesTitle, datum.series ?? primarySeriesLabel)
                                    )
                                    .position(
                                        by: .value(
                                            seriesTitle, datum.series ?? primarySeriesLabel))
                                    .accessibilityLabel(datum.accessibilityLabel)
                                } else {
                                    BarMark(
                                        x: .value(xTitle, datum.xLabel ?? ""),
                                        y: .value(yTitle, datum.yNumber ?? 0))
                                    .accessibilityLabel(datum.accessibilityLabel)
                                }
                            }
                            .chartYScale(domain: yDomain)
                            selectableFacetX(chart, as: String.self) { value in
                                select(category: value, in: facetData)
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private var primarySeriesLabel: String { yTitle }

    private func symbolSize(for value: Double?) -> Double {
        guard specification.family == .bubble else { return 45 }
        guard let value, value.isFinite, let sizeBounds else { return 40 }
        guard sizeBounds.maximum > sizeBounds.minimum else { return 132 }
        let normalized = min(
            1,
            max(0, (value - sizeBounds.minimum) / (sizeBounds.maximum - sizeBounds.minimum)))
        return 24 + normalized * 216
    }

    private var stackingMethod: MarkStackingMethod {
        switch specification.stacking {
        case .none: .unstacked
        case .standard: .standard
        case .normalized: .normalized
        }
    }

    private func formatted(_ value: AutoChartValue) -> String {
        guard let id = specification.encoding.y,
            let unit = snapshot.column(id)?.hints.unit,
            let numeric = value.numericValue
        else { return value.displayString }
        switch unit {
        case .currency(let code):
            return numeric.formatted(.currency(code: code))
        case .percent(let fractional):
            return (fractional ? numeric : numeric / 100).formatted(
                .percent.precision(.fractionLength(0...2)))
        default:
            return value.displayString
        }
    }

    @ViewBuilder
    private func selectableCategoryX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in select(category: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableCategoryY<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartYSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in select(category: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableCategoryIdentityX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in
                    select(categoryIdentity: value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableHeatmap<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onEnded { value in
                                guard abs(value.translation.width) < 8,
                                    abs(value.translation.height) < 8,
                                    let plotFrame = proxy.plotFrame
                                else { return }
                                let frame = geometry[plotFrame]
                                let location = CGPoint(
                                    x: value.location.x - frame.origin.x,
                                    y: value.location.y - frame.origin.y)
                                guard location.x >= 0, location.y >= 0,
                                    location.x <= frame.width, location.y <= frame.height,
                                    let xIdentity: String = proxy.value(atX: location.x),
                                    let yIdentity: String = proxy.value(atY: location.y)
                                else { return }
                                select(
                                    heatmapXIdentity: xIdentity,
                                    yIdentity: yIdentity)
                            })
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableFacetX<Content: View, Value: Plottable>(
        _ content: Content,
        as _: Value.Type,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        if interaction == .explore {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onEnded { value in
                                guard abs(value.translation.width) < 8,
                                    abs(value.translation.height) < 8,
                                    let plotFrame = proxy.plotFrame
                                else { return }
                                let frame = geometry[plotFrame]
                                let xPosition = value.location.x - frame.origin.x
                                guard xPosition >= 0, xPosition <= frame.width,
                                    let selected: Value = proxy.value(atX: xPosition)
                                else { return }
                                onSelect(selected)
                            })
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableDateX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, value in select(date: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableNumberX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedNumber)
                .onChange(of: selectedNumber) { _, value in select(number: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableAngle<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, value in select(angle: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func horizontalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func verticalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.vertical)
                .chartYVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func timeZoom<Content: View>(_ content: Content) -> some View {
        let dates = data.flatMap { datum in
            [datum.xDate, datum.startDate, datum.endDate].compactMap { $0 }
        }
        let span = max(86_400, (dates.max() ?? .now).timeIntervalSince(dates.min() ?? .now))
        if interaction == .explore, dates.count > 12 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(86_400, span / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func numberZoom<Content: View>(_ content: Content) -> some View {
        let values = data.compactMap(\.xNumber)
        let span = max(1, (values.max() ?? 1) - (values.min() ?? 0))
        if interaction == .explore, values.count > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: span / zoomScale)
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    #if os(tvOS) || os(watchOS)
    private var zoomGesture: some Gesture {
        TapGesture()
    }
    #else
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomScale = min(12, max(1, zoomAnchor * value.magnification))
            }
            .onEnded { _ in zoomAnchor = zoomScale }
    }
    #endif

    private func select(category: String?) {
        select(category: category, in: data)
    }

    private func select(category: String?, in candidates: [AutoChartDatum]) {
        guard let category else {
            selection = nil
            return
        }
        let matches = candidates.filter { $0.xLabel == category }
        applySelection(matches, label: category)
    }

    private func select(categoryIdentity: String?) {
        guard let categoryIdentity else {
            selection = nil
            return
        }
        let matches = data.filter { $0.xIdentity == categoryIdentity }
        applySelection(
            matches,
            label: matches.first?.xLabel ?? categoryIdentity)
    }

    private func select(heatmapXIdentity: String, yIdentity: String) {
        guard
            let match = data.first(where: {
                $0.xIdentity == heatmapXIdentity && $0.yIdentity == yIdentity
            })
        else { return }
        let label = [match.xLabel, match.yLabel].compactMap { $0 }.joined(separator: ", ")
        applySelection([match], label: label)
    }

    private func select(date: Date?) {
        select(date: date, in: data)
    }

    private func select(date: Date?, in candidates: [AutoChartDatum]) {
        guard let date else {
            selection = nil
            return
        }
        guard
            let nearest = candidates.min(by: {
                abs(($0.xDate ?? .distantPast).timeIntervalSince(date))
                    < abs(($1.xDate ?? .distantPast).timeIntervalSince(date))
            })
        else { return }
        applySelection([nearest], label: nearest.accessibilityLabel)
    }

    private func select(number: Double?) {
        select(number: number, in: data)
    }

    private func select(number: Double?, in candidates: [AutoChartDatum]) {
        guard let number else {
            selection = nil
            return
        }
        guard
            let nearest = candidates.filter({ !$0.sourceRowIDs.isEmpty }).min(by: {
                abs(($0.xNumber ?? 0) - number) < abs(($1.xNumber ?? 0) - number)
            })
        else { return }
        applySelection([nearest], label: nearest.accessibilityLabel)
    }

    private func select(angle: Double?) {
        guard let angle else {
            selection = nil
            return
        }
        var cumulative = 0.0
        for datum in data {
            cumulative += datum.yNumber ?? 0
            if angle <= cumulative {
                applySelection([datum], label: datum.xLabel ?? datum.accessibilityLabel)
                return
            }
        }
    }

    private func applySelection(_ matches: [AutoChartDatum], label: String) {
        let rowIDs = matches.reduce(into: Set<AutoChartRowID>()) {
            $0.formUnion($1.sourceRowIDs)
        }
        let value = matches.compactMap(\.yNumber).reduce(0, +)
        let numericValues = matches.compactMap(\.yNumber)
        let valueDescription =
            numericValues.isEmpty
            ? "\(rowIDs.count) source row\(rowIDs.count == 1 ? "" : "s")"
            : "\(value.formatted(.number.precision(.fractionLength(0...3)))) · \(rowIDs.count) source row\(rowIDs.count == 1 ? "" : "s")"
        selection = AutoChartSelection(
            sourceRowIDs: rowIDs,
            label: label,
            valueDescription: valueDescription)
    }

    private func clearSelection() {
        selectedCategory = nil
        selectedDate = nil
        selectedNumber = nil
        selectedAngle = nil
        selection = nil
    }

    private func resetInteractionState() {
        clearSelection()
        zoomScale = 1
        zoomAnchor = 1
    }
}
#endif
