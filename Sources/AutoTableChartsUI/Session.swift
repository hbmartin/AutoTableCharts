import Foundation
import Observation
import AutoTableCharts

/// Main-actor lifecycle owner for one independently displayed chart result.
@MainActor
@Observable
public final class AutoChartSession<RowID: Hashable & Sendable> {
    public enum State: Sendable {
        case idle
        case analyzing(AutoChartProgress?)
        case preparing(AutoChartAnalysis<RowID>, AutoChartProgress?)
        case ready(AutoChartAnalysis<RowID>, AutoChartPresentedChart<RowID>?)
        case fallback(AutoChartAnalysis<RowID>, AutoChartFallback?)
        case failed(AutoChartFailure)
    }

    public private(set) var state: State = .idle
    public private(set) var preference: AutoChartPreference = .automatic
    /// The requested chart choice, including while a prior chart remains visible,
    /// cached preparation is pending, or a retryable attempt has failed.
    public private(set) var currentRecommendation: AutoChartRecommendation?
    public var selection = AutoChartSelectionSet<RowID>()

    /// True while the session is resolving a new presentation payload. A ready
    /// chart may remain visible while this is true.
    public var isPresentationPending: Bool {
        presentationRequestID != nil
    }

    /// True while a visible ready chart is being replaced by preference or
    /// presentation work. Initial loading and preparation are reflected in state.
    public var isChartUpdatePending: Bool {
        guard case .ready(_, let presented?) = state else { return false }
        _ = presented
        return preferenceUpdatePending || presentationRequestID != nil
    }

    /// The resolver currently governing presentation work, including any
    /// environment override applied by ``AutoChartSessionView``.
    package var presentationTextResolver: AutoChartTextResolver {
        presentationConfiguration.textResolver
    }

    private struct PresentationConfiguration {
        var context = AutoChartPresentationContext()
        var formatters: AutoChartFormatters?
        var textResolver = AutoChartTextResolver.default

        func applying(_ overrides: PresentationOverrides) -> Self {
            Self(
                context: overrides.context ?? context,
                formatters: overrides.formatters ?? formatters,
                textResolver: overrides.textResolver ?? textResolver)
        }
    }

    private struct PresentationOverrides {
        var context: AutoChartPresentationContext?
        var formatters: AutoChartFormatters?
        var textResolver: AutoChartTextResolver?
    }

    private struct PresentationTarget {
        let analysis: AutoChartAnalysis<RowID>
        let chart: AutoChartPreparedChart<RowID>
        let keepsVisiblePresentation: Bool
    }

    private let cache: AutoChartCache
    private let analyzer: AutoChartAnalyzer
    private let presenter: AutoChartPresenter
    private var request: AutoChartRequest<RowID>?
    private var strategy: AutoChartPreparationStrategy = .preferredOrPrimary
    private var presentationConfiguration = PresentationConfiguration()
    private var loadedPresentationConfiguration = PresentationConfiguration()
    private var environmentPresentationOverrides = PresentationOverrides()
    private var generation: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var recommendationTask: Task<Void, Never>?
    @ObservationIgnored private var observedFailureEpisodes:
        [AutoChartFailureScope: UUID] = [:]
    @ObservationIgnored private var failedRequestID: AutoChartRequestID?
    private var presentationRequestID: AutoChartPresentationRequestID?
    private var presentationTarget: PresentationTarget?
    private var preferenceUpdatePending = false
    #if ATC_TEST_HOOKS
    @ObservationIgnored package var attemptDidStartForTesting: (() -> Void)?
    @ObservationIgnored package var presentationFailureForTesting: AutoChartFailure?
    @ObservationIgnored package var environmentApplicationForTesting: (() -> Void)?
    #endif

    public init(
        cache: AutoChartCache = AutoChartCache(),
        presenter: AutoChartPresenter = AutoChartPresenter()
    ) {
        self.cache = cache
        self.analyzer = AutoChartAnalyzer(cache: cache)
        self.presenter = presenter
    }

    deinit {
        task?.cancel()
        presentationTask?.cancel()
        recommendationTask?.cancel()
    }

    /// Starts or supersedes a request using the session's stored preference.
    ///
    /// A preference set before the first request, or retained from a prior request,
    /// becomes the default when this overload is used. Replacement requests clear
    /// visible state immediately.
    public func load(
        _ request: AutoChartRequest<RowID>,
        preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
        presentationContext: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) {
        load(
            request,
            preference: preference,
            preparation: preparation,
            presentationContext: presentationContext,
            formatters: formatters,
            textResolver: textResolver)
    }

    /// Starts or supersedes a request with an explicit preference.
    ///
    /// The supplied preference replaces the session's stored preference.
    /// Replacement requests clear visible state immediately.
    public func load(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
        presentationContext: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) {
        loadedPresentationConfiguration = PresentationConfiguration(
            context: presentationContext,
            formatters: formatters,
            textResolver: textResolver)
        start(
            request,
            preference: preference,
            preparation: preparation,
            presentationConfiguration: effectivePresentationConfiguration,
            clearsVisibleState: self.request?.id != request.id)
    }

    /// Selects and prepares an alternative without changing analysis identity.
    /// Selecting the stored preference is a no-op.
    public func select(_ recommendationID: AutoChartRecommendationID) {
        setPreference(.chart(.specific(recommendationID)))
    }

    /// Reconciles a new preference against the current analysis and prepared-chart cache.
    ///
    /// Reapplying the stored preference is always a no-op; call ``retry()`` to
    /// start another attempt with an unchanged preference. Before a request is
    /// loaded, this stores the default used by ``load(_:preparation:presentationContext:formatters:textResolver:)``.
    /// After ``cancel()``, a different preference may restart the retained request;
    /// after ``unload()``, it is stored without starting work.
    public func setPreference(_ preference: AutoChartPreference) {
        guard preference != self.preference else { return }
        guard let request else {
            self.preference = preference
            return
        }
        if case .ready(let displayedAnalysis, let presented?) = state,
            let base: AutoChartAnalysis<RowID> = cache.completedAnalysis(
                for: request.id),
            base.id == displayedAnalysis.id,
            Self.canResolveFromCatalog(preference, in: base),
            Self.canReusePreparedChart(
                presented.preparedChart, strategy: strategy,
                analysis: displayedAnalysis, base: base)
        {
            let resolution = base.resolve(preference)
            if resolution.recommendation?.id == presented.preparedChart.recommendation.id {
                if preferenceUpdatePending {
                    generation &+= 1
                    task?.cancel()
                    task = nil
                    preferenceUpdatePending = false
                }
                self.preference = preference
                currentRecommendation = resolution.recommendation
                let updated = base.replacingPresentation(
                    preparedCharts: displayedAnalysis.preparedCharts,
                    resolution: resolution)
                state = .ready(updated, presented)
                schedulePresentation(
                    for: updated,
                    chart: presented.preparedChart,
                    keepsVisiblePresentation: true)
                return
            }
        }
        start(
            request,
            preference: preference,
            preparation: strategy,
            presentationConfiguration: presentationConfiguration,
            clearsVisibleState: false,
            keepsVisibleReadyChart: true)
    }

    /// Schedules presentation rebuilding for the current prepared chart without
    /// replacing formatter or text-resolver configuration. The current ready
    /// presentation remains visible until its replacement is available.
    public func setPresentationContext(_ context: AutoChartPresentationContext) {
        loadedPresentationConfiguration.context = context
        rebuildEffectivePresentation()
    }

    /// Replaces the context and formatter configuration while preserving the
    /// text resolver supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?
    ) {
        loadedPresentationConfiguration.context = context
        loadedPresentationConfiguration.formatters = formatters
        rebuildEffectivePresentation()
    }

    /// Replaces the context and text resolver while preserving the formatter
    /// configuration supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        textResolver: AutoChartTextResolver
    ) {
        loadedPresentationConfiguration.context = context
        loadedPresentationConfiguration.textResolver = textResolver
        rebuildEffectivePresentation()
    }

    /// Replaces the complete presentation configuration without repeating analysis.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver
    ) {
        loadedPresentationConfiguration = PresentationConfiguration(
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        rebuildEffectivePresentation()
    }

    /// Applies optional SwiftUI environment overrides on top of the values
    /// supplied by `load`, restoring those values when an override disappears.
    package func applyPresentationEnvironment(
        context: AutoChartPresentationContext?,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver?
    ) {
        #if ATC_TEST_HOOKS
        environmentApplicationForTesting?()
        #endif
        environmentPresentationOverrides = PresentationOverrides(
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        rebuildEffectivePresentation()
    }

    private var effectivePresentationConfiguration: PresentationConfiguration {
        loadedPresentationConfiguration.applying(environmentPresentationOverrides)
    }

    private func rebuildEffectivePresentation() {
        rebuildPresentation(effectivePresentationConfiguration)
    }

    private func rebuildPresentation(_ configuration: PresentationConfiguration) {
        presentationConfiguration = configuration
        if preferenceUpdatePending { return }
        if let presentationTarget {
            schedulePresentation(
                for: presentationTarget.analysis,
                chart: presentationTarget.chart,
                keepsVisiblePresentation: presentationTarget.keepsVisiblePresentation)
            return
        }
        switch state {
        case .ready(let analysis, _):
            guard let chart = analysis.primaryChart else { return }
            schedulePresentation(
                for: analysis,
                chart: chart,
                keepsVisiblePresentation: true)
        case .preparing(let analysis, let progress)
            where progress?.phase == .presentationPreparation:
            guard let chart = analysis.primaryChart else { return }
            schedulePresentation(
                for: analysis,
                chart: chart,
                keepsVisiblePresentation: false)
        default:
            presentationGeneration &+= 1
            presentationTask?.cancel()
            presentationTask = nil
            presentationRequestID = nil
            presentationTarget = nil
        }
    }

    /// Restarts the retained request using the stored preference.
    ///
    /// A failed attempt begins a new failure episode, even if ``cancel()`` was
    /// called after the failure. Cancelling a nonfailed attempt and retrying with
    /// the same preference resumes it without resetting shared failure history or
    /// clearing its request-scoped recommendation. Once preference resolution
    /// completes, retrying with an unchanged preference preserves that
    /// recommendation synchronously, including after cancelling a failed attempt.
    public func retry() {
        retry(preference: preference)
    }

    /// Restarts the retained request using an explicit preference.
    ///
    /// A failed attempt begins a new failure episode, even if ``cancel()`` was
    /// called after the failure. Cancelling a nonfailed attempt and retrying with
    /// the same preference resumes it without resetting shared failure history or
    /// clearing its request-scoped recommendation. Once preference resolution
    /// completes, any retry with an unchanged preference preserves that
    /// recommendation synchronously, including after cancelling a failed attempt;
    /// a changed preference clears it before work begins.
    public func retry(preference: AutoChartPreference) {
        guard let request else { return }
        let isIdle = if case .idle = state { true } else { false }
        let resumesCancelledRequest = isIdle
            && failedRequestID != request.id
            && preference == self.preference
        start(
            request,
            preference: preference,
            preparation: strategy,
            presentationConfiguration: presentationConfiguration,
            clearsVisibleState: !resumesCancelledRequest,
            restartsAttemptedFailureEpisodes: !resumesCancelledRequest)
    }

    /// Cancels the current attempt and clears selection without forgetting the request.
    /// Cancellation never becomes a failure state. A later different preference
    /// may start new work for the retained request; use ``unload()`` to prevent that.
    public func cancel() {
        cancelInFlightWork(clearsSelection: true)
        state = .idle
    }

    /// Ends ownership of the current request and its loaded presentation
    /// configuration while preserving the session's stored preference and active
    /// environment overrides. Unlike `cancel`, a later preference change cannot
    /// restart the unloaded request.
    public func unload() {
        cancel()
        request = nil
        failedRequestID = nil
        currentRecommendation = nil
        loadedPresentationConfiguration = PresentationConfiguration()
        presentationConfiguration = effectivePresentationConfiguration
    }

    #if ATC_TEST_HOOKS
    /// Injects a terminal attempt after analysis for deterministic host UI tests.
    public func failCurrentAttemptForTesting(_ failure: AutoChartFailure) {
        guard let request else {
            preconditionFailure("A session failure requires a loaded request.")
        }
        publishFailure(failure, for: request.id)
    }
    #endif

    private func start(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        preparation: AutoChartPreparationStrategy,
        presentationConfiguration: PresentationConfiguration,
        clearsVisibleState: Bool,
        keepsVisibleReadyChart: Bool = false,
        restartsAttemptedFailureEpisodes: Bool = false
    ) {
        let changesRequest = self.request?.id != request.id
        let changesPreference = preference != self.preference
        let keepsReadyChart: Bool
        if keepsVisibleReadyChart, case .ready(_, let presented) = state,
            presented != nil,
            self.request?.id == request.id
        {
            keepsReadyChart = true
        } else {
            keepsReadyChart = false
        }
        let visibleAnalysis: AutoChartAnalysis<RowID>? = if keepsReadyChart,
            case .ready(let analysis, _) = state
        {
            analysis
        } else {
            nil
        }
        let failureEpisodeContext: AutoChartFailureEpisodeContext
        if observedFailureEpisodes.isEmpty, !restartsAttemptedFailureEpisodes {
            failureEpisodeContext = .coalescing
        } else {
            let episodeState = cache.failureEpisodeState(
                for: request.id,
                observedEpisodes: observedFailureEpisodes,
                restartsCurrentEpisodes: restartsAttemptedFailureEpisodes)
            observedFailureEpisodes = episodeState.observedEpisodes
            failureEpisodeContext = episodeState.context
        }
        failedRequestID = nil
        let shouldClearSelection = clearsVisibleState
            || (changesPreference && !keepsReadyChart)
        cancelInFlightWork(clearsSelection: shouldClearSelection)
        let token = generation
        self.request = request
        self.preference = preference
        self.strategy = preparation
        self.presentationConfiguration = presentationConfiguration
        preferenceUpdatePending = keepsReadyChart
        if changesRequest || changesPreference {
            currentRecommendation = nil
        }
        let completed: AutoChartAnalysis<RowID>? = cache.completedAnalysis(
            for: request.id)
        let recommendationSource = completed ?? visibleAnalysis
        if let recommendationSource {
            beginRecommendationResolution(
                for: recommendationSource,
                preference: preference,
                token: token)
        }
        let completedForPreparation: AutoChartAnalysis<RowID>?
        if preparation != .none,
            let completed,
            Self.canPrepareChart(for: preference, in: completed)
        {
            completedForPreparation = completed
            if !keepsReadyChart { state = .preparing(completed, nil) }
        } else {
            completedForPreparation = nil
            if !keepsReadyChart { state = .analyzing(nil) }
        }
        let analyzer = self.analyzer
        task = Task { [weak self, analyzer] in
            do {
                let analysis = try await analyzer.analyze(
                    request,
                    preference: preference,
                    preparation: preparation,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            if let completedForPreparation {
                                guard progress.phase == .chartPreparation
                                        || progress.phase == .presentationPreparation,
                                    case .preparing(let current, _) = self.state,
                                    current.id == completedForPreparation.id
                                else { return }
                                self.state = .preparing(current, progress)
                            } else if case .analyzing = self.state {
                                self.state = .analyzing(progress)
                            }
                        }
                    },
                    failureEpisodes: failureEpisodeContext,
                    preferenceResolution: { [weak self] resolution in
                        await MainActor.run {
                            guard let self,
                                self.generation == token,
                                self.request?.id == request.id,
                                self.preference == preference
                            else { return }
                            self.recommendationTask?.cancel()
                            self.recommendationTask = nil
                            self.currentRecommendation = resolution.recommendation
                        }
                    })
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.task = nil
                self.preferenceUpdatePending = false
                self.recommendationTask?.cancel()
                self.recommendationTask = nil
                self.currentRecommendation = analysis.preferenceResolution?.recommendation
                if case .tableFallback(let fallback) = analysis.outcome {
                    if !selection.isEmpty { selection.removeAll() }
                    state = .fallback(analysis, fallback)
                    return
                }
                guard let chart = analysis.primaryChart else {
                    if !selection.isEmpty { selection.removeAll() }
                    state = .fallback(analysis, nil)
                    return
                }
                schedulePresentation(
                    for: analysis,
                    chart: chart,
                    keepsVisiblePresentation: keepsReadyChart)
            } catch is CancellationError {
                // Supersession and explicit cancellation intentionally publish no failure.
            } catch let failure as AutoChartFailure {
                guard let self, self.generation == token else { return }
                self.publishFailure(
                    failure,
                    for: request.id,
                    recommendationSource: recommendationSource)
            } catch {
                guard let self, self.generation == token else { return }
                self.publishFailure(
                    AutoChartFailure(
                        stage: .recommendation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.session.internalFailure",
                        message: String(describing: error)),
                    for: request.id,
                    recommendationSource: recommendationSource)
            }
        }
        #if ATC_TEST_HOOKS
        if let attemptDidStartForTesting, !AttemptHookScope.isInvoking {
            AttemptHookScope.$isInvoking.withValue(true) {
                attemptDidStartForTesting()
            }
        }
        #endif
    }

    private func publishFailure(
        _ failure: AutoChartFailure,
        for requestID: AutoChartRequestID,
        recommendationSource: AutoChartAnalysis<RowID>? = nil
    ) {
        let retainedRecommendationSource = recommendationSource
            ?? recommendationSourceFromState(for: requestID)
        cancelInFlightWork(clearsSelection: true)
        failedRequestID = requestID
        observedFailureEpisodes = cache.recordingFailureEpisode(
            for: requestID,
            episodeID: failure.episodeID,
            observedEpisodes: observedFailureEpisodes)
        state = .failed(failure)
        guard let request, request.id == requestID else { return }
        restoreRecommendation(
            request: request,
            preference: preference,
            token: generation,
            fallback: retainedRecommendationSource)
    }

    private func cancelInFlightWork(clearsSelection: Bool) {
        generation &+= 1
        presentationGeneration &+= 1
        task?.cancel()
        presentationTask?.cancel()
        recommendationTask?.cancel()
        task = nil
        presentationTask = nil
        recommendationTask = nil
        presentationRequestID = nil
        presentationTarget = nil
        preferenceUpdatePending = false
        if clearsSelection, !selection.isEmpty { selection.removeAll() }
    }

    private func restoreRecommendation(
        request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        token: UInt64,
        fallback: AutoChartAnalysis<RowID>?
    ) {
        guard currentRecommendation == nil,
            recommendationTask == nil
        else { return }
        let completed: AutoChartAnalysis<RowID>? = cache.completedAnalysis(
            for: request.id)
        guard let source = completed
            ?? fallback.flatMap({ $0.request == request.id ? $0 : nil })
        else { return }
        beginRecommendationResolution(
            for: source, preference: preference, token: token)
    }

    private func recommendationSourceFromState(
        for requestID: AutoChartRequestID
    ) -> AutoChartAnalysis<RowID>? {
        let analysis: AutoChartAnalysis<RowID>?
        switch state {
        case .preparing(let current, _), .ready(let current, _),
            .fallback(let current, _):
            analysis = current
        case .idle, .analyzing, .failed:
            analysis = nil
        }
        return analysis?.request == requestID ? analysis : nil
    }

    private func beginRecommendationResolution(
        for analysis: AutoChartAnalysis<RowID>,
        preference: AutoChartPreference,
        token: UInt64
    ) {
        if let catalogRecommendation = Self.catalogRecommendation(
            for: preference, in: analysis)
        {
            currentRecommendation = catalogRecommendation
            return
        }
        guard case .chart(let chartPreference) = preference,
            case .charts = analysis.outcome
        else {
            currentRecommendation = nil
            return
        }
        let requestedSpecificationID: AutoChartSpecificationID? = switch chartPreference {
        case .recommended: nil
        case .specific(let id): id.specificationID
        }
        let retainsCurrentRecommendation = requestedSpecificationID.map { requestedID in
            currentRecommendation?.id.specificationID == requestedID
        } ?? false
        if !retainsCurrentRecommendation {
            currentRecommendation = nil
        }
        recommendationTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try? analysis.resolveCancellable(preference).recommendation
            }
            let resolved = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() })
            guard let self, self.generation == token,
                self.request?.id == analysis.request,
                self.preference == preference,
                !Task.isCancelled
            else { return }
            self.currentRecommendation = resolved
            self.recommendationTask = nil
        }
    }

    private static func catalogRecommendation(
        for preference: AutoChartPreference,
        in analysis: AutoChartAnalysis<RowID>
    ) -> AutoChartRecommendation? {
        guard case .charts(let catalog) = analysis.outcome else { return nil }
        switch preference {
        case .automatic, .chart(.recommended): return catalog.primary
        case .chart(.specific(let id)):
            let currentID = AutoChartRecommendationID(
                policyVersion: AutoTableCharts.recommendationPolicyVersion,
                specificationID: id.specificationID)
            return catalog.recommendation(for: currentID)
        case .table: return nil
        }
    }

    private func schedulePresentation(
        for analysis: AutoChartAnalysis<RowID>,
        chart: AutoChartPreparedChart<RowID>,
        keepsVisiblePresentation: Bool
    ) {
        presentationTarget = PresentationTarget(
            analysis: analysis,
            chart: chart,
            keepsVisiblePresentation: keepsVisiblePresentation)
        let context = presentationConfiguration.context
        let formatters = presentationConfiguration.formatters ?? AutoChartFormatters(
            locale: context.locale,
            timeZone: context.timeZone)
        let textResolver = presentationConfiguration.textResolver
        let request = AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        let requestID = request.id
        if case .ready(_, let presented?) = state,
            presented.requestID == requestID
        {
            if presentationRequestID != nil {
                presentationGeneration &+= 1
                presentationTask?.cancel()
                presentationTask = nil
                presentationRequestID = nil
            }
            presentationTarget = nil
            if !selection.belongs(to: analysis.id, preparedChartID: chart.id) {
                selection.removeAll()
            }
            state = .ready(analysis, presented)
            return
        }
        guard presentationRequestID != requestID else { return }

        presentationGeneration &+= 1
        let presentationToken = presentationGeneration
        presentationTask?.cancel()
        presentationRequestID = requestID
        if !keepsVisiblePresentation {
            state = .preparing(
                analysis,
                AutoChartProgress(phase: .presentationPreparation))
        }
        let presenter = presenter
        presentationTask = Task { [weak self, presenter] in
            do {
                #if ATC_TEST_HOOKS
                if let failure = self?.presentationFailureForTesting {
                    throw failure
                }
                #endif
                let presented = try await presenter.presentCancellable(
                    chart,
                    request: request)
                try Task.checkCancellation()
                guard let self,
                    self.presentationGeneration == presentationToken
                else { return }
                self.presentationTask = nil
                self.presentationRequestID = nil
                self.presentationTarget = nil
                let latestAnalysis: AutoChartAnalysis<RowID>
                if case .ready(let current, _) = self.state,
                    current.id == analysis.id,
                    current.primaryChart?.id == chart.id
                {
                    latestAnalysis = current
                } else {
                    latestAnalysis = analysis
                }
                if !self.selection.belongs(
                    to: latestAnalysis.id, preparedChartID: chart.id)
                {
                    self.selection.removeAll()
                }
                self.state = .ready(latestAnalysis, presented)
            } catch is CancellationError {
                guard let self, self.presentationGeneration == presentationToken else {
                    return
                }
                self.presentationTask = nil
                self.presentationRequestID = nil
                self.presentationTarget = nil
            } catch {
                guard let self,
                    self.presentationGeneration == presentationToken
                else { return }
                self.publishFailure(
                    AutoChartFailure(
                        stage: .presentationPreparation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.session.presentationFailure",
                        message: String(describing: error)),
                    for: analysis.request)
            }
        }
    }

    private static func canPrepareChart(
        for preference: AutoChartPreference,
        in analysis: AutoChartAnalysis<RowID>
    ) -> Bool {
        if case .table = preference { return false }
        guard case .charts(let catalog) = analysis.outcome else { return false }
        return catalog.primary != nil
    }

    private static func canResolveFromCatalog(
        _ preference: AutoChartPreference,
        in analysis: AutoChartAnalysis<RowID>
    ) -> Bool {
        guard case .charts(let catalog) = analysis.outcome else { return false }
        switch preference {
        case .automatic, .table, .chart(.recommended):
            return true
        case .chart(.specific(let id)):
            let currentID = AutoChartRecommendationID(
                policyVersion: AutoTableCharts.recommendationPolicyVersion,
                specificationID: id.specificationID)
            return catalog.containsCataloged(currentID)
        }
    }

    private static func canReusePreparedChart(
        _ chart: AutoChartPreparedChart<RowID>,
        strategy: AutoChartPreparationStrategy,
        analysis: AutoChartAnalysis<RowID>,
        base: AutoChartAnalysis<RowID>
    ) -> Bool {
        guard analysis.preparedCharts[chart.recommendation.id]?.id == chart.id,
            case .charts(let catalog) = base.outcome
        else { return false }
        switch strategy {
        case .none:
            return false
        case .primary:
            return catalog.primary?.id == chart.recommendation.id
        case .preferredOrPrimary:
            return true
        case .allCataloged:
            return catalog.cataloged.allSatisfy {
                analysis.preparedCharts[$0.id] != nil
            }
        }
    }
}

#if ATC_TEST_HOOKS
private enum AttemptHookScope {
    @TaskLocal static var isInvoking = false
}
#endif
