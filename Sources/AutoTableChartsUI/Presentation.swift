import Foundation
import AutoTableCharts

/// Hashable presentation inputs used to memoize work outside SwiftUI initializers.
public struct AutoChartPresentationContext: Hashable, Codable, Sendable {
    public var identity: String
    private var localeValue: Locale
    private var timeZoneValue: TimeZone
    private var explicitLocaleIdentifier: String?
    private var explicitTimeZoneIdentifier: String?

    public var localeIdentifier: String {
        get { explicitLocaleIdentifier ?? localeValue.identifier }
        set {
            localeValue = Locale(identifier: newValue)
            explicitLocaleIdentifier = newValue
        }
    }
    public var timeZoneIdentifier: String {
        get { explicitTimeZoneIdentifier ?? timeZoneValue.identifier }
        set {
            timeZoneValue = TimeZone(identifier: newValue) ?? .gmt
            explicitTimeZoneIdentifier = newValue
        }
    }

    public init(
        identity: String = "default",
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.identity = identity
        self.localeValue = locale
        self.timeZoneValue = timeZone
        self.explicitLocaleIdentifier = locale == .autoupdatingCurrent
            ? nil : locale.identifier
        self.explicitTimeZoneIdentifier = timeZone == .autoupdatingCurrent
            ? nil : timeZone.identifier
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
        let decodedLocaleIdentifier = try container.decodeIfPresent(
            String.self, forKey: .localeIdentifier)
        if let locale = try container.decodeIfPresent(Locale.self, forKey: .locale) {
            localeValue = locale
            explicitLocaleIdentifier = locale == .autoupdatingCurrent
                ? nil : decodedLocaleIdentifier ?? locale.identifier
        } else {
            let identifier = try container.decode(String.self, forKey: .localeIdentifier)
            localeValue = Locale(identifier: identifier)
            explicitLocaleIdentifier = identifier
        }
        let decodedTimeZoneIdentifier = try container.decodeIfPresent(
            String.self, forKey: .timeZoneIdentifier)
        if let timeZone = try container.decodeIfPresent(TimeZone.self, forKey: .timeZone) {
            timeZoneValue = timeZone
            explicitTimeZoneIdentifier = timeZone == .autoupdatingCurrent
                ? nil : decodedTimeZoneIdentifier ?? timeZone.identifier
        } else {
            let identifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
            timeZoneValue = TimeZone(identifier: identifier) ?? .gmt
            explicitTimeZoneIdentifier = identifier
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

/// A stable snapshot of Foundation values and the effective identifiers they
/// exposed when presentation work was requested.
struct AutoChartFoundationPresentationIdentity: Hashable, Sendable {
    let fixedLocale: Locale?
    let localeIdentifier: String
    let usesAutoupdatingLocale: Bool
    let fixedTimeZone: TimeZone?
    let timeZoneIdentifier: String
    let usesAutoupdatingTimeZone: Bool

    init(locale: Locale, timeZone: TimeZone) {
        let usesAutoupdatingLocale = locale == .autoupdatingCurrent
        let usesAutoupdatingTimeZone = timeZone == .autoupdatingCurrent
        self.fixedLocale = usesAutoupdatingLocale ? nil : locale
        self.localeIdentifier = locale.identifier
        self.usesAutoupdatingLocale = usesAutoupdatingLocale
        self.fixedTimeZone = usesAutoupdatingTimeZone ? nil : timeZone
        self.timeZoneIdentifier = timeZone.identifier
        self.usesAutoupdatingTimeZone = usesAutoupdatingTimeZone
    }
}

struct AutoChartPresentationContextIdentity: Hashable, Sendable {
    let identity: String
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let foundation: AutoChartFoundationPresentationIdentity

    init(_ context: AutoChartPresentationContext) {
        self.identity = context.identity
        self.localeIdentifier = context.localeIdentifier
        self.timeZoneIdentifier = context.timeZoneIdentifier
        self.foundation = AutoChartFoundationPresentationIdentity(
            locale: context.locale,
            timeZone: context.timeZone)
    }
}

/// Complete identity for one presentation payload or deferred presentation task.
struct AutoChartPresentationRequestID: Hashable, Sendable {
    let preparedChart: AutoChartPreparedChartID
    let context: AutoChartPresentationContextIdentity
    let formatterFoundation: AutoChartFoundationPresentationIdentity
    let formatterCallback: UUID?
    let resolverCallback: UUID?

    init(
        preparedChart: AutoChartPreparedChartID,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) {
        self.preparedChart = preparedChart
        self.context = AutoChartPresentationContextIdentity(context)
        self.formatterFoundation = AutoChartFoundationPresentationIdentity(
            locale: formatters.locale,
            timeZone: formatters.timeZone)
        self.formatterCallback = formatters.callbackIdentity
        self.resolverCallback = textResolver.callbackIdentity
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
    let requestID: AutoChartPresentationRequestID

    public var id: AutoChartPreparedChartID { preparedChart.id }

    init(
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
        textResolver: AutoChartTextResolver,
        requestID: AutoChartPresentationRequestID
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
        self.requestID = requestID
    }
}

package struct AutoChartPresentedKPI: Sendable {
    package let valueText: String
    package let title: String
    package let accessibilityText: String
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
    private var entries: [AutoChartPresentationRequestID: AutoChartPresentationPayload] = [:]
    private var recency: [AutoChartPresentationRequestID] = []

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
        present(
            chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver,
            checkingCancellation: {})
    }

    func presentCheckingCancellation<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) throws -> AutoChartPresentedChart<RowID> {
        try present(
            chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver,
            checkingCancellation: { try Task.checkCancellation() })
    }

    func presentCancellable<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default,
        priority: TaskPriority = .userInitiated
    ) async throws -> AutoChartPresentedChart<RowID> {
        let work = Task.detached(priority: priority) {
            try self.presentCheckingCancellation(
                chart,
                context: context,
                formatters: formatters,
                textResolver: textResolver)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func present<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver,
        checkingCancellation: () throws -> Void
    ) rethrows -> AutoChartPresentedChart<RowID> {
        try checkingCancellation()
        let formatters = formatters ?? AutoChartFormatters(
            locale: context.locale, timeZone: context.timeZone)
        let requestID = AutoChartPresentationRequestID(
            preparedChart: chart.id,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        if let cached = lock.withLock({ cachedPayload(for: requestID) }) {
            try checkingCancellation()
            return presentedChart(
                chart,
                context: context,
                formatters: formatters,
                textResolver: textResolver,
                payload: cached,
                requestID: requestID)
        }

        // Host callbacks run outside the cache lock so a resolver or formatter
        // can safely re-enter a presenter without deadlocking.
        let core = chart.core
        let specification = chart.recommendation.specification
        let resolved = core.presentation.resolvedPresentation(
            data: core.data,
            using: textResolver,
            formatters: formatters)
        try checkingCancellation()
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
        try checkingCancellation()
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
        try checkingCancellation()
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
        try checkingCancellation()
        let proposed = AutoChartPresentationPayload(
            title: title,
            diagnostics: chart.diagnostics,
            selectionSummary: "\(chart.marks.count) chart marks",
            resolvedPresentation: resolved,
            renderedData: renderedData,
            facetPanels: facetPanels,
            sharedXCategoryDomain: sharedXCategoryDomain,
            kpi: kpi)
        try checkingCancellation()
        let payload = lock.withLock {
            if let cached = cachedPayload(for: requestID) { return cached }
            guard maximumEntries > 0 else { return proposed }
            entries[requestID] = proposed
            touch(requestID)
            while entries.count > maximumEntries, let oldest = recency.first {
                recency.removeFirst()
                entries.removeValue(forKey: oldest)
            }
            return proposed
        }
        try checkingCancellation()
        return presentedChart(
            chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver,
            payload: payload,
            requestID: requestID)
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll(keepingCapacity: false)
            recency.removeAll(keepingCapacity: false)
        }
    }

    private func cachedPayload(
        for key: AutoChartPresentationRequestID
    ) -> AutoChartPresentationPayload? {
        guard let payload = entries[key] else { return nil }
        touch(key)
        return payload
    }

    private func touch(_ key: AutoChartPresentationRequestID) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func presentedChart<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver,
        payload: AutoChartPresentationPayload,
        requestID: AutoChartPresentationRequestID
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
            textResolver: textResolver,
            requestID: requestID)
    }
}
