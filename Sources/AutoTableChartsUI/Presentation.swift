import Foundation
import AutoTableCharts

/// Hashable presentation inputs used to memoize work outside SwiftUI initializers.
public struct AutoChartPresentationContext: Hashable, Codable, Sendable {
    public var identity: String
    private var localeValue: Locale
    private var timeZoneValue: TimeZone

    public var localeIdentifier: String {
        get { localeValue.identifier }
        set { localeValue = Locale(identifier: newValue) }
    }
    public var timeZoneIdentifier: String {
        get { timeZoneValue.identifier }
        set { timeZoneValue = TimeZone(identifier: newValue) ?? .gmt }
    }

    public init(
        identity: String = "default",
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.identity = identity
        self.localeValue = locale
        self.timeZoneValue = timeZone
    }

    public var locale: Locale { localeValue }
    public var timeZone: TimeZone { timeZoneValue }

    private enum CodingKeys: String, CodingKey {
        case identity, localeIdentifier, timeZoneIdentifier
        case locale, timeZone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(String.self, forKey: .identity)
        if let locale = try container.decodeIfPresent(Locale.self, forKey: .locale) {
            localeValue = locale
        } else {
            localeValue = Locale(
                identifier: try container.decode(String.self, forKey: .localeIdentifier))
        }
        if let timeZone = try container.decodeIfPresent(TimeZone.self, forKey: .timeZone) {
            timeZoneValue = timeZone
        } else {
            timeZoneValue = TimeZone(
                identifier: try container.decode(String.self, forKey: .timeZoneIdentifier))
                ?? .gmt
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(localeValue, forKey: .locale)
        try container.encode(timeZoneValue, forKey: .timeZone)
    }
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
    package let formatters: AutoChartFormatters
    package let textResolver: AutoChartTextResolver

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
        kpi: AutoChartPresentedKPI?,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
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
        self.formatters = formatters
        self.textResolver = textResolver
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
    var formatterLocale: Locale
    var formatterTimeZone: TimeZone
    var formatterCallback: UUID?
    var resolverCallback: UUID?
}

private struct AutoChartPresentationPayload: Sendable {
    let title: String
    let diagnostics: [AutoChartDiagnostic]
    let selectionSummary: String
    let resolvedPresentation: AutoChartResolvedPresentation
    let renderedData: [AutoChartDatum]
    let facetPanels: [AutoChartFacetPanel]
    let sharedXCategoryDomain: [String]
    let kpi: AutoChartPresentedKPI?
}

/// Thread-safe presenter memoized by prepared-chart and presentation-context identity.
public final class AutoChartPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEntries: Int
    private var entries: [AutoChartPresentationKey: AutoChartPresentationPayload] = [:]
    private var recency: [AutoChartPresentationKey] = []

    /// Creates a presenter with a bounded presentation memo.
    public init(maximumEntries: Int = 16) {
        self.maximumEntries = max(0, maximumEntries)
    }

    public func present<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartPresentedChart<RowID> {
        let formatters = formatters ?? AutoChartFormatters(
            locale: context.locale, timeZone: context.timeZone)
        let key = AutoChartPresentationKey(
            preparedChart: chart.id,
            context: context,
            formatterLocale: formatters.locale,
            formatterTimeZone: formatters.timeZone,
            formatterCallback: formatters.callbackIdentity,
            resolverCallback: textResolver.callbackIdentity)
        if let cached = lock.withLock({ cachedPayload(for: key) }) {
            return presentedChart(
                chart,
                context: context,
                formatters: formatters,
                textResolver: textResolver,
                payload: cached)
        }

        // Host callbacks run outside the cache lock so a resolver or formatter
        // can safely re-enter a presenter without deadlocking.
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
            let valueText: String
            if let sourceValue = core.data.first?.ySourceValue {
                valueText = formatters.format(
                    AutoChartFormattingRequest(
                        column: column,
                        value: sourceValue,
                        context: .kpi,
                        purpose: semantics.formattingPurpose))
            } else {
                assertionFailure("Prepared KPI charts require one source measure value.")
                valueText = AutoChartValue.unrepresentableValuePlaceholder
            }
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
        let proposed = AutoChartPresentationPayload(
            title: title,
            diagnostics: chart.diagnostics,
            selectionSummary: "\(chart.marks.count) chart marks",
            resolvedPresentation: resolved,
            renderedData: renderedData,
            facetPanels: facetPanels,
            sharedXCategoryDomain: sharedXCategoryDomain,
            kpi: kpi)
        let payload = lock.withLock {
            if let cached = cachedPayload(for: key) { return cached }
            guard maximumEntries > 0 else { return proposed }
            entries[key] = proposed
            touch(key)
            while entries.count > maximumEntries, let oldest = recency.first {
                recency.removeFirst()
                entries.removeValue(forKey: oldest)
            }
            return proposed
        }
        return presentedChart(
            chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver,
            payload: payload)
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll(keepingCapacity: false)
            recency.removeAll(keepingCapacity: false)
        }
    }

    private func cachedPayload(
        for key: AutoChartPresentationKey
    ) -> AutoChartPresentationPayload? {
        guard let payload = entries[key] else { return nil }
        touch(key)
        return payload
    }

    private func touch(_ key: AutoChartPresentationKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func presentedChart<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver,
        payload: AutoChartPresentationPayload
    ) -> AutoChartPresentedChart<RowID> {
        AutoChartPresentedChart(
            preparedChart: chart,
            context: context,
            title: payload.title,
            diagnostics: payload.diagnostics,
            selectionSummary: payload.selectionSummary,
            resolvedPresentation: payload.resolvedPresentation,
            renderedData: payload.renderedData,
            facetPanels: payload.facetPanels,
            sharedXCategoryDomain: payload.sharedXCategoryDomain,
            kpi: payload.kpi,
            formatters: formatters,
            textResolver: textResolver)
    }
}
