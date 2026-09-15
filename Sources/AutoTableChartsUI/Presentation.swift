import Dispatch
import Foundation
import AutoTableCharts

/// Bounded, source-snapshot-free memoization shared by convenience tasks and
/// presented charts whose originating presenter has been released.
let autoChartConveniencePresenter = AutoChartPresenter()

final class AutoChartCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

private final class AutoChartCancellableWorkRelay<Value: Sendable>: @unchecked Sendable {
    private typealias Outcome = Result<Value, any Error>
    private typealias Continuation = CheckedContinuation<Outcome, Never>

    private enum State {
        case pending
        case waiting(Continuation)
        case completed(Outcome)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func value() async throws -> Value {
        let outcome = await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Outcome? in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return nil
                case .waiting:
                    preconditionFailure("Cancellable work supports one waiter.")
                case .completed(let outcome):
                    return outcome
                }
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }
        return try outcome.get()
    }

    func complete(with outcome: Result<Value, any Error>) {
        let continuation = lock.withLock { () -> Continuation? in
            switch state {
            case .pending:
                state = .completed(outcome)
                return nil
            case .waiting(let continuation):
                state = .completed(outcome)
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume(returning: outcome)
    }
}

enum AutoChartCancellableWork {
    static func run<Value: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable (AutoChartCancellationToken) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let callbackContext = AutoChartHostCallbackActivity.currentContext
        let cancellation = AutoChartCancellationToken()
        let relay = AutoChartCancellableWorkRelay<Value>()
        queue.async {
            guard !cancellation.isCancelled else { return }
            do {
                let value = try AutoChartHostCallbackActivity.withContext(callbackContext) {
                    try cancellation.checkCancellation()
                    return try operation(cancellation)
                }
                try cancellation.checkCancellation()
                relay.complete(with: .success(value))
            } catch {
                relay.complete(with: .failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            let value = try await relay.value()
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
            relay.complete(with: .failure(CancellationError()))
        }
    }
}

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
        case usesAutoupdatingLocale, usesAutoupdatingTimeZone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(String.self, forKey: .identity)
        let decodedLocaleIdentifier = try container.decodeIfPresent(
            String.self, forKey: .localeIdentifier)
        if try container.decodeIfPresent(
            Bool.self, forKey: .usesAutoupdatingLocale) == true
        {
            localeValue = .autoupdatingCurrent
            explicitLocaleIdentifier = nil
        } else if let locale = try container.decodeIfPresent(
            Locale.self, forKey: .locale)
        {
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
        if try container.decodeIfPresent(
            Bool.self, forKey: .usesAutoupdatingTimeZone) == true
        {
            timeZoneValue = .autoupdatingCurrent
            explicitTimeZoneIdentifier = nil
        } else if let timeZone = try container.decodeIfPresent(
            TimeZone.self, forKey: .timeZone)
        {
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
        try container.encode(
            localeValue == .autoupdatingCurrent,
            forKey: .usesAutoupdatingLocale)
        try container.encode(
            timeZoneValue == .autoupdatingCurrent,
            forKey: .usesAutoupdatingTimeZone)
    }
}

/// A stable snapshot of Foundation values and the effective identifiers they
/// exposed when presentation work was requested.
struct AutoChartFoundationPresentationIdentity: Hashable, Sendable {
    let resolvedLocale: Locale
    let localeIdentifier: String
    let usesAutoupdatingLocale: Bool
    let resolvedTimeZone: TimeZone
    let timeZoneIdentifier: String
    let usesAutoupdatingTimeZone: Bool

    init(locale: Locale, timeZone: TimeZone) {
        let usesAutoupdatingLocale = locale == .autoupdatingCurrent
        let usesAutoupdatingTimeZone = timeZone == .autoupdatingCurrent
        let resolvedLocale = usesAutoupdatingLocale ? Locale.current : locale
        let resolvedTimeZone = usesAutoupdatingTimeZone ? TimeZone.current : timeZone
        self.resolvedLocale = resolvedLocale
        self.localeIdentifier = resolvedLocale.identifier
        self.usesAutoupdatingLocale = usesAutoupdatingLocale
        self.resolvedTimeZone = resolvedTimeZone
        self.timeZoneIdentifier = resolvedTimeZone.identifier
        self.usesAutoupdatingTimeZone = usesAutoupdatingTimeZone
    }
}

struct AutoChartPresentationContextIdentity: Hashable, Sendable {
    let identity: String
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let foundation: AutoChartFoundationPresentationIdentity

    init(_ context: AutoChartPresentationContext) {
        let foundation = AutoChartFoundationPresentationIdentity(
            locale: context.locale,
            timeZone: context.timeZone)
        self.identity = context.identity
        self.localeIdentifier = foundation.usesAutoupdatingLocale
            ? foundation.localeIdentifier : context.localeIdentifier
        self.timeZoneIdentifier = foundation.usesAutoupdatingTimeZone
            ? foundation.timeZoneIdentifier : context.timeZoneIdentifier
        self.foundation = foundation
    }
}

/// Complete identity for one presentation payload or deferred presentation task.
struct AutoChartPresentationRequestID: Hashable, Sendable {
    let preparedChart: AutoChartPreparedChartID
    let context: AutoChartPresentationContextIdentity
    let formatterFoundation: AutoChartFoundationPresentationIdentity
    let formatterCallback: AutoChartHostCallbackCacheIdentity?
    let resolverCallback: AutoChartHostCallbackCacheIdentity?
}

/// One immutable sampling of every input used to build and identify a payload.
/// The policy values remain live for later invalidation, while `resolvedFormatters`
/// freezes autoupdating Foundation values for this request's complete output.
struct AutoChartPresentationRequest: Sendable {
    let id: AutoChartPresentationRequestID
    let context: AutoChartPresentationContext
    let formatters: AutoChartFormatters
    let resolvedFormatters: AutoChartFormatters
    let textResolver: AutoChartTextResolver

    init(
        preparedChart: AutoChartPreparedChartID,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) {
        let contextIdentity = AutoChartPresentationContextIdentity(context)
        let formatterFoundation = AutoChartFoundationPresentationIdentity(
            locale: formatters.locale,
            timeZone: formatters.timeZone)
        var resolvedFormatters = formatters
        resolvedFormatters.locale = formatterFoundation.resolvedLocale
        resolvedFormatters.timeZone = formatterFoundation.resolvedTimeZone

        self.id = AutoChartPresentationRequestID(
            preparedChart: preparedChart,
            context: contextIdentity,
            formatterFoundation: formatterFoundation,
            formatterCallback: formatters.callbackIdentity,
            resolverCallback: textResolver.callbackIdentity)
        self.context = context
        self.formatters = formatters
        self.resolvedFormatters = resolvedFormatters
        self.textResolver = textResolver
    }
}

private struct AutoChartOrderedPresentationContent {
    let data: [AutoChartDatum]
    let facetDeclaredRanks: [String: Int]
}

private func orderedPresentationContent(
    core: AutoChartRenderCore,
    specification: AutoChartSpecification,
    resolved: AutoChartResolvedPresentation,
    formatters: AutoChartFormatters
) -> AutoChartOrderedPresentationContent {
    let usesDeclaredOrder = specification.sort == .source
    let xDeclaredRanks = usesDeclaredOrder
        ? declaredCategoryRanks(for: specification.encoding.x.flatMap {
            core.table.profiles[$0]
        }) : [:]
    let yDeclaredRanks = usesDeclaredOrder
        ? declaredCategoryRanks(for: specification.encoding.y.flatMap {
            core.table.profiles[$0]
        }) : [:]
    let seriesDeclaredRanks = usesDeclaredOrder
        ? declaredCategoryRanks(for: specification.encoding.series.flatMap {
            core.table.profiles[$0]
        }) : [:]
    let facetDeclaredRanks = usesDeclaredOrder
        ? declaredCategoryRanks(for: specification.encoding.facet.flatMap {
            core.table.profiles[$0]
        }) : [:]
    let data: [AutoChartDatum]
    if specification.family == .boxPlot {
        data = orderedBoxPlotData(
            core.data,
            labels: resolved.xDisplayLabels,
            fallback: resolved.missingValue,
            locale: formatters.locale,
            declaredRanks: xDeclaredRanks)
    } else {
        data = orderedPresentedData(
            core.data,
            specification: specification,
            xLabels: resolved.xDisplayLabels,
            yLabels: resolved.yDisplayLabels,
            missingValue: resolved.missingValue,
            locale: formatters.locale,
            xDeclaredRanks: xDeclaredRanks,
            yDeclaredRanks: yDeclaredRanks,
            seriesDeclaredRanks: seriesDeclaredRanks)
    }
    return AutoChartOrderedPresentationContent(
        data: data,
        facetDeclaredRanks: facetDeclaredRanks)
}

private func resolvedDisplayTitle<RowID: Hashable & Sendable>(
    for chart: AutoChartPreparedChart<RowID>,
    textResolver: AutoChartTextResolver
) -> String {
    let specification = chart.recommendation.specification
    return specification.title.isEmpty
        ? textResolver(specification.family.localizationMessage)
        : specification.title
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
    /// Original formatter policy retained so autoupdating values can invalidate later.
    package let formatters: AutoChartFormatters
    /// Foundation values frozen to the snapshot that produced this payload.
    package let resolvedFormatters: AutoChartFormatters
    package let textResolver: AutoChartTextResolver
    let audioGraphAvailability: AutoChartAudioGraphAvailability?
    let originatingPresenter: AutoChartPresenterReference
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
        resolvedFormatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver,
        audioGraphAvailability: AutoChartAudioGraphAvailability?,
        originatingPresenter: AutoChartPresenterReference,
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
        self.resolvedFormatters = resolvedFormatters
        self.textResolver = textResolver
        self.audioGraphAvailability = audioGraphAvailability
        self.originatingPresenter = originatingPresenter
        self.requestID = requestID
    }

    /// Explicit descriptor building is uncached; SwiftUI supplies a view-owned cache.
    func makeAudioGraphDescriptor() -> AutoChartAudioGraphDescriptor? {
        guard let audioGraphAvailability else { return nil }
        return makeAudioGraphDescriptor(availability: audioGraphAvailability)
    }

    private func makeAudioGraphDescriptor(
        availability: AutoChartAudioGraphAvailability
    ) -> AutoChartAudioGraphDescriptor {
        makeAutoChartAudioGraphDescriptor(
            preparedChart: preparedChart,
            renderedData: renderedData,
            resolved: resolvedPresentation,
            displayTitle: title,
            formatters: resolvedFormatters,
            textResolver: textResolver,
            availability: availability)
    }

    func makeLazyAudioGraphDescriptor(
        cache: AutoChartAudioGraphViewCache? = AutoChartAudioGraphViewCache()
    ) -> AutoChartLazyAudioGraphDescriptor? {
        guard let audioGraphAvailability else { return nil }
        return AutoChartLazyAudioGraphDescriptor(requestID: requestID, cache: cache) {
            makeAudioGraphDescriptor(availability: audioGraphAvailability)
        }
    }

    func presentationRequest(
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) -> AutoChartPresentationRequest {
        AutoChartPresentationRequest(
            preparedChart: id, context: context,
            formatters: formatters, textResolver: textResolver)
    }

    /// Returns an exact cached override without running host callbacks.
    func cachedRePresentation(
        request: AutoChartPresentationRequest
    ) -> AutoChartPresentedChart<RowID>? {
        originatingPresenter.active.cachedPresentation(
            preparedChart,
            request: request)
    }

    func rePresent(
        request: AutoChartPresentationRequest
    ) -> AutoChartPresentedChart<RowID> {
        originatingPresenter.active.present(
            preparedChart,
            request: request,
            checkingCancellation: {})
    }

    func rePresentCancellable(
        request: AutoChartPresentationRequest
    ) async throws -> AutoChartPresentedChart<RowID> {
        try await originatingPresenter.active.presentCancellable(
            preparedChart,
            request: request)
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
    let audioGraphAvailability: AutoChartAudioGraphAvailability?
}

final class AutoChartPresenterReference: @unchecked Sendable {
    private weak var source: AutoChartPresenter?
    private let fallback: AutoChartPresenter

    init(_ source: AutoChartPresenter, fallback: AutoChartPresenter) {
        self.source = source
        self.fallback = fallback
    }

    var active: AutoChartPresenter {
        source ?? fallback
    }
}

/// Thread-safe presenter memoized by prepared-chart and presentation-context identity.
public final class AutoChartPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumEntries: Int
    #if ATC_TEST_HOOKS
    private let releasedPresenterFallbackForTesting: AutoChartPresenter?
    #endif
    private var entries: [AutoChartPresentationRequestID: AutoChartPresentationPayload] = [:]
    private var recency: [AutoChartPresentationRequestID] = []

    /// Creates a presenter with a bounded presentation memo.
    public init(maximumEntries: Int = 16) {
        self.maximumEntries = max(0, maximumEntries)
        #if ATC_TEST_HOOKS
        self.releasedPresenterFallbackForTesting = nil
        #endif
    }

    #if ATC_TEST_HOOKS
    /// Test-only construction keeps orphan fallback behavior off process-wide state.
    init(
        maximumEntries: Int = 16,
        releasedPresenterFallbackForTesting: AutoChartPresenter
    ) {
        self.maximumEntries = max(0, maximumEntries)
        self.releasedPresenterFallbackForTesting = releasedPresenterFallbackForTesting
    }
    #endif

    public func present<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartPresentedChart<RowID> {
        let request = presentationRequest(
            for: chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        return present(
            chart,
            request: request,
            checkingCancellation: {})
    }

    func presentCheckingCancellation<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) throws -> AutoChartPresentedChart<RowID> {
        let request = presentationRequest(
            for: chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        return try present(
            chart,
            request: request,
            checkingCancellation: { try Task.checkCancellation() })
    }

    func presentCancellable<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default,
        priority: TaskPriority = .userInitiated
    ) async throws -> AutoChartPresentedChart<RowID> {
        let request = presentationRequest(
            for: chart,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        return try await presentCancellable(
            chart, request: request, priority: priority)
    }

    /// Presents the exact snapshot already used as SwiftUI task identity.
    func presentCancellable<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        request: AutoChartPresentationRequest,
        priority: TaskPriority = .userInitiated
    ) async throws -> AutoChartPresentedChart<RowID> {
        return try await AutoChartCancellableWork.run(
            on: DispatchQueue.global(qos: Self.qos(for: priority))
        ) { cancellation in
            try self.present(
                chart,
                request: request,
                checkingCancellation: cancellation.checkCancellation)
        }
    }

    /// Looks up an exact payload without invoking formatters or resolvers.
    func cachedPresentation<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        request: AutoChartPresentationRequest
    ) -> AutoChartPresentedChart<RowID>? {
        guard let payload = lock.withLock({ cachedPayload(for: request.id) }) else {
            return nil
        }
        return presentedChart(
            chart,
            payload: payload,
            request: request)
    }

    private func presentationRequest<RowID: Hashable & Sendable>(
        for chart: AutoChartPreparedChart<RowID>,
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver
    ) -> AutoChartPresentationRequest {
        let formatters = formatters ?? AutoChartFormatters(
            locale: context.locale,
            timeZone: context.timeZone)
        return AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
    }

    private static func qos(for priority: TaskPriority) -> DispatchQoS.QoSClass {
        switch priority {
        case .background:
            return .background
        case .low:
            return .utility
        case .high:
            return .userInitiated
        default:
            return .default
        }
    }

    func present<RowID: Hashable & Sendable>(
        _ chart: AutoChartPreparedChart<RowID>,
        request: AutoChartPresentationRequest,
        checkingCancellation: () throws -> Void
    ) rethrows -> AutoChartPresentedChart<RowID> {
        try checkingCancellation()
        let formatters = request.resolvedFormatters
        let textResolver = request.textResolver
        let requestID = request.id
        if let cached = lock.withLock({ cachedPayload(for: requestID) }) {
            try checkingCancellation()
            return presentedChart(
                chart,
                payload: cached,
                request: request)
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
        let ordered = orderedPresentationContent(
            core: core,
            specification: specification,
            resolved: resolved,
            formatters: formatters)
        let renderedData = ordered.data
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
                locale: formatters.locale,
                declaredRanks: ordered.facetDeclaredRanks)
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
        let audioGraphAvailability = makeAutoChartAudioGraphAvailability(
            preparedChart: chart, renderedData: renderedData)
        try checkingCancellation()
        let title = resolvedDisplayTitle(for: chart, textResolver: textResolver)
        let proposed = AutoChartPresentationPayload(
            title: title,
            diagnostics: chart.diagnostics,
            selectionSummary: "\(chart.marks.count) chart marks",
            resolvedPresentation: resolved,
            renderedData: renderedData,
            facetPanels: facetPanels,
            sharedXCategoryDomain: sharedXCategoryDomain,
            kpi: kpi,
            audioGraphAvailability: audioGraphAvailability)
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
            payload: payload,
            request: request)
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
        payload: AutoChartPresentationPayload,
        request: AutoChartPresentationRequest
    ) -> AutoChartPresentedChart<RowID> {
        #if ATC_TEST_HOOKS
        let releasedPresenterFallback = releasedPresenterFallbackForTesting
            ?? autoChartConveniencePresenter
        #else
        let releasedPresenterFallback = autoChartConveniencePresenter
        #endif
        return AutoChartPresentedChart(
            preparedChart: chart,
            context: request.context,
            title: payload.title,
            diagnostics: payload.diagnostics,
            selectionSummary: payload.selectionSummary,
            resolvedPresentation: payload.resolvedPresentation,
            renderedData: payload.renderedData,
            facetPanels: payload.facetPanels,
            sharedXCategoryDomain: payload.sharedXCategoryDomain,
            kpi: payload.kpi,
            formatters: request.formatters,
            resolvedFormatters: request.resolvedFormatters,
            textResolver: request.textResolver,
            audioGraphAvailability: payload.audioGraphAvailability,
            originatingPresenter: AutoChartPresenterReference(
                self,
                fallback: releasedPresenterFallback),
            requestID: request.id)
    }
}
