#if canImport(SwiftUI) && canImport(Charts)
import Dispatch
import Foundation
import SwiftUI
import Charts
import AutoTableCharts

/// Process-wide memo used by deferred convenience presentation tasks and by
/// presented charts whose originating presenter has been released.
///
/// Release its bounded presentation payloads in response to memory pressure or
/// when the host no longer displays convenience-created or fallback-presented charts.
public enum AutoChartConveniencePresentationCache {
    public static func removeAll() {
        autoChartConveniencePresenter.removeAll()
    }
}

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

/// Controls where presented-chart override callbacks run on a cache miss.
public enum AutoChartOverridePresentationMode: Hashable, Sendable {
    /// Resolves presentation synchronously on the caller's thread. This is the
    /// compatibility default and is suitable for synchronous renderers.
    case immediate
    /// Keeps the incoming chart visible while presentation resolves off-main.
    case deferred
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
    case deferred(AutoChartPreparedChart<RowID>, AutoChartPresentationContext?)
    case deferredOverride(AutoChartDeferredPresentationSource<RowID>)
    case immediateOverride(
        source: AutoChartPresentedChart<RowID>,
        resolved: AutoChartPresentedChart<RowID>,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver)
    case chart(AutoChartPreparedChart<RowID>, AutoChartResolvedPresentation)
    case fallback(AutoChartFallback)
}

private enum AutoChartDeferredPresentationSource<RowID: Hashable & Sendable>: Sendable {
    case prepared(
        AutoChartPreparedChart<RowID>,
        AutoChartPresentationRequest)
    case presented(
        source: AutoChartPresentedChart<RowID>,
        immediate: AutoChartPresentedChart<RowID>,
        request: AutoChartPresentationRequest)

    var preparedChart: AutoChartPreparedChart<RowID> {
        switch self {
        case .prepared(let chart, _):
            return chart
        case .presented(let source, _, _):
            return source.preparedChart
        }
    }

    var request: AutoChartPresentationRequest {
        switch self {
        case .prepared(_, let request), .presented(_, _, let request):
            return request
        }
    }

    var immediatePresentedChart: AutoChartPresentedChart<RowID>? {
        guard case .presented(_, let immediate, _) = self else { return nil }
        return immediate
    }

    var sourcePresentationID: AutoChartPresentationRequestID? {
        guard case .presented(let source, _, _) = self else { return nil }
        return source.requestID
    }

    func resampling(
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) -> Self {
        guard case .presented(let source, _, _) = self else { return self }
        let request = source.presentationRequest(
            formatters: formatters,
            textResolver: textResolver)
        let immediate = request.id == source.requestID
            ? source
            : source.cachedRePresentation(request: request) ?? source
        return .presented(source: source, immediate: immediate, request: request)
    }

    func present(on scheduler: AutoChartCallbackWorkScheduler) async throws
        -> AutoChartPresentedChart<RowID>
    {
        switch self {
        case .prepared(let chart, let request):
            return try await autoChartConveniencePresenter.presentCancellable(
                chart,
                request: request,
                scheduler: scheduler)
        case .presented(let source, _, let request):
            return try await source.rePresentCancellable(
                request: request,
                scheduler: scheduler)
        }
    }
}

struct AutoChartViewPresentationInputs {
    let context: AutoChartPresentationContext
    let formatters: AutoChartFormatters
    let textResolver: AutoChartTextResolver

    static func resolve(
        explicitContext: AutoChartPresentationContext?,
        environmentContext: AutoChartPresentationContext?,
        explicitFormatters: AutoChartFormatters?,
        environmentFormatters: AutoChartFormatters?,
        explicitTextResolver: AutoChartTextResolver?,
        environmentTextResolver: AutoChartTextResolver?
    ) -> Self {
        let suppliedContext = explicitContext ?? environmentContext
        let suppliedFormatters = explicitFormatters ?? environmentFormatters
        let formatters: AutoChartFormatters
        let context: AutoChartPresentationContext
        switch (suppliedContext, suppliedFormatters) {
        case (let suppliedContext?, let suppliedFormatters?):
            context = suppliedContext
            formatters = suppliedFormatters
        case (let suppliedContext?, nil):
            context = suppliedContext
            formatters = AutoChartFormatters(
                locale: suppliedContext.locale,
                timeZone: suppliedContext.timeZone)
        case (nil, let suppliedFormatters?):
            formatters = suppliedFormatters
            context = AutoChartPresentationContext(
                locale: suppliedFormatters.locale,
                timeZone: suppliedFormatters.timeZone)
        case (nil, nil):
            formatters = AutoChartFormatters()
            context = AutoChartPresentationContext(
                locale: formatters.locale,
                timeZone: formatters.timeZone)
        }
        return Self(
            context: context,
            formatters: formatters,
            textResolver: explicitTextResolver ?? environmentTextResolver ?? .default)
    }
}

private final class AutoChartDeferredPresentationWorker: ObservableObject {
    let scheduler = AutoChartCallbackWorkScheduler(
        maximumConcurrentJobs: 1,
        queue: DispatchQueue.global(qos: .userInitiated))
}

private struct AutoChartDeferredPresentationView<RowID: Hashable & Sendable>: View {
    let source: AutoChartDeferredPresentationSource<RowID>
    let analysisID: AutoChartAnalysisID
    let selection: Binding<AutoChartSelectionSet<RowID>>
    let presentation: AutoChartPresentation
    private struct StoredPresentation {
        let chart: AutoChartPresentedChart<RowID>
        let sourcePresentationID: AutoChartPresentationRequestID?
    }
    private struct TaskID: Hashable {
        let request: AutoChartPresentationRequestID
        let scheduling: AutoChartDeferredCallbackScheduling
    }
    @State private var storedPresentation: StoredPresentation?
    @StateObject private var worker = AutoChartDeferredPresentationWorker()
    @Environment(\.autoChartDeferredCallbackScheduling) private var callbackScheduling
    #if ATC_TEST_HOOKS
    @Environment(\.autoChartViewTestHooks) private var viewTestHooks
    #endif

    private var visiblePresentedChart: AutoChartPresentedChart<RowID>? {
        if let immediate = source.immediatePresentedChart,
            immediate.requestID == source.request.id
        {
            return immediate
        }
        if let storedPresentation,
            storedPresentation.sourcePresentationID == source.sourcePresentationID
        {
            return storedPresentation.chart
        }
        return source.immediatePresentedChart
    }

    @ViewBuilder
    var body: some View {
        let request = source.request
        let requestID = request.id
        let visible = visiblePresentedChart
        ZStack(alignment: .topTrailing) {
            if let presentedChart = visible {
                AutoChartView(
                    resolvedPresentedChart: presentedChart,
                    analysisID: analysisID,
                    selection: selection,
                    presentation: presentation)
            } else {
                AutoChartAccessibleProgressView(
                    message: AutoChartProgressAccessibility.preparing,
                    textResolver: request.textResolver,
                    scheduler: worker.scheduler)
                    .frame(maxWidth: .infinity)
                    .frame(height: presentation.plotHeight)
            }
            if let presentedChart = visible,
                presentedChart.requestID != requestID
            {
                AutoChartAccessibleProgressView(
                    message: AutoChartProgressAccessibility.updating,
                    textResolver: request.textResolver,
                    scheduler: worker.scheduler)
                    .controlSize(.small)
                    .padding(8)
            }
        }
        .task(id: TaskID(request: requestID, scheduling: callbackScheduling)) {
            #if ATC_TEST_HOOKS
            viewTestHooks?.callbackSchedulerForTesting = worker.scheduler
            #endif
            worker.scheduler.setMaximumConcurrentJobs(
                callbackScheduling.maximumConcurrentJobs)
            // Exact inputs need no publication. This avoids an otherwise
            // redundant body pass each time an exact cached view mounts.
            guard visible?.requestID != requestID else {
                if let storedPresentation,
                    storedPresentation.chart.requestID != requestID
                        || storedPresentation.sourcePresentationID
                            != source.sourcePresentationID
                {
                    self.storedPresentation = nil
                }
                #if ATC_TEST_HOOKS
                viewTestHooks?.didFinishDeferredPresentation(requestID, .exact)
                #endif
                return
            }
            if let storedPresentation,
                storedPresentation.sourcePresentationID != source.sourcePresentationID
            {
                self.storedPresentation = nil
            }
            do {
                let presented = try await source.present(on: worker.scheduler)
                try Task.checkCancellation()
                #if ATC_TEST_HOOKS
                viewTestHooks?.didPublishDeferredPresentation(presented.requestID)
                #endif
                storedPresentation = StoredPresentation(
                    chart: presented,
                    sourcePresentationID: source.sourcePresentationID)
                #if ATC_TEST_HOOKS
                viewTestHooks?.didFinishDeferredPresentation(requestID, .published)
                #endif
            } catch is CancellationError {
                #if ATC_TEST_HOOKS
                viewTestHooks?.didFinishDeferredPresentation(requestID, .cancelled)
                #endif
                return
            } catch {
                assertionFailure("Unexpected deferred presentation error: \(error)")
            }
        }
    }
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

#if canImport(Accessibility)
/// Owns Audio Graph memoization only while an accessible chart is mounted.
private struct AutoChartAccessibleChart<Content: View>: View {
    let content: Content
    let descriptor: AutoChartLazyAudioGraphDescriptor
    @StateObject private var cache = AutoChartAudioGraphViewCache()
    #if ATC_TEST_HOOKS
    @Environment(\.autoChartViewTestHooks) private var viewTestHooks
    @Environment(\.autoChartViewRevisionForTesting) private var viewRevisionForTesting
    #endif

    var body: some View {
        let cachedDescriptor = descriptor.cached(in: cache)
        let chart = content.accessibilityChartDescriptor(cachedDescriptor)
        #if ATC_TEST_HOOKS
        if viewTestHooks != nil {
            chart.background {
                Color.clear
                    .onAppear { reportAudioGraphForTesting(cachedDescriptor) }
                    .onChange(of: descriptor.requestID) { _, _ in
                        reportAudioGraphForTesting(cachedDescriptor)
                    }
                    .onChange(of: viewRevisionForTesting) { _, _ in
                        reportAudioGraphForTesting(cachedDescriptor)
                    }
            }
        } else {
            chart
        }
        #else
        chart
        #endif
    }

    #if ATC_TEST_HOOKS
    private func reportAudioGraphForTesting(
        _ cachedDescriptor: AutoChartLazyAudioGraphDescriptor
    ) {
        viewTestHooks?.observeAudioGraph(cache, cachedDescriptor)
    }
    #endif
}
#endif

/// Convenience composition of a prepared plot and optional package chrome.
public struct AutoChartView<RowID: Hashable & Sendable>: View {
    #if ATC_TEST_HOOKS
    var presentedChartForTesting: AutoChartPresentedChart<RowID>?
    @Environment(\.autoChartViewTestHooks) private var viewTestHooks
    @Environment(\.autoChartViewRevisionForTesting) private var viewRevisionForTesting
    #endif

    private var content: AutoChartViewContent<RowID>
    private let displayTitle: String
    private let presentation: AutoChartPresentation
    private let formatters: AutoChartFormatters?
    private let textResolver: AutoChartTextResolver?
    private let renderedData: [AutoChartDatum]
    private let facetPanels: [AutoChartFacetPanel]
    private let sharedXCategoryDomain: [String]
    private let presentedKPI: AutoChartPresentedKPI?
    private let presentedAudioGraphDescriptor: AutoChartLazyAudioGraphDescriptor?
    private let presentationRequestID: AutoChartPresentationRequestID?
    private let analysisID: AutoChartAnalysisID
    @Binding private var selection: AutoChartSelectionSet<RowID>

    private struct SelectionOwnershipID: Hashable {
        let analysis: AutoChartAnalysisID
        let preparedChart: AutoChartPreparedChartID
    }

    private var selectionOwnershipID: SelectionOwnershipID {
        SelectionOwnershipID(analysis: analysisID, preparedChart: preparedChart.id)
    }

    private var ownsSelection: Bool {
        !selection.isEmpty && selection.belongs(
            to: analysisID, preparedChartID: preparedChart.id)
    }

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
    @State private var foundationSettingsRevision = 0
    @Environment(\.autoChartPalette) private var palette
    @Environment(\.autoChartTheme) private var theme
    @Environment(\.autoChartPresentationContext) private var environmentPresentationContext
    @Environment(\.autoChartFormatters) private var environmentFormatters
    @Environment(\.autoChartTextResolver) private var environmentTextResolver
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    private func effectivePresentationInputs(
        explicit: AutoChartPresentationContext?
    ) -> AutoChartViewPresentationInputs {
        AutoChartViewPresentationInputs.resolve(
            explicitContext: explicit,
            environmentContext: environmentPresentationContext,
            explicitFormatters: formatters,
            environmentFormatters: environmentFormatters,
            explicitTextResolver: textResolver,
            environmentTextResolver: environmentTextResolver)
    }

    private var effectiveFormatters: AutoChartFormatters {
        effectivePresentationInputs(explicit: nil).formatters
    }

    private var effectiveTextResolver: AutoChartTextResolver {
        effectivePresentationInputs(explicit: nil).textResolver
    }

    /// Defers presentation until the view participates in a SwiftUI lifecycle.
    /// For synchronous renderers, resolve the chart with ``AutoChartPresenter``
    /// and use
    /// ``init(presentedChart:analysisID:selection:presentation:formatters:textResolver:overridePresentationMode:)``.
    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver? = nil
    ) {
        content = .deferred(preparedChart, presentationContext)
        displayTitle = ""
        renderedData = []
        facetPanels = []
        sharedXCategoryDomain = []
        presentedKPI = nil
        presentedAudioGraphDescriptor = nil
        presentationRequestID = nil
        self.analysisID = analysisID
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters
        self.textResolver = textResolver
    }

    /// Compatibility overload for the original nonoptional presentation inputs.
    @_disfavoredOverload
    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        self.init(
            preparedChart: preparedChart,
            analysisID: analysisID,
            selection: selection,
            presentation: presentation,
            presentationContext: presentationContext,
            formatters: Optional(formatters),
            textResolver: Optional(textResolver))
    }

    /// Renders a presented chart, resolving override cache misses synchronously
    /// by default so callback behavior remains compatible with synchronous
    /// renderers such as `ImageRenderer`.
    public init(
        presentedChart: AutoChartPresentedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver? = nil,
        overridePresentationMode: AutoChartOverridePresentationMode = .immediate
    ) {
        let effectiveFormatters = formatters ?? presentedChart.formatters
        let effectiveTextResolver = textResolver ?? presentedChart.textResolver
        let request = presentedChart.presentationRequest(
            formatters: effectiveFormatters,
            textResolver: effectiveTextResolver)
        let cached = request.id == presentedChart.requestID
            ? presentedChart
            : presentedChart.cachedRePresentation(
                request: request)
        switch overridePresentationMode {
        case .immediate:
            let resolved = cached ?? presentedChart.rePresent(request: request)
            self.init(
                resolvedPresentedChart: resolved,
                analysisID: analysisID,
                selection: selection,
                presentation: presentation)
            content = .immediateOverride(
                source: presentedChart,
                resolved: resolved,
                formatters: effectiveFormatters,
                textResolver: effectiveTextResolver)
        case .deferred:
            self.init(
                deferredOverrideSource: .presented(
                    source: presentedChart,
                    immediate: cached ?? presentedChart,
                    request: request),
                analysisID: analysisID,
                selection: selection,
                presentation: presentation,
                formatters: effectiveFormatters,
                textResolver: effectiveTextResolver)
        }
    }

    private init(
        deferredOverrideSource: AutoChartDeferredPresentationSource<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>>,
        presentation: AutoChartPresentation,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) {
        #if ATC_TEST_HOOKS
        presentedChartForTesting = nil
        #endif
        content = .deferredOverride(deferredOverrideSource)
        displayTitle = ""
        renderedData = []
        facetPanels = []
        sharedXCategoryDomain = []
        presentedKPI = nil
        presentedAudioGraphDescriptor = nil
        presentationRequestID = nil
        self.analysisID = analysisID
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters
        self.textResolver = textResolver
    }

    /// Builds the already-resolved chart inside the stable presented-chart loader.
    init(
        resolvedPresentedChart: AutoChartPresentedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>>,
        presentation: AutoChartPresentation
    ) {
        #if ATC_TEST_HOOKS
        presentedChartForTesting = resolvedPresentedChart
        #endif
        content = .chart(
            resolvedPresentedChart.preparedChart,
            resolvedPresentedChart.resolvedPresentation)
        displayTitle = resolvedPresentedChart.title
        renderedData = resolvedPresentedChart.renderedData
        facetPanels = resolvedPresentedChart.facetPanels
        sharedXCategoryDomain = resolvedPresentedChart.sharedXCategoryDomain
        presentedKPI = resolvedPresentedChart.kpi
        #if canImport(Accessibility)
        presentedAudioGraphDescriptor = resolvedPresentedChart.makeLazyAudioGraphDescriptor(
            cache: nil)
        #else
        presentedAudioGraphDescriptor = nil
        #endif
        presentationRequestID = resolvedPresentedChart.requestID
        self.analysisID = analysisID
        self._selection = selection
        self.presentation = presentation
        self.formatters = resolvedPresentedChart.resolvedFormatters
        self.textResolver = resolvedPresentedChart.textResolver
    }

    /// Defers presentation until the view participates in a SwiftUI lifecycle.
    /// For synchronous renderers, resolve the primary chart with
    /// ``AutoChartPresenter`` and use the presented-chart initializer.
    public init(
        analysis: AutoChartAnalysis<RowID>,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver? = nil
    ) {
        if let primary = analysis.primaryChart {
            content = .deferred(primary, presentationContext)
            displayTitle = ""
            renderedData = []
            facetPanels = []
            sharedXCategoryDomain = []
            presentedKPI = nil
            presentedAudioGraphDescriptor = nil
            presentationRequestID = nil
        } else if case .tableFallback(let fallback) = analysis.outcome {
            content = .fallback(fallback)
            displayTitle = ""
            renderedData = []
            facetPanels = []
            sharedXCategoryDomain = []
            presentedKPI = nil
            presentedAudioGraphDescriptor = nil
            presentationRequestID = nil
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
            presentedAudioGraphDescriptor = nil
            presentationRequestID = nil
        }
        analysisID = analysis.id
        self._selection = selection
        self.presentation = presentation
        self.formatters = formatters
        self.textResolver = textResolver
    }

    /// Compatibility overload for the original nonoptional presentation inputs.
    @_disfavoredOverload
    public init(
        analysis: AutoChartAnalysis<RowID>,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        presentation: AutoChartPresentation = .explorer(),
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        self.init(
            analysis: analysis,
            selection: selection,
            presentation: presentation,
            presentationContext: presentationContext,
            formatters: Optional(formatters),
            textResolver: Optional(textResolver))
    }

    private var preparedChart: AutoChartPreparedChart<RowID> {
        switch content {
        case .deferred(let chart, _), .chart(let chart, _):
            return chart
        case .deferredOverride(let source):
            return source.preparedChart
        case .immediateOverride(let source, _, _, _):
            return source.preparedChart
        case .fallback:
            preconditionFailure("No chart content")
        }
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
        Group {
        let _ = foundationSettingsRevision
        switch content {
        case .deferred(let preparedChart, let explicitContext):
            let inputs = effectivePresentationInputs(explicit: explicitContext)
            AutoChartDeferredPresentationView(
                source: .prepared(
                    preparedChart,
                    AutoChartPresentationRequest(
                        preparedChart: preparedChart.id,
                        context: inputs.context,
                        formatters: inputs.formatters,
                        textResolver: inputs.textResolver)),
                analysisID: analysisID,
                selection: $selection,
                presentation: presentation)
                .id(preparedChart.id)
        case .deferredOverride(let source):
            let refreshed = source.resampling(
                formatters: formatters ?? effectiveFormatters,
                textResolver: textResolver ?? effectiveTextResolver)
            AutoChartDeferredPresentationView(
                source: refreshed,
                analysisID: analysisID,
                selection: $selection,
                presentation: presentation)
                .id(refreshed.preparedChart.id)
        case .immediateOverride(
            let source, let resolved, let sourceFormatters, let sourceTextResolver):
            let request = source.presentationRequest(
                formatters: sourceFormatters,
                textResolver: sourceTextResolver)
            let refreshed = request.id == resolved.requestID
                ? resolved
                : source.cachedRePresentation(request: request)
                    ?? source.rePresent(request: request)
            AutoChartView(
                resolvedPresentedChart: refreshed,
                analysisID: analysisID,
                selection: $selection,
                presentation: presentation)
                .id(refreshed.preparedChart.id)
        case .fallback(let fallback):
            VStack(alignment: .leading, spacing: 10) {
                ContentUnavailableView(
                    effectiveTextResolver(.init(
                        category: .interface,
                        code: .chartUnavailable,
                        defaultText: "Chart unavailable")),
                    systemImage: "tablecells",
                    description: Text(effectiveTextResolver(fallback.message)))
                if presentation.chrome.contains(.diagnostics) {
                    ForEach(Array(fallback.diagnostics.enumerated()), id: \.offset) {
                        _, diagnostic in
                        Label(
                            effectiveTextResolver(diagnostic.messageValue),
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        case .chart:
            let chart = VStack(alignment: .leading, spacing: 10) {
            if presentation.chrome.contains(.title), !displayTitle.isEmpty {
                Text(displayTitle)
                    .font(isCompact ? theme.labelFont.weight(.semibold) : theme.titleFont)
                    .lineLimit(isCompact ? 2 : nil)
            }
            if validation.isValid {
                accessibleChartBody
                    .frame(height: presentation.plotHeight)
                if presentation.chrome.contains(.selectionSummary),
                    ownsSelection, let first = selection.first
                {
                    let summary = first.presentation(
                        columns: snapshot.columns,
                        formatters: effectiveFormatters,
                        textResolver: effectiveTextResolver,
                        resolvedDimensionLabel: resolvedSelectionDimensionLabel)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.label).font(theme.labelFont.weight(.semibold))
                            Text(summary.valueDescription).font(theme.labelFont).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        Button(effectiveTextResolver(.init(
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
                    Button(effectiveTextResolver(.init(
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
                    effectiveTextResolver(.init(
                        category: .interface,
                        code: .chartUnavailable,
                        defaultText: "Chart unavailable")),
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        validation.issues
                            .map { effectiveTextResolver($0.messageValue) }
                            .joined(separator: " ")))
            }
            if presentation.chrome.contains(.diagnostics) {
                ForEach(Array(preparedChart.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(
                    effectiveTextResolver(diagnostic.messageValue),
                    systemImage: "exclamationmark.triangle.fill")
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
        .onAppear {
            synchronizeInteractionState(from: selection)
        }
        .onChange(of: selectionOwnershipID) { _, _ in
            resetInteractionState()
            synchronizeInteractionState(from: selection)
        }
        .onChange(of: presentationRequestID) { _, _ in
            synchronizeInteractionState(from: selection)
        }
        .onChange(of: selection) { _, updated in
            synchronizeInteractionState(from: updated)
        }
        #if ATC_TEST_HOOKS
        if viewTestHooks != nil {
            chart.background {
                Color.clear
                .onAppear { reportViewStateForTesting() }
                .onChange(of: presentationRequestID) { _, _ in
                    reportViewStateForTesting()
                }
                .onChange(of: selectionOwnershipID) { _, _ in
                    reportViewStateForTesting()
                }
                .onChange(of: viewRevisionForTesting) { _, _ in
                    reportViewStateForTesting()
                }
                .onChange(of: zoomScale) { _, _ in reportViewStateForTesting() }
                .onChange(of: selection) { _, _ in reportViewStateForTesting() }
                .onChange(of: selectedCategory) { _, _ in reportViewStateForTesting() }
                .onChange(of: selectedAngle) { _, _ in reportViewStateForTesting() }
            }
        } else {
            chart
        }
        #else
        chart
        #endif
        }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            foundationSettingsRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSSystemTimeZoneDidChange)) { _ in
            foundationSettingsRevision &+= 1
        }
    }

    #if ATC_TEST_HOOKS
    private func reportViewStateForTesting() {
        guard let viewTestHooks, let presentedChartForTesting else { return }
        viewTestHooks.observe(AutoChartViewTestHookState(
            requestID: presentedChartForTesting.requestID,
            zoomScale: $zoomScale,
            zoomAnchor: $zoomAnchor,
            selectionCount: ownsSelection ? selection.count : 0,
            hasSelectionSummary: ownsSelection
                && presentation.chrome.contains(.selectionSummary),
            selectedCategory: selectedCategory,
            selectedAngle: selectedAngle,
            displayTitle: displayTitle,
            renderedXLabels: renderedData.compactMap(\.xLabel),
            facetDisplayValues: facetPanels.map(\.displayValue),
            sharedXCategoryDomain: sharedXCategoryDomain,
            kpiValueText: presentedKPI?.valueText,
            kpiTitle: presentedKPI?.title,
            kpiAccessibilityText: presentedKPI?.accessibilityText))
    }
    #endif

    @ViewBuilder
    private var accessibleChartBody: some View {
        #if canImport(Accessibility)
        if let descriptor = presentedAudioGraphDescriptor {
            AutoChartAccessibleChart(content: chartBody, descriptor: descriptor)
        } else {
            chartBody
        }
        #else
        chartBody
        #endif
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
            .environment(\.timeZone, effectiveFormatters.timeZone)
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
            .environment(\.timeZone, effectiveFormatters.timeZone)
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
            .annotation(position: .overlay) {
                if differentiateWithoutColor, let value = datum.yNumber {
                    Text(formattedMeasureValue(value, for: .axisTick))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
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
        .environment(\.timeZone, effectiveFormatters.timeZone)
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
                .annotation(position: .overlay) {
                    if differentiateWithoutColor {
                        Text(seriesValue(for: datum))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
        } else if specification.encoding.series != nil {
            mark
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(selectionOpacity(for: datum))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
                .annotation(position: .overlay) {
                    if differentiateWithoutColor {
                        Text(seriesValue(for: datum))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
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
                            .environment(\.timeZone, effectiveFormatters.timeZone)
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
                            .environment(\.timeZone, effectiveFormatters.timeZone)
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
            formatters: effectiveFormatters)
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
            formatters: effectiveFormatters)
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
            formatters: effectiveFormatters)
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
            name = effectiveFormatters.format(
                column: xColumn, value: .date(date), context: .markAccessibility)
        } else if let number = datum.xNumber {
            name = effectiveFormatters.format(
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
                    formatters: effectiveFormatters,
                    textResolver: effectiveTextResolver)
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
            textResolver: effectiveTextResolver)
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
            textResolver: effectiveTextResolver)
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
        guard ownsSelection else { return [] }
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
                        effectiveFormatters.format(
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
        return effectiveFormatters.format(
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
                        effectiveFormatters.format(
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
            selection.select(selectedMarks, togglingAsGroup: true)
            return
        }
        #endif
        selection = AutoChartSelectionSet(selectedMarks)
    }

    private func clearSelection() {
        synchronizeInteractionBindings(
            category: nil, date: nil, number: nil, angle: nil)
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
            selection.belongs(to: analysisID, preparedChartID: preparedChart.id)
        else {
            synchronizeInteractionBindings(
                category: nil, date: nil, number: nil, angle: nil)
            return
        }
        guard let datumIndex = data.firstIndex(where: { $0.id == selectedMark.markID })
        else {
            synchronizeInteractionBindings(
                category: nil, date: nil, number: nil, angle: nil)
            return
        }
        let datum = data[datumIndex]
        switch specification.family {
        case .donut:
            let preceding = data[..<datumIndex].compactMap(\.yNumber).reduce(0, +)
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
        synchronizeInteractionBindings(
            category: nil, date: nil, number: nil, angle: nil)
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
    private let presentationContext: AutoChartPresentationContext?
    private let formatters: AutoChartFormatters?
    private let textResolver: AutoChartTextResolver?

    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        plotHeight: CGFloat? = AutoChartDefaultPlotHeight.plotOnly,
        interactions: AutoChartInteractions = .all,
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver? = nil
    ) {
        self.chart = preparedChart
        self.analysisID = analysisID
        self.selection = selection
        self.plotHeight = plotHeight
        self.interactions = interactions
        self.presentationContext = presentationContext
        self.formatters = formatters
        self.textResolver = textResolver
    }

    /// Compatibility overload for the original nonoptional presentation inputs.
    @_disfavoredOverload
    public init(
        preparedChart: AutoChartPreparedChart<RowID>,
        analysisID: AutoChartAnalysisID,
        selection: Binding<AutoChartSelectionSet<RowID>> = .constant(.init()),
        plotHeight: CGFloat? = AutoChartDefaultPlotHeight.plotOnly,
        interactions: AutoChartInteractions = .all,
        presentationContext: AutoChartPresentationContext? = nil,
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) {
        self.init(
            preparedChart: preparedChart,
            analysisID: analysisID,
            selection: selection,
            plotHeight: plotHeight,
            interactions: interactions,
            presentationContext: presentationContext,
            formatters: Optional(formatters),
            textResolver: Optional(textResolver))
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
            presentationContext: presentationContext,
            formatters: formatters,
            textResolver: textResolver)
    }
}
#endif
