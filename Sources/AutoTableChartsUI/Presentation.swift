import Foundation
import AutoTableCharts

/// Hashable presentation inputs used to memoize work outside SwiftUI initializers.
public struct AutoChartPresentationContext: Hashable, Codable, Sendable {
    public var identity: String
    public var localeIdentifier: String
    public var timeZoneIdentifier: String

    public init(
        identity: String = "default",
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.identity = identity
        self.localeIdentifier = locale.identifier
        self.timeZoneIdentifier = timeZone.identifier
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }
}

/// A chart whose presentation metadata has been resolved and can be rendered synchronously.
public struct AutoChartPresentedChart<RowID: Hashable & Sendable>: Sendable {
    public let preparedChart: AutoChartPreparedChart<RowID>
    public let context: AutoChartPresentationContext
    public let title: String
    public let diagnostics: [AutoChartDiagnostic]
    public let selectionSummary: String

    package let resolvedPresentation: AutoChartResolvedPresentation
    package let renderedData: [AutoChartDatum]
    package let facetPanels: [AutoChartFacetPanel]
    package let sharedXCategoryDomain: [String]
    package let kpi: AutoChartPresentedKPI?

    public var id: AutoChartPreparedChartID { preparedChart.id }

    package init(
        preparedChart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext,
        title: String,
        diagnostics: [AutoChartDiagnostic],
        selectionSummary: String,
        resolvedPresentation: AutoChartResolvedPresentation,
        renderedData: [AutoChartDatum],
        facetPanels: [AutoChartFacetPanel],
        sharedXCategoryDomain: [String],
        kpi: AutoChartPresentedKPI?
    ) {
        self.preparedChart = preparedChart
        self.context = context
        self.title = title
        self.diagnostics = diagnostics
        self.selectionSummary = selectionSummary
        self.resolvedPresentation = resolvedPresentation
        self.renderedData = renderedData
        self.facetPanels = facetPanels
        self.sharedXCategoryDomain = sharedXCategoryDomain
        self.kpi = kpi
    }
}

package struct AutoChartPresentedKPI: Sendable {
    package let valueText: String
    package let title: String
    package let accessibilityText: String
}

private struct AutoChartPresentationKey: Hashable {
    var preparedChart: AutoChartPreparedChartID
    var context: AutoChartPresentationContext
}

private final class AutoChartAnyPresentedBox: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Thread-safe presenter memoized by prepared-chart and presentation-context identity.
public final class AutoChartPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AutoChartPresentationKey: AutoChartAnyPresentedBox] = [:]

    public init() {}

    public func present<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartPresentedChart<RowID> {
        let key = AutoChartPresentationKey(preparedChart: chart.id, context: context)
        return lock.withLock {
            if let cached = entries[key]?.value as? AutoChartPresentedChart<RowID> {
                return cached
            }
            // Constructing these values here keeps localization, sorting, generated
            // histogram labels, and KPI formatting out of SwiftUI initialization.
            let formatters = formatters ?? AutoChartFormatters(
                locale: context.locale, timeZone: context.timeZone)
            let core = chart.core
            let specification = chart.recommendation.specification
            let resolved = core.presentation.resolvedPresentation(
                data: core.data,
                using: textResolver,
                formatters: formatters)
            let renderedData: [AutoChartDatum]
            if specification.family == .boxPlot {
                renderedData = orderedBoxPlotData(
                    core.data,
                    labels: resolved.xDisplayLabels,
                    fallback: resolved.missingValue,
                    locale: formatters.locale)
            } else {
                renderedData = orderedPresentedData(
                    core.data,
                    specification: specification,
                    xLabels: resolved.xDisplayLabels,
                    yLabels: resolved.yDisplayLabels,
                    missingValue: resolved.missingValue,
                    locale: formatters.locale)
            }
            let sharedXCategoryDomain = core.presentation.usesSharedXCategoryDomain
                ? resolvedXCategoryDomain(
                    in: renderedData,
                    labels: resolved.xDisplayLabels,
                    fallback: resolved.missingValue)
                : []
            let facetPanels = specification.family == .faceted
                ? orderedFacetPanels(
                    in: renderedData,
                    labels: resolved.facetDisplayLabels,
                    fallback: resolved.missingFacet,
                    locale: formatters.locale)
                : []
            let kpi: AutoChartPresentedKPI?
            if specification.family == .kpi {
                let semantics = core.measureSemantics
                let column = semantics.columnID.flatMap { core.table.profiles[$0]?.column }
                let valueText = core.data.first?.ySourceValue.map {
                    formatters.format(
                        AutoChartFormattingRequest(
                            column: column,
                            value: $0,
                            context: .kpi,
                            purpose: semantics.formattingPurpose))
                } ?? AutoChartValue.unrepresentableValuePlaceholder
                let kpiTitle = core.presentation.resolvedYTitle(using: textResolver)
                kpi = AutoChartPresentedKPI(
                    valueText: valueText,
                    title: kpiTitle,
                    accessibilityText: AutoChartAccessibility.kpiLabel(
                        title: kpiTitle,
                        valueDescription: valueText,
                        textResolver: textResolver))
            } else {
                kpi = nil
            }
            let title = chart.recommendation.specification.title.isEmpty
                ? textResolver(chart.recommendation.specification.family.localizationMessage)
                : chart.recommendation.specification.title
            let presented = AutoChartPresentedChart(
                preparedChart: chart,
                context: context,
                title: title,
                diagnostics: chart.diagnostics,
                selectionSummary: "\(chart.marks.count) chart marks",
                resolvedPresentation: resolved,
                renderedData: renderedData,
                facetPanels: facetPanels,
                sharedXCategoryDomain: sharedXCategoryDomain,
                kpi: kpi)
            entries[key] = AutoChartAnyPresentedBox(presented)
            return presented
        }
    }

    public func removeAll() {
        lock.withLock { entries.removeAll(keepingCapacity: false) }
    }
}
