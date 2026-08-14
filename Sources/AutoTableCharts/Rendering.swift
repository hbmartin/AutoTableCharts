import Charts
import SwiftUI

struct AutoChartDatum: Identifiable, Sendable {
    var id: String
    var sourceRowIDs: Set<AutoChartRowID>
    var xLabel: String?
    var xNumber: Double?
    var xDate: Date?
    var yLabel: String?
    var yNumber: Double?
    var series: String?
    var size: Double?
    var facet: String?
    var startDate: Date?
    var endDate: Date?
    var lower: Double?
    var quartile1: Double?
    var median: Double?
    var quartile3: Double?
    var upper: Double?

    var accessibilityLabel: String {
        let name = xLabel ?? xDate?.formatted(date: .abbreviated, time: .omitted)
            ?? xNumber?.formatted() ?? yLabel ?? "Value"
        let value = yNumber?.formatted(.number.precision(.fractionLength(0...3)))
            ?? median?.formatted(.number.precision(.fractionLength(0...3))) ?? ""
        return value.isEmpty ? name : "\(name), \(value)"
    }
}

enum AutoChartDataPreparation {
    static func data(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        switch specification.family {
        case .histogram:
            return histogram(snapshot: snapshot, specification: specification)
        case .boxPlot:
            return boxPlot(snapshot: snapshot, specification: specification)
        case .heatmap:
            return heatmap(snapshot: snapshot, specification: specification)
        case .donut:
            return grouped(snapshot: snapshot, specification: specification, forceSum: true)
        default:
            if specification.aggregation != .none {
                return grouped(snapshot: snapshot, specification: specification, forceSum: false)
            }
            return sorted(
                raw(snapshot: snapshot, specification: specification),
                specification: specification)
        }
    }

    private static func raw(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        let encoding = specification.encoding
        let profiles = Dictionary(
            uniqueKeysWithValues: AutoChartProfiler.profiles(snapshot).map {
                ($0.column.id, $0.semanticType)
            })
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
                let isRenderable: Bool = switch profiles[x] {
                case .temporal: xValue.flatMap(AutoChartProfiler.dateValue) != nil
                case .quantitative: xValue?.numericValue != nil
                default: xValue?.categoryString() != nil
                }
                guard isRenderable else { return nil }
            }
            if specification.family != .table,
                specification.family != .kpi,
                encoding.y != nil,
                yValue?.numericValue == nil
            { return nil }
            return AutoChartDatum(
                id: "row-\(index)-\(row.id.rawValue)",
                sourceRowIDs: [row.id],
                xLabel: xValue?.categoryString(),
                xNumber: xValue?.numericValue,
                xDate: xValue.flatMap(AutoChartProfiler.dateValue),
                yLabel: yValue?.categoryString(),
                yNumber: yValue?.numericValue,
                series: encoding.series.flatMap { row.values[$0]?.categoryString() },
                size: encoding.size.flatMap { row.values[$0]?.numericValue },
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
        forceSum: Bool
    ) -> [AutoChartDatum] {
        let rawData = raw(snapshot: snapshot, specification: specification)
        let groups = Dictionary(grouping: rawData.enumerated()) { indexedDatum in
            let datum = indexedDatum.element
            return GroupKey(
                x: datum.xLabel ?? datum.xDate?.ISO8601Format()
                    ?? datum.xNumber.map { String($0) } ?? "",
                series: datum.series ?? "",
                facet: datum.facet ?? "")
        }
        let aggregated = groups.sorted {
            $0.value[0].offset < $1.value[0].offset
        }.map { key, indexedGroup -> AutoChartDatum in
            let group = indexedGroup.map { $0.element }
            let values = group.compactMap { $0.yNumber }
            let aggregation = forceSum ? AutoChartAggregation.sum : specification.aggregation
            let result: Double = switch aggregation {
            case .none, .sum: values.reduce(0, +)
            case .mean: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            case .minimum: values.min() ?? 0
            case .maximum: values.max() ?? 0
            case .count: Double(group.count)
            case .countDistinct: Double(Set(values).count)
            }
            var datum = group[0]
            datum.id = "group-\(key.x)-\(key.series)-\(key.facet)"
            datum.sourceRowIDs = group.reduce(into: []) { $0.formUnion($1.sourceRowIDs) }
            datum.yNumber = result
            return datum
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
        let count = max(1, specification.binCount ?? 10)
        let width = maximum > minimum ? (maximum - minimum) / Double(count) : 1
        var bins: [[(Double, AutoChartRowID)]] = Array(repeating: [], count: count)
        for value in values {
            let rawIndex = Int((value.0 - minimum) / width)
            bins[min(max(rawIndex, 0), count - 1)].append(value)
        }
        return bins.enumerated().map { index, bin in
            let start = minimum + Double(index) * width
            let end = start + width
            return AutoChartDatum(
                id: "bin-\(index)",
                sourceRowIDs: Set(bin.map(\.1)),
                xLabel: "\(start.formatted(.number.precision(.fractionLength(0...2))))–\(end.formatted(.number.precision(.fractionLength(0...2))))",
                xNumber: start + width / 2,
                yNumber: Double(bin.count),
                lower: start,
                upper: end)
        }
    }

    private static func boxPlot(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        guard let y = specification.encoding.y else { return [] }
        let x = specification.encoding.x
        let grouped = Dictionary(grouping: snapshot.rows) { row in
            x.flatMap { row.values[$0]?.categoryString() } ?? "All"
        }
        return grouped.compactMap { label, rows in
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
                id: "box-\(label)",
                sourceRowIDs: Set(rows.map(\.id)),
                xLabel: label,
                lower: sortedValues.first,
                quartile1: quantile(0.25),
                median: quantile(0.5),
                quartile3: quantile(0.75),
                upper: sortedValues.last)
        }.sorted { $0.xLabel ?? "" < $1.xLabel ?? "" }
    }

    private static func heatmap(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x, let y = specification.encoding.y else {
            return []
        }
        struct Key: Hashable { var x: String; var y: String }
        var groups: [Key: [AutoChartSnapshot.Row]] = [:]
        for row in snapshot.rows {
            guard let xValue = row.values[x]?.categoryString(),
                let yValue = row.values[y]?.categoryString()
            else { continue }
            groups[Key(x: xValue, y: yValue), default: []].append(row)
        }
        return groups.map { key, rows in
            AutoChartDatum(
                id: "heat-\(key.x)-\(key.y)",
                sourceRowIDs: Set(rows.map(\.id)),
                xLabel: key.x,
                yLabel: key.y,
                yNumber: Double(rows.count))
        }.sorted {
            ($0.xLabel ?? "", $0.yLabel ?? "") < ($1.xLabel ?? "", $1.yLabel ?? "")
        }
    }

    private static func sorted(
        _ data: [AutoChartDatum],
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        switch specification.sort {
        case .source: data
        case .ascending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") < ($1.yNumber ?? 0, $1.xLabel ?? "") }
        case .descending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") > ($1.yNumber ?? 0, $1.xLabel ?? "") }
        }
    }
}

/// A native Swift Charts view for an AutoTableCharts recommendation or specification.
///
/// The view snapshots the supplied table, prepares marks without mutating source
/// storage, validates the specification, and preserves contributing
/// ``AutoChartRowID`` values in bound selection state.
public struct AutoChartView: View {
    private let snapshot: AutoChartSnapshot
    private let recommendation: AutoChartRecommendation
    private let data: [AutoChartDatum]
    private let sizeBounds: (minimum: Double, maximum: Double)?
    private let interaction: AutoChartInteraction
    private let chartHeight: CGFloat
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
        let data = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: recommendation.specification)
        let sizes = data.compactMap(\.size).filter(\.isFinite)
        self.snapshot = snapshot
        self.recommendation = recommendation
        self.data = data
        if let minimum = sizes.min(), let maximum = sizes.max() {
            sizeBounds = (minimum, maximum)
        } else {
            sizeBounds = nil
        }
        self._selection = selection
        self.interaction = interaction
        chartHeight = height
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
        let warnings = table.chartMetadata.isTruncated
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
        let validation = AutoChartEngine.validate(
            specification: specification,
            snapshot: snapshot)
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
                            Text(selection.valueDescription).font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel(specification.title.isEmpty ? specification.family.displayName : specification.title)
        .accessibilityIdentifier("auto-chart-\(specification.family.rawValue)")
        .onChange(of: recommendation.id) { _, _ in
            clearSelection()
            zoomScale = 1
            zoomAnchor = 1
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch specification.family {
        case .table:
            ContentUnavailableView(
                "Use the table view",
                systemImage: "tablecells",
                description: Text(recommendation.rationale.first ?? "No safe chart is available."))
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
                .font(.system(size: interaction == .preview ? 34 : 52, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
            Text(specification.encoding.y.flatMap { snapshot.column($0)?.name }
                .map(AutoChartProfiler.humanized) ?? "Value")
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
                        stacking: .unstacked)
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .position(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .accessibilityLabel(datum.accessibilityLabel)
                } else {
                    BarMark(
                        x: .value(yTitle, datum.yNumber ?? 0),
                        y: .value(xTitle, datum.xLabel ?? ""),
                        stacking: stackingMethod)
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
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
                        stacking: .unstacked)
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .position(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .accessibilityLabel(datum.accessibilityLabel)
                } else {
                    BarMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: stackingMethod)
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
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
                y: .value(xTitle, datum.xLabel ?? ""))
            .foregroundStyle(.secondary.opacity(0.45))
            PointMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, datum.xLabel ?? ""))
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
                        y: .value(yTitle, datum.yNumber ?? 0))
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .opacity(0.45)
                }
                LineMark(
                    x: .value(xTitle, datum.xDate ?? .distantPast),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .lineStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xDate ?? .distantPast),
                        y: .value(yTitle, datum.yNumber ?? 0))
                    .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                    .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableDateX(timeZoom(chart))
        } else if data.contains(where: { $0.xNumber != nil }) {
            let chart = Chart(data) { datum in
                LineMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xNumber ?? 0),
                        y: .value(yTitle, datum.yNumber ?? 0))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                LineMark(
                    x: .value(xTitle, datum.xLabel ?? ""),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xLabel ?? ""),
                        y: .value(yTitle, datum.yNumber ?? 0))
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
                    y: .value(yTitle, datum.yNumber ?? 0))
                .symbolSize(symbolSize(for: datum.size))
                .foregroundStyle(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .symbol(by: .value(seriesTitle, datum.series ?? primarySeriesLabel))
                .accessibilityLabel(datum.accessibilityLabel)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableDateX(timeZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                PointMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0))
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
                y: .value("Count", datum.yNumber ?? 0))
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel("Count")
        return selectableNumberX(numberZoom(chart))
    }

    private var boxPlotChart: some View {
        let chart = Chart(data) { datum in
            RuleMark(
                x: .value(xTitle, datum.xLabel ?? "All"),
                yStart: .value(yTitle, datum.lower ?? 0),
                yEnd: .value(yTitle, datum.upper ?? 0))
            BarMark(
                x: .value(xTitle, datum.xLabel ?? "All"),
                yStart: .value(yTitle, datum.quartile1 ?? 0),
                yEnd: .value(yTitle, datum.quartile3 ?? 0),
                width: .fixed(28))
            PointMark(
                x: .value(xTitle, datum.xLabel ?? "All"),
                y: .value("Median", datum.median ?? 0))
            .symbol(.square)
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel(yTitle)
        return selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var heatmapChart: some View {
        let chart = Chart(data) { datum in
            RectangleMark(
                x: .value(xTitle, datum.xLabel ?? ""),
                y: .value(yTitle, datum.yLabel ?? ""))
            .foregroundStyle(by: .value("Count", datum.yNumber ?? 0))
            .accessibilityLabel(datum.accessibilityLabel)
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel(yTitle)
        return selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var donutChart: some View {
        let chart = Chart(data) { datum in
            SectorMark(
                angle: .value(yTitle, datum.yNumber ?? 0),
                innerRadius: .ratio(0.56),
                angularInset: 1.5)
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
                y: .value(xTitle, datum.xLabel ?? ""))
            .accessibilityLabel(datum.accessibilityLabel)
            if datum.startDate == datum.endDate {
                PointMark(
                    x: .value("Date", datum.startDate ?? .distantPast),
                    y: .value(xTitle, datum.xLabel ?? ""))
                .symbol(.diamond)
            }
        }
        .chartXAxisLabel("Date")
        .chartYAxisLabel(xTitle)
        return selectableCategoryY(timeZoom(chart))
    }

    private var facetedChart: some View {
        let facets = Dictionary(grouping: data) { $0.facet ?? "Other" }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(facets.keys.sorted(), id: \.self) { facet in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(facet).font(.caption.weight(.semibold))
                        if facets[facet]?.contains(where: { $0.xDate != nil }) == true {
                            Chart(facets[facet] ?? []) { datum in
                                LineMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0))
                                PointMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0))
                            }
                        } else if facets[facet]?.contains(where: { $0.xNumber != nil }) == true {
                            Chart(facets[facet] ?? []) { datum in
                                PointMark(
                                    x: .value(xTitle, datum.xNumber ?? 0),
                                    y: .value(yTitle, datum.yNumber ?? 0))
                            }
                        } else {
                            Chart(facets[facet] ?? []) { datum in
                                BarMark(
                                    x: .value(xTitle, datum.xLabel ?? ""),
                                    y: .value(yTitle, datum.yNumber ?? 0))
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private var xTitle: String {
        specification.encoding.x.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Category"
    }

    private var yTitle: String {
        specification.encoding.y.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Value"
    }

    private var seriesTitle: String {
        specification.encoding.series.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Series"
    }

    private var primarySeriesLabel: String { yTitle }
    private var uniqueXCount: Int { Set(data.compactMap(\.xLabel)).count }

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
            return (fractional ? numeric : numeric / 100).formatted(.percent.precision(.fractionLength(0...2)))
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
        } else { content }
    }

    @ViewBuilder
    private func selectableCategoryY<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartYSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in select(category: value) }
        } else { content }
    }

    @ViewBuilder
    private func selectableDateX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, value in select(date: value) }
        } else { content }
    }

    @ViewBuilder
    private func selectableNumberX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedNumber)
                .onChange(of: selectedNumber) { _, value in select(number: value) }
        } else { content }
    }

    @ViewBuilder
    private func selectableAngle<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, value in select(angle: value) }
        } else { content }
    }

    @ViewBuilder
    private func horizontalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale)))
                .simultaneousGesture(zoomGesture)
        } else { content }
    }

    @ViewBuilder
    private func verticalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.vertical)
                .chartYVisibleDomain(length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale)))
                .simultaneousGesture(zoomGesture)
        } else { content }
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
        } else { content }
    }

    @ViewBuilder
    private func numberZoom<Content: View>(_ content: Content) -> some View {
        let values = data.compactMap(\.xNumber)
        let span = max(1, (values.max() ?? 1) - (values.min() ?? 0))
        if interaction == .explore, values.count > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(span / 20, span / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else { content }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomScale = min(12, max(1, zoomAnchor * value.magnification))
            }
            .onEnded { _ in zoomAnchor = zoomScale }
    }

    private func select(category: String?) {
        guard let category else { selection = nil; return }
        let matches = data.filter { $0.xLabel == category || $0.yLabel == category }
        applySelection(matches, label: category)
    }

    private func select(date: Date?) {
        guard let date else { selection = nil; return }
        guard let nearest = data.min(by: {
            abs(($0.xDate ?? .distantPast).timeIntervalSince(date))
                < abs(($1.xDate ?? .distantPast).timeIntervalSince(date))
        }) else { return }
        applySelection([nearest], label: nearest.accessibilityLabel)
    }

    private func select(number: Double?) {
        guard let number else { selection = nil; return }
        guard let nearest = data.filter({ !$0.sourceRowIDs.isEmpty }).min(by: {
            abs(($0.xNumber ?? 0) - number) < abs(($1.xNumber ?? 0) - number)
        }) else { return }
        applySelection([nearest], label: nearest.accessibilityLabel)
    }

    private func select(angle: Double?) {
        guard let angle else { selection = nil; return }
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
        let valueDescription = numericValues.isEmpty
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
}
