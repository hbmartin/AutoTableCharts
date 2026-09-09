#if canImport(SwiftUI) && canImport(Charts)
import Foundation
import SwiftUI
import Charts
import AutoTableCharts

/// Bounded, source-snapshot-free memoization for the synchronous convenience
/// initializers. Sessions may still inject their own presenter.
private let autoChartConveniencePresenter = AutoChartPresenter()

#if os(macOS)
import AppKit
#endif

private enum AutoChartFacetLayout {
    static let minimumTileWidth: CGFloat = 220
    static let spacing: CGFloat = 16
}

private enum AutoChartFacetSelectionAxis {
    case x
    case y
}

enum AutoChartMeasureFormattingSurface {
    case axisTick
    case markAccessibility
}

@usableFromInline
enum AutoChartDefaultPlotHeight {
    @usableFromInline static let explorer: CGFloat = 280
    @usableFromInline static let plotOnly: CGFloat = 180
}

public struct AutoChartChrome: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let title = AutoChartChrome(rawValue: 1 << 0)
    public static let diagnostics = AutoChartChrome(rawValue: 1 << 1)
    public static let selectionSummary = AutoChartChrome(rawValue: 1 << 2)
    public static let zoomControls = AutoChartChrome(rawValue: 1 << 3)
    public static let all: AutoChartChrome = [.title, .diagnostics, .selectionSummary, .zoomControls]
}

public struct AutoChartInteractions: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let selection = AutoChartInteractions(rawValue: 1 << 0)
    public static let scrolling = AutoChartInteractions(rawValue: 1 << 1)
    public static let zoom = AutoChartInteractions(rawValue: 1 << 2)
    public static let all: AutoChartInteractions = [.selection, .scrolling, .zoom]
}

public enum AutoChartTypography: String, Hashable, Codable, Sendable {
    case compact
    case standard
}

public struct AutoChartPresentation: Hashable, Sendable {
    /// The exact plot-region height. Pass `nil` only when the surrounding layout
    /// supplies a bounded height; the standard presentation defaults to 280 points.
    public var plotHeight: CGFloat?
    public var chrome: AutoChartChrome
    public var interactions: AutoChartInteractions
    public var typography: AutoChartTypography

    public init(
        plotHeight: CGFloat? = AutoChartDefaultPlotHeight.explorer,
        chrome: AutoChartChrome = .all,
        interactions: AutoChartInteractions = .all,
        typography: AutoChartTypography = .standard
    ) {
        self.plotHeight = plotHeight
        self.chrome = chrome
        self.interactions = interactions
        self.typography = typography
    }

    public static func preview(plotHeight: CGFloat) -> Self {
        Self(
            plotHeight: plotHeight,
            chrome: [.diagnostics],
            interactions: [],
            typography: .compact)
    }

    /// Creates the standard interactive presentation, 280 points tall by default.
    public static func explorer(
        plotHeight: CGFloat? = AutoChartDefaultPlotHeight.explorer
    ) -> Self {
        Self(plotHeight: plotHeight)
    }
}

private enum AutoChartViewContent<RowID: Hashable & Sendable>: Sendable {
    case chart(AutoChartPreparedChart<RowID>, AutoChartResolvedPresentation)
    case fallback(AutoChartFallback)
}

struct AutoChartKPIContent: View {
    let valueText: String
    let title: String
    let isCompact: Bool
    let accessibilityText: String

    init(presented: AutoChartPresentedKPI, typography: AutoChartTypography) {
        valueText = presented.valueText
        title = presented.title
        isCompact = typography == .compact
        accessibilityText = presented.accessibilityText
    }

    init<RowID: Hashable & Sendable>(
        preparedChart: AutoChartPreparedChart<RowID>,
        typography: AutoChartTypography,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) {
        let core = preparedChart.core
        let semantics = core.measureSemantics
        let column = semantics.columnID.flatMap { core.table.profiles[$0]?.column }
        let resolvedValueText: String
        if let value = core.data.first?.ySourceValue {
            resolvedValueText = formatters.format(
                AutoChartFormattingRequest(
                    column: column,
                    value: value,
                    context: .kpi,
                    purpose: semantics.formattingPurpose))
        } else {
            assertionFailure("Prepared KPI charts require one source measure value.")
            resolvedValueText = AutoChartValue.unrepresentableValuePlaceholder
        }
        let resolvedTitle = core.presentation.resolvedYTitle(using: textResolver)
        valueText = resolvedValueText
        title = resolvedTitle
        isCompact = typography == .compact
        accessibilityText = AutoChartAccessibility.kpiLabel(
            title: resolvedTitle,
            valueDescription: resolvedValueText,
            textResolver: textResolver)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(valueText)
                .font(
                    .system(
                        size: isCompact ? 34 : 52, weight: .bold, design: .rounded
                    )
                )
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// Convenience composition of a prepared plot and optional package chrome.
public struct AutoChartView<RowID: Hashable & Sendable>: View {
    private let content: AutoChartViewContent<RowID>
    private let displayTitle: String
    private let presentation: AutoChartPresentation
    private let formatters: AutoChartFormatters
    private let textResolver: AutoChartTextResolver
    private let renderedData: [AutoChartDatum]
    private let facetPanels: [AutoChartFacetPanel]
    private let sharedXCategoryDomain: [String]
    private let presentedKPI: AutoChartPresentedKPI?
    private let analysisID: AutoChartAnalysisID
    @Binding private var selection: AutoChartSelectionSet<RowID>

    @State private var selectedCategory: String?
    @State private var selectedDate: Date?
    @State private var selectedNumber: Double?
    @State private var selectedAngle: Double?
    @State private var pendingCategorySynchronization: String?? = nil
    @State private var pendingDateSynchronization: Date?? = nil
    @State private var pendingNumberSynchronization: Double?? = nil
    @State private var pendingAngleSynchronization: Double?? = nil
    @State private var zoomScale = 1.0
    @State private var zoomAnchor = 1.0
    @Environment(\.autoChartPalette) private var palette
    @Environment(\.autoChartTheme) private var theme

    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        let presented = autoChartConveniencePresenter.present(
            preparedChart,
            context: AutoChartPresentationContext(
                locale: formatters.locale,
                timeZone: formatters.timeZone),
            formatters: formatters,
            textResolver: textResolver)
        content = .chart(preparedChart, presented.resolvedPresentation)
        displayTitle = presented.title
        renderedData = presented.renderedData
        facetPanels = presented.facetPanels
        sharedXCategoryDomain = presented.sharedXCategoryDomain
        presentedKPI = presented.kpi
        self.analysisID = analysisID
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters
        self.textResolver = textResolver
    }

    /// Renders presentation work already memoized by ``AutoChartPresenter``.
    public init(
        presentedChart: AutoChartPresentedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver? = nil
    ) {
        content = .chart(
            presentedChart.preparedChart,
            presentedChart.resolvedPresentation)
        displayTitle = presentedChart.title
        renderedData = presentedChart.renderedData
        facetPanels = presentedChart.facetPanels
        sharedXCategoryDomain = presentedChart.sharedXCategoryDomain
        presentedKPI = presentedChart.kpi
        self.analysisID = analysisID
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters ?? presentedChart.formatters
        self.textResolver = textResolver ?? presentedChart.textResolver
    }

    public init(
        analysis: AutoChartAnalysis<RowID>,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        if let primary = analysis.primaryChart {
            let presented = autoChartConveniencePresenter.present(
                primary,
                context: AutoChartPresentationContext(
                    locale: formatters.locale,
                    timeZone: formatters.timeZone),
                formatters: formatters,
                textResolver: textResolver)
            content = .chart(primary, presented.resolvedPresentation)
            displayTitle = presented.title
            renderedData = presented.renderedData
            facetPanels = presented.facetPanels
            sharedXCategoryDomain = presented.sharedXCategoryDomain
            presentedKPI = presented.kpi
        } else if case .tableFallback(let fallback) = analysis.outcome {
            content = .fallback(fallback)
            displayTitle = ""
            renderedData = []
            facetPanels = []
            sharedXCategoryDomain = []
            presentedKPI = nil
        } else {
            content = .fallback(
                AutoChartFallback(
                    message: AutoChartMessage(
                        category: .fallback,
                        code: .noSafeChart,
                        defaultText: "No prepared chart is available.")))
            displayTitle = ""
            renderedData = []
            facetPanels = []
            sharedXCategoryDomain = []
            presentedKPI = nil
        }
        analysisID = analysis.id
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters
        self.textResolver = textResolver
    }

    private var preparedChart: AutoChartPreparedChart<RowID> {
        guard case .chart(let chart, _) = content else {
            preconditionFailure("No chart content")
        }
        return chart
    }
    private var resolvedPresentation: AutoChartResolvedPresentation {
        guard case .chart(_, let presentation) = content else {
            preconditionFailure("No chart presentation")
        }
        return presentation
    }
    private var snapshot: AutoChartSnapshot { preparedChart.core.snapshot }
    private var recommendation: AutoChartRecommendation { preparedChart.recommendation }
    private var validation: AutoChartValidationResult { preparedChart.validation }
    private var data: [AutoChartDatum] { renderedData }
    private var renderPresentation: AutoChartRenderPresentation { preparedChart.core.presentation }
    private var sizeBounds: (minimum: Double, maximum: Double)? { renderPresentation.sizeBounds }
    private var sharedYDomain: ClosedRange<Double>? { renderPresentation.sharedYDomain }
    private var sharedXDateDomain: ClosedRange<Date>? { renderPresentation.sharedXDateDomain }
    private var sharedXNumberDomain: ClosedRange<Double>? { renderPresentation.sharedXNumberDomain }
    private var facetBaseFamily: AutoChartFamily? { renderPresentation.facetBaseFamily }
    private var snapshotFingerprint: Int { preparedChart.core.fingerprint }
    private var xTitle: String { resolvedPresentation.x }
    private var yTitle: String { resolvedPresentation.y }
    private var seriesTitle: String { resolvedPresentation.series }
    private var facetTitle: String { resolvedPresentation.facet }
    private var countTitle: String { resolvedPresentation.count }
    private var medianTitle: String { resolvedPresentation.median }
    private var rangeStartTitle: String { resolvedPresentation.rangeStart }
    private var rangeEndTitle: String { resolvedPresentation.rangeEnd }
    private var dateTitle: String { resolvedPresentation.date }
    private var xSemanticType: AutoChartSemanticType? { renderPresentation.xSemanticType }
    private var xDisplayLabels: [String: String] { resolvedPresentation.xDisplayLabels }
    private var yDisplayLabels: [String: String] { resolvedPresentation.yDisplayLabels }
    private var seriesDisplayLabels: [String: String] { resolvedPresentation.seriesDisplayLabels }
    private var facetDisplayLabels: [String: String] { resolvedPresentation.facetDisplayLabels }
    private var xCategoryCount: Int { renderPresentation.xCategoryCount }
    private var timeZoomValueCount: Int { renderPresentation.timeZoomValueCount }
    private var timeZoomSpan: TimeInterval { renderPresentation.timeZoomSpan }
    private var numberZoomValueCount: Int { renderPresentation.numberZoomValueCount }
    private var numberZoomSpan: Double { renderPresentation.numberZoomSpan }
    private var specification: AutoChartSpecification { recommendation.specification }
    private var isCompact: Bool { presentation.typography == .compact }
    private var interactions: AutoChartInteractions { presentation.interactions }

    private func resolvedColumn(_ id: AutoChartColumnID?) -> AutoChartColumn? {
        id.flatMap { preparedChart.core.table.profiles[$0]?.column }
    }

    private var renderedMeasureSemantics: AutoChartRenderedMeasureSemantics {
        preparedChart.core.measureSemantics
    }

    /// The source measure retained by the preparation plan. Structural row
    /// counts omit it, while raw and measure-derived values keep their lineage.
    private var sourceMeasureColumn: AutoChartColumn? {
        resolvedColumn(renderedMeasureSemantics.columnID)
    }

    @ViewBuilder
    public var body: some View {
        switch content {
        case .fallback(let fallback):
            VStack(alignment: .leading, spacing: 10) {
                ContentUnavailableView(
                    textResolver(.init(
                        category: .interface,
                        code: .chartUnavailable,
                        defaultText: "Chart unavailable")),
                    systemImage: "tablecells",
                    description: Text(textResolver(fallback.message)))
                if presentation.chrome.contains(.diagnostics) {
                    ForEach(Array(fallback.diagnostics.enumerated()), id: \.offset) {
                        _, diagnostic in
                        Label(
                            textResolver(diagnostic.messageValue),
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        case .chart:
            VStack(alignment: .leading, spacing: 10) {
            if presentation.chrome.contains(.title), !displayTitle.isEmpty {
                Text(displayTitle)
                    .font(isCompact ? theme.labelFont.weight(.semibold) : theme.titleFont)
                    .lineLimit(isCompact ? 2 : nil)
            }
            if validation.isValid {
                chartBody
                    .frame(height: presentation.plotHeight)
                if presentation.chrome.contains(.selectionSummary), let first = selection.first {
                    let summary = first.presentation(
                        columns: snapshot.columns,
                        formatters: formatters,
                        textResolver: textResolver,
                        resolvedDimensionLabel: resolvedSelectionDimensionLabel)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.label).font(theme.labelFont.weight(.semibold))
                            Text(summary.valueDescription).font(theme.labelFont).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        Button(textResolver(.init(
                            category: .interface,
                            code: .clearSelection,
                            defaultText: "Clear"))) { clearSelection() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("auto-chart-clear-selection")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(summary.accessibilityDescription)
                }
                if presentation.chrome.contains(.zoomControls), zoomScale > 1.01 {
                    Button(textResolver(.init(
                        category: .interface,
                        code: .resetZoom,
                        defaultText: "Reset Zoom")), systemImage: "arrow.counterclockwise") {
                        zoomScale = 1
                        zoomAnchor = 1
                    }
                    .font(.caption)
                    .accessibilityIdentifier("auto-chart-reset-zoom")
                }
            } else {
                // Every issue is an `AutoChartDiagnostic` carrying a coded
                // `messageValue`, so route them through the resolver rather
                // than concatenating raw `defaultText` the host cannot localize.
                ContentUnavailableView(
                    textResolver(.init(
                        category: .interface,
                        code: .chartUnavailable,
                        defaultText: "Chart unavailable")),
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        validation.issues
                            .map { textResolver($0.messageValue) }
                            .joined(separator: " ")))
            }
            if presentation.chrome.contains(.diagnostics) {
                ForEach(Array(preparedChart.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(textResolver(diagnostic.messageValue), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            displayTitle
        )
        .accessibilityIdentifier("auto-chart-\(specification.family.rawValue)")
        .foregroundStyle(theme.legendColor)
        .chartForegroundStyleScale(
            range: palette.marks.isEmpty ? theme.markColors : palette.marks)
        .onChange(of: recommendation.id) { _, _ in
            resetInteractionState()
        }
        .onChange(of: snapshotFingerprint) { _, _ in
            resetInteractionState()
        }
        .onAppear { synchronizeInteractionState(from: selection) }
        .onChange(of: selection) { _, updated in
            synchronizeInteractionState(from: updated)
        }
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch specification.family {
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
        Group {
            if let presentedKPI {
                AutoChartKPIContent(
                    presented: presentedKPI,
                    typography: presentation.typography)
            } else {
                AutoChartKPIContent(
                    preparedChart: preparedChart,
                    typography: presentation.typography,
                    formatters: formatters,
                    textResolver: textResolver)
            }
        }
    }

    @ViewBuilder
    private var barChart: some View {
        if specification.orientation == .horizontal {
            let chart = Chart(data) { datum in
                horizontalBarMark(
                    for: datum,
                    groupsSeries: specification.family == .groupedBar,
                    stacking: stackingMethod)
            }
            .chartXAxisLabel(yTitle)
            .chartYAxisLabel(xTitle)
            .chartXAxis { yNumericAxis() }
            selectableCategoryY(verticalZoom(chart, categoryCount: xCategoryCount))
        } else {
            let chart = Chart(data) { datum in
                verticalBarMark(
                    for: datum,
                    groupsSeries: specification.family == .groupedBar,
                    stacking: stackingMethod)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartYAxis { yNumericAxis() }
            selectableCategoryX(horizontalZoom(chart, categoryCount: xCategoryCount))
        }
    }

    private var rankedDotChart: some View {
        let chart = Chart(data) { datum in
            RuleMark(
                xStart: .value(yTitle, 0),
                xEnd: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .foregroundStyle(.secondary.opacity(0.45))
            .opacity(selectionOpacity(for: datum))
            PointMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .symbol(.circle)
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(yTitle)
        .chartYAxisLabel(xTitle)
        .chartXAxis { yNumericAxis() }
        return selectableCategoryY(verticalZoom(chart, categoryCount: xCategoryCount))
    }

    @ViewBuilder
    private var lineChart: some View {
        if xSemanticType == .temporal {
            let chart = Chart(data) { datum in
                lineMarks(
                    for: datum,
                    x: datum.xDate ?? .distantPast,
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartXAxis { temporalAxis(columnID: specification.encoding.x) }
            .chartYAxis { yNumericAxis() }
            .environment(\.timeZone, formatters.timeZone)
            selectableDateX(timeZoom(chart))
        } else if xSemanticType == .quantitative {
            let chart = Chart(data) { datum in
                lineMarks(
                    for: datum,
                    x: datum.xNumber ?? 0,
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartXAxis { numericAxis(columnID: specification.encoding.x) }
            .chartYAxis { yNumericAxis() }
            selectableNumberX(numberZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                lineMarks(
                    for: datum,
                    x: xCategoryValue(for: datum),
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartYAxis { yNumericAxis() }
            selectableCategoryX(horizontalZoom(chart, categoryCount: xCategoryCount))
        }
    }

    @ViewBuilder
    private var scatterChart: some View {
        if xSemanticType == .temporal {
            let chart = Chart(data) { datum in
                scatterMark(
                    for: datum,
                    x: datum.xDate ?? .distantPast,
                    symbolSize: symbolSize(for: datum.size))
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartXAxis { temporalAxis(columnID: specification.encoding.x) }
            .chartYAxis { yNumericAxis() }
            .environment(\.timeZone, formatters.timeZone)
            selectableDateX(timeZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                scatterMark(
                    for: datum,
                    x: datum.xNumber ?? 0,
                    symbolSize: symbolSize(for: datum.size))
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .chartXAxis { numericAxis(columnID: specification.encoding.x) }
            .chartYAxis { yNumericAxis() }
            selectableNumberX(numberZoom(chart))
        }
    }

    private var histogramChart: some View {
        let chart = Chart(data) { datum in
            BarMark(
                xStart: .value(xTitle, datum.lower ?? 0),
                xEnd: .value(xTitle, datum.upper ?? 0),
                y: .value(countTitle, datum.yNumber ?? 0)
            )
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel(countTitle)
        .chartXAxis { numericAxis(columnID: specification.encoding.x) }
        .chartYAxis { yNumericAxis() }
        return selectableNumberX(numberZoom(chart))
    }

    private var boxPlotChart: some View {
        let chart = Chart(data) { datum in
            RuleMark(
                x: .value(xTitle, xCategoryValue(for: datum)),
                yStart: .value(yTitle, datum.lower ?? 0),
                yEnd: .value(yTitle, datum.upper ?? 0))
            .opacity(selectionOpacity(for: datum))
            BarMark(
                x: .value(xTitle, xCategoryValue(for: datum)),
                yStart: .value(yTitle, datum.quartile1 ?? 0),
                yEnd: .value(yTitle, datum.quartile3 ?? 0),
                width: .fixed(28))
            .opacity(selectionOpacity(for: datum))
            PointMark(
                x: .value(xTitle, xCategoryValue(for: datum)),
                y: .value(medianTitle, datum.median ?? 0)
            )
            .symbol(.square)
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel(yTitle)
        .chartYAxis { yNumericAxis() }
        return selectableCategoryX(horizontalZoom(chart, categoryCount: xCategoryCount))
    }

    private var heatmapChart: some View {
        let xLabels = xDisplayLabels
        let yLabels = yDisplayLabels
        let chart = Chart(data) { datum in
            RectangleMark(
                x: .value(xTitle, datum.xIdentity ?? ""),
                y: .value(yTitle, datum.yIdentity ?? "")
            )
            .foregroundStyle(by: .value(countTitle, datum.yNumber ?? 0))
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(heatmapAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(xTitle)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(theme.axisColor.opacity(0.24))
                AxisTick().foregroundStyle(theme.axisColor)
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(xLabels[identity] ?? identity)
                    }
                }.foregroundStyle(theme.axisColor)
            }
        }
        .chartYAxisLabel(yTitle)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(theme.axisColor.opacity(0.24))
                AxisTick().foregroundStyle(theme.axisColor)
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(yLabels[identity] ?? identity)
                    }
                }.foregroundStyle(theme.axisColor)
            }
        }
        return selectableHeatmap(horizontalZoom(chart, categoryCount: xCategoryCount))
    }

    private var donutChart: some View {
        let chart = Chart(data) { datum in
            SectorMark(
                angle: .value(yTitle, datum.yNumber ?? 0),
                innerRadius: .ratio(0.56),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value(xTitle, xCategoryValue(for: datum)))
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            .annotation(position: .overlay) {
                Text(xCategoryValue(for: datum))
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
                xStart: .value(rangeStartTitle, datum.startDate ?? .distantPast),
                xEnd: .value(rangeEndTitle, datum.endDate ?? .distantPast),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if datum.startDate == datum.endDate {
                PointMark(
                    x: .value(dateTitle, datum.startDate ?? .distantPast),
                    y: .value(xTitle, xCategoryValue(for: datum))
                )
                .symbol(.diamond)
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        }
        .chartXAxisLabel(dateTitle)
        .chartYAxisLabel(xTitle)
        .chartXAxis { temporalAxis(columnID: specification.encoding.start) }
        .environment(\.timeZone, formatters.timeZone)
        return selectableCategoryY(timeZoom(chart))
    }

    @ChartContentBuilder
    private func horizontalBarMark(
        for datum: AutoChartDatum,
        groupsSeries: Bool,
        stacking: MarkStackingMethod
    ) -> some ChartContent {
        styledBarMark(
            BarMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum)),
                stacking: groupsSeries ? .unstacked : stacking),
            for: datum,
            groupsSeries: groupsSeries)
    }

    @ChartContentBuilder
    private func verticalBarMark(
        for datum: AutoChartDatum,
        groupsSeries: Bool,
        stacking: MarkStackingMethod
    ) -> some ChartContent {
        styledBarMark(
            BarMark(
                x: .value(xTitle, xCategoryValue(for: datum)),
                y: .value(yTitle, datum.yNumber ?? 0),
                stacking: groupsSeries ? .unstacked : stacking),
            for: datum,
            groupsSeries: groupsSeries)
    }

    @ChartContentBuilder
    private func styledBarMark(
        _ mark: BarMark,
        for datum: AutoChartDatum,
        groupsSeries: Bool
    ) -> some ChartContent {
        if groupsSeries {
            mark
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .position(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else if specification.encoding.series != nil {
            mark
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else {
            mark
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
    }

    @ChartContentBuilder
    private func lineMarks<X: Plottable>(
        for datum: AutoChartDatum,
        x: X,
        includesArea: Bool,
        includesPoint: Bool
    ) -> some ChartContent {
        if specification.encoding.series != nil {
            if includesArea {
                AreaMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(0.45 * selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            LineMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0),
                series: .value(seriesTitle, seriesValue(for: datum))
            )
            .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
            .lineStyle(by: .value(seriesTitle, seriesValue(for: datum)))
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if includesPoint {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        } else {
            if includesArea {
                AreaMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    stacking: .unstacked
                )
                .opacity(0.45 * selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            LineMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if includesPoint {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        }
    }

    @ChartContentBuilder
    private func scatterMark<X: Plottable>(
        for datum: AutoChartDatum,
        x: X,
        symbolSize: Double? = nil
    ) -> some ChartContent {
        if specification.encoding.series != nil {
            if let symbolSize {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize)
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            } else {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        } else if let symbolSize {
            PointMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .symbolSize(symbolSize)
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else {
            PointMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .opacity(selectionOpacity(for: datum))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
    }

    private var facetedChart: some View {
        return Group {
            if let plotHeight = presentation.plotHeight {
                GeometryReader { geometry in
                    facetGrid(
                        panels: facetPanels,
                        tileHeight: facetTileHeight(
                            totalHeight: plotHeight,
                            availableWidth: geometry.size.width,
                            panelCount: facetPanels.count))
                }
            } else {
                facetGrid(panels: facetPanels, tileHeight: 180)
            }
        }
    }

    /// Divides the requested total plot height among the grid rows the panels
    /// occupy at the given width, with a floor that keeps panels legible.
    private func facetTileHeight(
        totalHeight: CGFloat,
        availableWidth: CGFloat,
        panelCount: Int
    ) -> CGFloat {
        guard panelCount > 0 else { return totalHeight }
        let captionAllowance: CGFloat = 20
        let columns = max(
            1,
            Int(
                (availableWidth + AutoChartFacetLayout.spacing)
                    / (AutoChartFacetLayout.minimumTileWidth + AutoChartFacetLayout.spacing)))
        let rows = max(1, Int(ceil(Double(panelCount) / Double(columns))))
        let chrome =
            CGFloat(rows - 1) * AutoChartFacetLayout.spacing
            + CGFloat(rows) * captionAllowance
        return max(120, (totalHeight - chrome) / CGFloat(rows))
    }

    private func facetGrid(
        panels: [AutoChartFacetPanel],
        tileHeight: CGFloat
    ) -> some View {
        let yDomain = sharedYDomain ?? 0...1
        let dateDomain =
            sharedXDateDomain
            ?? Date.distantPast...Date.distantFuture
        let numberDomain = sharedXNumberDomain ?? 0...1
        return ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: AutoChartFacetLayout.minimumTileWidth),
                        spacing: AutoChartFacetLayout.spacing)
                ],
                spacing: AutoChartFacetLayout.spacing
            ) {
                ForEach(panels, id: \.key) { panel in
                    let facetData = panel.data
                    VStack(alignment: .leading, spacing: 4) {
                        Text(panel.displayValue)
                            .font(.caption.weight(.semibold))
                        if facetBaseFamily == .line, xSemanticType == .temporal {
                            let chart = Chart(facetData) { datum in
                                lineMarks(
                                    for: datum,
                                    x: datum.xDate ?? .distantPast,
                                    includesArea: false,
                                    includesPoint: true)
                            }
                            .chartXScale(domain: dateDomain)
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, formatters.timeZone)
                            selectableFacet(chart, axis: .x, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                            .frame(height: tileHeight)
                        } else if facetBaseFamily == .line {
                            let chart = Chart(facetData) { datum in
                                lineMarks(
                                    for: datum,
                                    x: xCategoryValue(for: datum),
                                    includesArea: false,
                                    includesPoint: true)
                            }
                            .chartXScale(domain: sharedXCategoryDomain)
                            .chartYScale(domain: yDomain)
                            selectableFacet(chart, axis: .x, as: String.self) { value in
                                select(category: value, in: facetData)
                            }
                            .frame(height: tileHeight)
                        } else if facetBaseFamily == .scatter,
                            xSemanticType == .temporal
                        {
                            let chart = Chart(facetData) { datum in
                                scatterMark(
                                    for: datum,
                                    x: datum.xDate ?? .distantPast)
                            }
                            .chartXScale(domain: dateDomain)
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, formatters.timeZone)
                            selectableFacet(chart, axis: .x, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                            .frame(height: tileHeight)
                        } else if facetBaseFamily == .scatter {
                            let chart = Chart(facetData) { datum in
                                scatterMark(
                                    for: datum,
                                    x: datum.xNumber ?? 0)
                            }
                            .chartXScale(domain: numberDomain)
                            .chartYScale(domain: yDomain)
                            selectableFacet(chart, axis: .x, as: Double.self) { value in
                                select(number: value, in: facetData)
                            }
                            .frame(height: tileHeight)
                        } else {
                            if specification.orientation == .horizontal {
                                let chart = Chart(facetData) { datum in
                                    horizontalBarMark(
                                        for: datum,
                                        groupsSeries: specification.encoding.series != nil,
                                        stacking: .standard)
                                }
                                .chartXScale(domain: yDomain)
                                .chartYScale(domain: sharedXCategoryDomain)
                                selectableFacet(chart, axis: .y, as: String.self) { value in
                                    select(category: value, in: facetData)
                                }
                                .frame(height: tileHeight)
                            } else {
                                let chart = Chart(facetData) { datum in
                                    verticalBarMark(
                                        for: datum,
                                        groupsSeries: specification.encoding.series != nil,
                                        stacking: .standard)
                                }
                                .chartXScale(domain: sharedXCategoryDomain)
                                .chartYScale(domain: yDomain)
                                selectableFacet(chart, axis: .x, as: String.self) { value in
                                    select(category: value, in: facetData)
                                }
                                .frame(height: tileHeight)
                            }
                        }
                    }
                }
            }
        }
    }

    private func xCategoryValue(for datum: AutoChartDatum) -> String {
        disambiguatedCategoryValue(
            identity: datum.xIdentity,
            label: datum.xLabel,
            labels: xDisplayLabels,
            fallback: resolvedPresentation.missingValue)
    }

    private func seriesValue(for datum: AutoChartDatum) -> String {
        guard specification.encoding.series != nil else { return seriesTitle }
        return disambiguatedCategoryValue(
            identity: datum.seriesIdentity,
            label: datum.series,
            labels: seriesDisplayLabels,
            fallback: resolvedPresentation.missingSeries)
    }

    private func facetValue(for datum: AutoChartDatum) -> String {
        disambiguatedCategoryValue(
            identity: datum.facetIdentity,
            label: datum.facet,
            labels: facetDisplayLabels,
            fallback: resolvedPresentation.missingFacet)
    }

    private func accessibilityXCategoryValue(for datum: AutoChartDatum) -> String {
        categoryValueForSurface(
            identity: datum.xIdentity,
            value: datum.xCategoryValue,
            label: datum.xLabel,
            labels: xDisplayLabels,
            fallback: resolvedPresentation.missingValue,
            column: resolvedColumn(specification.encoding.x),
            context: .markAccessibility,
            formatters: formatters)
    }

    private func accessibilitySeriesValue(for datum: AutoChartDatum) -> String {
        categoryValueForSurface(
            identity: datum.seriesIdentity,
            value: datum.seriesCategoryValue,
            label: datum.series,
            labels: seriesDisplayLabels,
            fallback: resolvedPresentation.missingSeries,
            column: resolvedColumn(specification.encoding.series),
            context: .markAccessibility,
            formatters: formatters)
    }

    private func accessibilityFacetValue(for datum: AutoChartDatum) -> String {
        categoryValueForSurface(
            identity: datum.facetIdentity,
            value: datum.facetCategoryValue,
            label: datum.facet,
            labels: facetDisplayLabels,
            fallback: resolvedPresentation.missingFacet,
            column: resolvedColumn(specification.encoding.facet),
            context: .markAccessibility,
            formatters: formatters)
    }

    private func resolvedSelectionDimensionLabel(
        _ dimension: AutoChartSelectedDimension
    ) -> String? {
        let labels: [String: String]
        let missingLabel: String
        if dimension.columnID == specification.encoding.x {
            labels = xDisplayLabels
            missingLabel = resolvedPresentation.missingValue
        } else if specification.family == .heatmap,
            dimension.columnID == specification.encoding.y
        {
            labels = yDisplayLabels
            missingLabel = resolvedPresentation.missingValue
        } else if dimension.columnID == specification.encoding.series {
            labels = seriesDisplayLabels
            missingLabel = resolvedPresentation.missingSeries
        } else if dimension.columnID == specification.encoding.facet {
            labels = facetDisplayLabels
            missingLabel = resolvedPresentation.missingFacet
        } else {
            return nil
        }
        let semanticType = preparedChart.core.table.profiles[dimension.columnID]?.semanticType
        guard
            let identity = AutoChartProfiler.identity(
                dimension.value,
                semanticType: semanticType).stringValue
        else {
            return dimension.value == .null ? missingLabel : nil
        }
        return labels[identity]
    }

    private func markAccessibilityLabel(for datum: AutoChartDatum) -> String {
        let xColumn = resolvedColumn(specification.encoding.x)
        let name: String
        if specification.family == .histogram {
            name = resolvedPresentation.histogramBinAccessibilityLabel(for: datum)
        } else if [
            .bar, .groupedBar, .stackedBar, .normalizedBar, .rankedDot,
            .boxPlot, .donut, .range,
        ].contains(specification.family) {
            name = accessibilityXCategoryValue(for: datum)
        } else if let date = datum.xDate {
            name = formatters.format(
                column: xColumn, value: .date(date), context: .markAccessibility)
        } else if let number = datum.xNumber {
            name = formatters.format(
                column: xColumn, value: .double(number), context: .markAccessibility)
        } else {
            name = accessibilityXCategoryValue(for: datum)
        }
        let valueDescription: String? = {
            if specification.family == .range,
                let description = AutoChartAccessibility.rangeValueDescription(
                    for: datum,
                    measureSemantics: renderedMeasureSemantics,
                    profiles: preparedChart.core.table.profiles,
                    formatters: formatters,
                    textResolver: textResolver)
            {
                return description
            }
            let number = datum.yNumber ?? datum.median
            return number.map {
                formattedMeasureValue($0, for: .markAccessibility)
            }
        }()
        return AutoChartAccessibility.markLabel(
            name: name,
            series: specification.encoding.series == nil
                ? nil : accessibilitySeriesValue(for: datum),
            facetTitle: specification.encoding.facet == nil ? nil : facetTitle,
            facetValue: specification.encoding.facet == nil
                ? nil : accessibilityFacetValue(for: datum),
            valueDescription: valueDescription,
            textResolver: textResolver)
    }

    private func heatmapAccessibilityLabel(for datum: AutoChartDatum) -> String {
        let xName = disambiguatedCategoryValue(
            identity: datum.xIdentity,
            label: datum.xLabel,
            labels: xDisplayLabels,
            fallback: resolvedPresentation.missingValue)
        let yName = disambiguatedCategoryValue(
            identity: datum.yIdentity,
            label: datum.yLabel,
            labels: yDisplayLabels,
            fallback: resolvedPresentation.missingValue)
        let count = datum.yNumber.map {
            formattedMeasureValue($0, for: .markAccessibility)
        }
        return AutoChartAccessibility.heatmapLabel(
            category: xName,
            secondaryCategory: yName,
            valueDescription: count,
            textResolver: textResolver)
    }

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

    private var selectedDatumIDs: Set<String> {
        guard selection.analysisID == analysisID,
            selection.preparedChartID == preparedChart.id
        else { return [] }
        return Set(
            selection.map(\.markID))
    }

    private func selectionOpacity(for datum: AutoChartDatum) -> Double {
        let selected = selectedDatumIDs
        return selected.isEmpty || selected.contains(datum.id) ? 1 : 0.24
    }

    @AxisContentBuilder
    private func yNumericAxis() -> some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(theme.axisColor.opacity(0.24))
            AxisTick().foregroundStyle(theme.axisColor)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(formattedMeasureValue(number, for: .axisTick))
                }
            }.foregroundStyle(theme.axisColor)
        }
    }

    @AxisContentBuilder
    private func numericAxis(columnID: AutoChartColumnID?) -> some AxisContent {
        let column = resolvedColumn(columnID)
        AxisMarks { value in
            AxisGridLine().foregroundStyle(theme.axisColor.opacity(0.24))
            AxisTick().foregroundStyle(theme.axisColor)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(
                        formatters.format(
                            column: column,
                            value: .double(number),
                            context: .axisTick))
                }
            }.foregroundStyle(theme.axisColor)
        }
    }

    func formattedMeasureValue(
        _ number: Double,
        for surface: AutoChartMeasureFormattingSurface
    ) -> String {
        let context: AutoChartFormattingContext
        let normalizedFraction: Bool
        switch surface {
        case .axisTick:
            context = .axisTick
            normalizedFraction = renderedMeasureSemantics.usesNormalizedMeasureAxis
        case .markAccessibility:
            context = .markAccessibility
            normalizedFraction = false
        }
        return formattedRenderedMeasure(
            .double(number),
            context: context,
            normalizedFraction: normalizedFraction)
    }

    private func formattedRenderedMeasure(
        _ value: AutoChartValue,
        context: AutoChartFormattingContext,
        normalizedFraction: Bool
    ) -> String {
        let purpose: AutoChartFormattingPurpose = normalizedFraction
            ? .normalizedFraction(renderedMeasureSemantics.aggregation)
            : renderedMeasureSemantics.formattingPurpose
        return formatters.format(
            AutoChartFormattingRequest(
                column: sourceMeasureColumn,
                value: value,
                context: context,
                purpose: purpose))
    }

    @AxisContentBuilder
    private func temporalAxis(columnID: AutoChartColumnID?) -> some AxisContent {
        let column = resolvedColumn(columnID)
        AxisMarks { value in
            AxisGridLine().foregroundStyle(theme.axisColor.opacity(0.24))
            AxisTick().foregroundStyle(theme.axisColor)
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(
                        formatters.format(
                            column: column,
                            value: .date(date),
                            context: .axisTick))
                }
            }.foregroundStyle(theme.axisColor)
        }
    }

    @ViewBuilder
    private func selectableCategoryX<Content: View>(_ content: Content) -> some View {
        if interactions.contains(.selection) {
            content
                .chartXSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in
                    handleCategorySelectionChange(value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableCategoryY<Content: View>(_ content: Content) -> some View {
        if interactions.contains(.selection) {
            content
                .chartYSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in
                    handleCategorySelectionChange(value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableHeatmap<Content: View>(_ content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        if interactions.contains(.selection) {
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
        #endif
    }

    @ViewBuilder
    private func selectableFacet<Content: View, Value: Plottable>(
        _ content: Content,
        axis: AutoChartFacetSelectionAxis,
        as _: Value.Type,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        #if os(tvOS)
        content
        #else
        if interactions.contains(.selection) {
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
                                guard location.x >= 0, location.x <= frame.width,
                                    location.y >= 0, location.y <= frame.height
                                else { return }
                                let selected: Value? =
                                    switch axis {
                                    case .x: proxy.value(atX: location.x)
                                    case .y: proxy.value(atY: location.y)
                                    }
                                guard let selected else { return }
                                onSelect(selected)
                            })
                }
            }
        } else {
            content
        }
        #endif
    }

    @ViewBuilder
    private func selectableDateX<Content: View>(_ content: Content) -> some View {
        if interactions.contains(.selection) {
            content
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, value in
                    handleDateSelectionChange(value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableNumberX<Content: View>(_ content: Content) -> some View {
        if interactions.contains(.selection) {
            content
                .chartXSelection(value: $selectedNumber)
                .onChange(of: selectedNumber) { _, value in
                    handleNumberSelectionChange(value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableAngle<Content: View>(_ content: Content) -> some View {
        if interactions.contains(.selection) {
            content
                .chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, value in
                    handleAngleSelectionChange(value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func horizontalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interactions.contains([.scrolling, .zoom]), categoryCount > 10 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else if interactions.contains(.scrolling), categoryCount > 10 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: min(categoryCount, 10))
        } else if interactions.contains(.zoom), categoryCount > 10 {
            content
                .chartXVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale)))
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
        if interactions.contains([.scrolling, .zoom]), categoryCount > 10 {
            content
                .chartScrollableAxes(.vertical)
                .chartYVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else if interactions.contains(.scrolling), categoryCount > 10 {
            content
                .chartScrollableAxes(.vertical)
                .chartYVisibleDomain(length: min(categoryCount, 10))
        } else if interactions.contains(.zoom), categoryCount > 10 {
            content
                .chartYVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale)))
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func timeZoom<Content: View>(_ content: Content) -> some View {
        if interactions.contains([.scrolling, .zoom]), timeZoomValueCount > 12 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(86_400, timeZoomSpan / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else if interactions.contains(.scrolling), timeZoomValueCount > 12 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(86_400, timeZoomSpan))
        } else if interactions.contains(.zoom), timeZoomValueCount > 12 {
            content
                .chartXVisibleDomain(length: max(86_400, timeZoomSpan / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func numberZoom<Content: View>(_ content: Content) -> some View {
        if interactions.contains([.scrolling, .zoom]), numberZoomValueCount > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: numberZoomSpan / zoomScale)
                .simultaneousGesture(zoomGesture)
        } else if interactions.contains(.scrolling), numberZoomValueCount > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: numberZoomSpan)
        } else if interactions.contains(.zoom), numberZoomValueCount > 30 {
            content
                .chartXVisibleDomain(length: numberZoomSpan / zoomScale)
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
            selection.removeAll()
            return
        }
        let matches = candidates.filter { xCategoryValue(for: $0) == category }
        applySelection(matches)
    }

    private func select(heatmapXIdentity: String, yIdentity: String) {
        guard
            let match = data.first(where: {
                $0.xIdentity == heatmapXIdentity && $0.yIdentity == yIdentity
            })
        else {
            selection.removeAll()
            return
        }
        applySelection([match])
    }

    private func select(date: Date?) {
        select(date: date, in: data)
    }

    private func select(date: Date?, in candidates: [AutoChartDatum]) {
        guard let date else {
            selection.removeAll()
            return
        }
        let matches = AutoChartSelectionPreparation.nearestDateMatches(
            to: date,
            in: candidates)
        guard !matches.isEmpty else {
            selection.removeAll()
            return
        }
        applySelection(matches)
    }

    private func select(number: Double?) {
        select(number: number, in: data)
    }

    private func select(number: Double?, in candidates: [AutoChartDatum]) {
        guard let number else {
            selection.removeAll()
            return
        }
        let matches = AutoChartSelectionPreparation.nearestNumberMatches(
            to: number,
            in: candidates)
        guard !matches.isEmpty else {
            selection.removeAll()
            return
        }
        applySelection(matches)
    }

    private func select(angle: Double?) {
        guard let angle else {
            selection.removeAll()
            return
        }
        guard let datum = AutoChartSelectionPreparation.angleMatch(to: angle, in: data) else {
            selection.removeAll()
            return
        }
        applySelection([datum])
    }

    private func applySelection(_ matches: [AutoChartDatum]) {
        let selectedMarks = matches.compactMap { match -> AutoChartSelection<RowID>? in
            guard let sourceRowOffsets = AutoChartSelectionPreparation.sourceRowOffsets(
                for: [match])
            else { return nil }
            let semanticValues = AutoChartSelectionPreparation.semanticValues(
                for: [match],
                specification: specification,
                measureSemantics: renderedMeasureSemantics)
            return AutoChartSelection(
                analysisID: analysisID,
                preparedChartID: preparedChart.id,
                sourceRowIDs: preparedChart.rowIDs(for: sourceRowOffsets),
                dimensions: semanticValues.dimensions,
                rangeDimensions: semanticValues.rangeDimensions,
                measure: semanticValues.measure,
                family: specification.family,
                specificationID: specification.id,
                markID: match.id)
        }
        guard !selectedMarks.isEmpty else {
            selection.removeAll()
            return
        }
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command) {
            for selectedMark in selectedMarks {
                selection.select(selectedMark, toggling: true)
            }
            return
        }
        #endif
        selection = AutoChartSelectionSet(selectedMarks)
    }

    private func clearSelection() {
        selectedCategory = nil
        selectedDate = nil
        selectedNumber = nil
        selectedAngle = nil
        selection.removeAll()
    }

    /// Keeps Swift Charts' transient selection bindings aligned with caller-owned state.
    private func synchronizeInteractionState(
        from selection: AutoChartSelectionSet<RowID>
    ) {
        var category: String?
        var date: Date?
        var number: Double?
        var angle: Double?
        guard let selectedMark = selection.first,
            selection.analysisID == analysisID,
            selection.preparedChartID == preparedChart.id
        else {
            synchronizeInteractionBindings(
                category: nil, date: nil, number: nil, angle: nil)
            return
        }
        guard let datum = data.first(where: { $0.id == selectedMark.markID }) else {
            synchronizeInteractionBindings(
                category: nil, date: nil, number: nil, angle: nil)
            return
        }
        switch specification.family {
        case .donut:
            guard let index = data.firstIndex(where: { $0.id == datum.id }) else { return }
            let preceding = data[..<index].compactMap(\.yNumber).reduce(0, +)
            angle = preceding + (datum.yNumber ?? 0) / 2
        case .line, .pointLine, .area, .scatter, .bubble:
            if let value = datum.xDate { date = value }
            else if let value = datum.xNumber { number = value }
            else { category = xCategoryValue(for: datum) }
        case .histogram:
            number = datum.xNumber
                ?? datum.lower.flatMap { lower in datum.upper.map { (lower + $0) / 2 } }
        default:
            category = xCategoryValue(for: datum)
        }
        synchronizeInteractionBindings(
            category: category, date: date, number: number, angle: angle)
    }

    private func handleCategorySelectionChange(_ value: String?) {
        if let expected = pendingCategorySynchronization, expected == value {
            pendingCategorySynchronization = nil
            return
        }
        pendingCategorySynchronization = nil
        select(category: value)
    }

    private func handleDateSelectionChange(_ value: Date?) {
        if let expected = pendingDateSynchronization, expected == value {
            pendingDateSynchronization = nil
            return
        }
        pendingDateSynchronization = nil
        select(date: value)
    }

    private func handleNumberSelectionChange(_ value: Double?) {
        if let expected = pendingNumberSynchronization, expected == value {
            pendingNumberSynchronization = nil
            return
        }
        pendingNumberSynchronization = nil
        select(number: value)
    }

    private func handleAngleSelectionChange(_ value: Double?) {
        if let expected = pendingAngleSynchronization, expected == value {
            pendingAngleSynchronization = nil
            return
        }
        pendingAngleSynchronization = nil
        select(angle: value)
    }

    private func synchronizeInteractionBindings(
        category: String?,
        date: Date?,
        number: Double?,
        angle: Double?
    ) {
        if selectedCategory != category {
            pendingCategorySynchronization = .some(category)
            selectedCategory = category
        }
        if selectedDate != date {
            pendingDateSynchronization = .some(date)
            selectedDate = date
        }
        if selectedNumber != number {
            pendingNumberSynchronization = .some(number)
            selectedNumber = number
        }
        if selectedAngle != angle {
            pendingAngleSynchronization = .some(angle)
            selectedAngle = angle
        }
    }

    private func resetInteractionState() {
        clearSelection()
        zoomScale = 1
        zoomAnchor = 1
    }
}

/// Plot-only rendering for a prepared chart.
///
/// The plot defaults to a 180-point height so it remains visible in unbounded
/// containers such as a vertical `ScrollView`. Pass `nil` when the host supplies
/// a bounded height through its surrounding layout.
public struct AutoChartPlot<RowID: Hashable & Sendable>: View {
    private let chart: AutoChartPreparedChart<RowID>
    private let analysisID: AutoChartAnalysisID
    private let selection: Binding<AutoChartSelectionSet<RowID>>
    private let plotHeight: CGFloat?
    private let interactions: AutoChartInteractions
    private let formatters: AutoChartFormatters
    private let textResolver: AutoChartTextResolver

    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        plotHeight: CGFloat? = AutoChartDefaultPlotHeight.plotOnly,
        interactions: AutoChartInteractions = .all,
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        self.chart = preparedChart
        self.analysisID = analysisID
        self.selection = selection
        self.plotHeight = plotHeight
        self.interactions = interactions
        self.formatters = formatters
        self.textResolver = textResolver
    }

    public var body: some View {
        AutoChartView(
            preparedChart: chart,
            analysisID: analysisID,
            selection: selection,
            presentation: AutoChartPresentation(
                plotHeight: plotHeight,
                chrome: [],
                interactions: interactions),
            formatters: formatters,
            textResolver: textResolver)
    }
}
#endif
