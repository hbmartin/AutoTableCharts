import Foundation
import Observation
import AutoTableCharts

/// The synchronous effect of loading a request into an ``AutoChartSession``.
public enum AutoChartLoadApplication: Hashable, Sendable {
    /// The load was installed and remained current when the call returned.
    case started
    /// Synchronous reentrancy replaced, cancelled, or unloaded the load.
    case superseded
}

/// The effect of applying a preference to an ``AutoChartSession``.
public enum AutoChartPreferenceApplication: Hashable, Sendable {
    /// The supplied preference already matched the session's stored preference.
    case unchanged
    /// The preference was stored as the default for a future load.
    case stored
    /// The preference was reconciled using an existing prepared chart.
    ///
    /// Presentation-only work may still be pending or begin after this result.
    case reusedPreparedChart
    /// A replacement session pass was installed and remained current on return.
    case startedReplacement
    /// An application, including prepared-chart reuse, began but synchronous
    /// reentrancy made it noncurrent.
    ///
    /// This includes replacement, retry, cancellation, and unload operations.
    case superseded
}

private struct AutoChartSessionPublishedChanges: OptionSet {
    let rawValue: UInt8

    static let state = Self(rawValue: 1 << 0)
    static let preference = Self(rawValue: 1 << 1)
    static let currentRecommendation = Self(rawValue: 1 << 2)
    static let selection = Self(rawValue: 1 << 3)
    static let presentationPending = Self(rawValue: 1 << 4)
    static let chartUpdatePending = Self(rawValue: 1 << 5)
    static let presentationTextResolver = Self(rawValue: 1 << 6)
}

/// Main-actor lifecycle owner for one independently displayed chart result.
@MainActor
@Observable
public final class AutoChartSession<RowID: Hashable & Sendable> {
    public enum State: Sendable {
        case idle
        case analyzing(AutoChartProgress?)
        case preparing(AutoChartAnalysis<RowID>, AutoChartProgress?)
        /// Analysis and presentation for the currently visible chart.
        ///
        /// When a replacement is pending, ``currentRecommendation`` describes
        /// the requested chart while these associated values remain paired.
        case ready(AutoChartAnalysis<RowID>, AutoChartPresentedChart<RowID>?)
        case fallback(AutoChartAnalysis<RowID>, AutoChartFallback?)
        case failed(AutoChartFailure)
    }

    private struct PublishedValues {
        var state: State = .idle
        var preference: AutoChartPreference = .automatic
        var currentRecommendation: AutoChartRecommendation?
        var selection = AutoChartSelectionSet<RowID>()
    }

    private typealias PublishedChanges = AutoChartSessionPublishedChanges

    @ObservationIgnored private var publishedValues = PublishedValues()
    @ObservationIgnored private var lifecycleRevision: UInt64 = 0

    public var state: State {
        access(keyPath: \.state)
        return publishedValues.state
    }
    public var preference: AutoChartPreference {
        access(keyPath: \.preference)
        return publishedValues.preference
    }
    /// The requested chart choice, including while a prior chart remains visible,
    /// cached preparation is pending, or a retryable attempt has failed.
    public var currentRecommendation: AutoChartRecommendation? {
        access(keyPath: \.currentRecommendation)
        return publishedValues.currentRecommendation
    }
    public var selection: AutoChartSelectionSet<RowID> {
        get {
            access(keyPath: \.selection)
            return publishedValues.selection
        }
        set {
            let revision = lifecycleRevision
            withMutation(keyPath: \.selection) {
                guard lifecycleRevision == revision else { return }
                publishedValues.selection = newValue
            }
        }
    }

    /// True while the session is resolving a new presentation payload. A ready
    /// chart may remain visible while this is true.
    public var isPresentationPending: Bool {
        access(keyPath: \.isPresentationPending)
        return presentationRequestID != nil
    }

    /// True while a visible ready chart is being replaced by preference or
    /// presentation work. Initial loading and preparation are reflected in state.
    public var isChartUpdatePending: Bool {
        access(keyPath: \.isChartUpdatePending)
        guard case .ready(_, let presented?) = publishedValues.state else { return false }
        _ = presented
        return preferenceUpdatePending || presentationRequestID != nil
    }

    /// The resolver currently governing presentation work, including any
    /// environment override applied by ``AutoChartSessionView``.
    package var presentationTextResolver: AutoChartTextResolver {
        access(keyPath: \.presentationTextResolver)
        return presentationConfiguration.textResolver
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

    private struct StartToken {
        let generation: UInt64
        let lifecycleRevision: UInt64
    }

    private let cache: AutoChartCache
    private let analyzer: AutoChartAnalyzer
    private let presenter: AutoChartPresenter
    @ObservationIgnored private var request: AutoChartRequest<RowID>?
    @ObservationIgnored private var strategy: AutoChartPreparationStrategy = .preferredOrPrimary
    @ObservationIgnored private var presentationConfiguration = PresentationConfiguration()
    @ObservationIgnored private var loadedPresentationConfiguration = PresentationConfiguration()
    @ObservationIgnored private var environmentPresentationOverrides = PresentationOverrides()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var presentationGeneration: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var recommendationTask: Task<Void, Never>?
    @ObservationIgnored private var observedFailureEpisodes:
        [AutoChartFailureScope: UUID] = [:]
    @ObservationIgnored private var failedRequestID: AutoChartRequestID?
    @ObservationIgnored private var presentationRequestID: AutoChartPresentationRequestID?
    @ObservationIgnored private var presentationTarget: PresentationTarget?
    @ObservationIgnored private var preferenceUpdatePending = false
    #if ATC_TEST_HOOKS
    @ObservationIgnored package var attemptDidStartForTesting: (() -> Void)?
    @ObservationIgnored package var presentationFailureForTesting: AutoChartFailure?
    @ObservationIgnored package var environmentApplicationForTesting: (() -> Void)?
    package var hasRecommendationTaskForTesting: Bool {
        recommendationTask != nil
    }
    #endif

    public init(
        cache: AutoChartCache = AutoChartCache(),
        presenter: AutoChartPresenter = AutoChartPresenter()
    ) {
        self.cache = cache
        self.analyzer = AutoChartAnalyzer(cache: cache)
        self.presenter = presenter
    }

    private func reserveLifecycleRevision() -> UInt64 {
        lifecycleRevision &+= 1
        return lifecycleRevision
    }

    @discardableResult
    private func publish(
        revision: UInt64,
        changes: PublishedChanges,
        mutation: @escaping () -> Void
    ) -> Bool {
        guard lifecycleRevision == revision else { return false }
        var didPublish = false
        let commit = {
            guard self.lifecycleRevision == revision else { return }
            mutation()
            didPublish = true
        }
        let publishResolver = {
            if changes.contains(.presentationTextResolver) {
                self.withMutation(keyPath: \.presentationTextResolver, commit)
            } else {
                commit()
            }
        }
        let publishChartUpdatePending = {
            if changes.contains(.chartUpdatePending) {
                self.withMutation(
                    keyPath: \.isChartUpdatePending,
                    publishResolver)
            } else {
                publishResolver()
            }
        }
        let publishPresentationPending = {
            if changes.contains(.presentationPending) {
                self.withMutation(
                    keyPath: \.isPresentationPending,
                    publishChartUpdatePending)
            } else {
                publishChartUpdatePending()
            }
        }
        let publishSelection = {
            if changes.contains(.selection) {
                self.withMutation(keyPath: \.selection, publishPresentationPending)
            } else {
                publishPresentationPending()
            }
        }
        let publishRecommendation = {
            if changes.contains(.currentRecommendation) {
                self.withMutation(
                    keyPath: \.currentRecommendation,
                    publishSelection)
            } else {
                publishSelection()
            }
        }
        let publishPreference = {
            if changes.contains(.preference) {
                self.withMutation(keyPath: \.preference, publishRecommendation)
            } else {
                publishRecommendation()
            }
        }
        if changes.contains(.state) {
            withMutation(keyPath: \.state, publishPreference)
        } else {
            publishPreference()
        }
        return didPublish
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
    @discardableResult
    public func load(
        _ request: AutoChartRequest<RowID>,
        preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
        presentationContext: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartLoadApplication {
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
    @discardableResult
    public func load(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
        presentationContext: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartLoadApplication {
        let loadedPresentationConfiguration = PresentationConfiguration(
            context: presentationContext,
            formatters: formatters,
            textResolver: textResolver)
        let startToken = start(
            request,
            preference: preference,
            preparation: preparation,
            presentationConfiguration: loadedPresentationConfiguration.applying(
                environmentPresentationOverrides),
            loadedPresentationConfiguration: loadedPresentationConfiguration,
            clearsVisibleState: self.request?.id != request.id)
        guard generation == startToken.generation,
            lifecycleRevision == startToken.lifecycleRevision,
            self.request?.id == request.id,
            self.preference == preference
        else { return .superseded }
        return .started
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
        _ = applyPreference(preference)
    }

    /// Reconciles a new preference and reports how it was applied.
    ///
    /// A replacement is a new asynchronous session pass. Cached transitions such
    /// as switching to table presentation still count as replacements. Reusing a
    /// prepared chart does not, even when presentation-only work remains pending.
    public func applyPreference(
        _ preference: AutoChartPreference
    ) -> AutoChartPreferenceApplication {
        guard preference != self.preference else { return .unchanged }
        guard let request else {
            let revision = reserveLifecycleRevision()
            let installed = publish(
                revision: revision,
                changes: [.preference]
            ) {
                self.publishedValues.preference = preference
            }
            guard installed,
                lifecycleRevision == revision,
                self.preference == preference
            else { return .superseded }
            return .stored
        }
        if let base: AutoChartAnalysis<RowID> = cache.completedAnalysis(
            for: request.id)
        {
            for analysis in reusablePreparedChartAnalyses
            where analysis.id == base.id
                && Self.canResolveKnownPreparedChart(preference, in: analysis)
            {
                let resolution = analysis.resolve(preference)
                guard let recommendation = resolution.recommendation,
                    let chart = analysis.preparedCharts[recommendation.id],
                    Self.canReusePreparedChart(
                        chart, strategy: strategy,
                        analysis: analysis, base: base)
                else { continue }
                let updated = base.replacingPresentation(
                    preparedCharts: analysis.preparedCharts,
                    resolution: resolution)
                let keepsVisiblePresentation = readyState?.presented != nil
                let clearsSelection = presentationWillClearSelection(
                    analysis: updated,
                    chart: chart)
                let revision = reserveLifecycleRevision()
                let generation = self.generation &+ 1
                var changes: PublishedChanges = [
                    .state, .preference, .currentRecommendation,
                    .presentationPending, .chartUpdatePending,
                ]
                if clearsSelection { changes.insert(.selection) }
                let installed = publish(
                    revision: revision,
                    changes: changes
                ) {
                    self.cancelInFlightWork(
                        generation: generation,
                        clearsSelection: false,
                        preservesPresentation: true)
                    self.publishedValues.preference = preference
                    self.publishedValues.currentRecommendation = recommendation
                    self.installPresentation(
                        for: updated,
                        chart: chart,
                        keepsVisiblePresentation: keepsVisiblePresentation)
                }
                guard installed,
                    lifecycleRevision == revision,
                    self.generation == generation,
                    self.request?.id == request.id,
                    self.preference == preference
                else { return .superseded }
                return .reusedPreparedChart
            }
        }
        let token = start(
            request,
            preference: preference,
            preparation: strategy,
            presentationConfiguration: presentationConfiguration,
            clearsVisibleState: false,
            keepsVisibleReadyChart: true)
        guard generation == token.generation,
            lifecycleRevision == token.lifecycleRevision,
            self.request?.id == request.id,
            self.preference == preference
        else { return .superseded }
        return .startedReplacement
    }

    private var readyState: (
        analysis: AutoChartAnalysis<RowID>,
        presented: AutoChartPresentedChart<RowID>?
    )? {
        guard case .ready(let analysis, let presented) = state else {
            return nil
        }
        return (analysis, presented)
    }

    private var reusablePreparedChartAnalyses: [AutoChartAnalysis<RowID>] {
        var analyses: [AutoChartAnalysis<RowID>] = []
        if let readyState {
            analyses.append(readyState.analysis)
        }
        if task == nil, let presentationTarget {
            analyses.append(presentationTarget.analysis)
        }
        return analyses
    }

    /// Schedules presentation rebuilding for the current prepared chart without
    /// replacing formatter or text-resolver configuration. The current ready
    /// presentation remains visible until its replacement is available.
    public func setPresentationContext(_ context: AutoChartPresentationContext) {
        var loaded = loadedPresentationConfiguration
        loaded.context = context
        rebuildPresentation(
            loaded.applying(environmentPresentationOverrides),
            loadedPresentationConfiguration: loaded)
    }

    /// Replaces the context and formatter configuration while preserving the
    /// text resolver supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?
    ) {
        var loaded = loadedPresentationConfiguration
        loaded.context = context
        loaded.formatters = formatters
        rebuildPresentation(
            loaded.applying(environmentPresentationOverrides),
            loadedPresentationConfiguration: loaded)
    }

    /// Replaces the context and text resolver while preserving the formatter
    /// configuration supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        textResolver: AutoChartTextResolver
    ) {
        var loaded = loadedPresentationConfiguration
        loaded.context = context
        loaded.textResolver = textResolver
        rebuildPresentation(
            loaded.applying(environmentPresentationOverrides),
            loadedPresentationConfiguration: loaded)
    }

    /// Replaces the complete presentation configuration without repeating analysis.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver
    ) {
        let loaded = PresentationConfiguration(
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        rebuildPresentation(
            loaded.applying(environmentPresentationOverrides),
            loadedPresentationConfiguration: loaded)
    }

    /// Applies optional SwiftUI environment overrides on top of the values
    /// supplied by `load`, restoring those values when an override disappears.
    package func applyPresentationEnvironment(
        context: AutoChartPresentationContext?,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver?
    ) {
        let revision = reserveLifecycleRevision()
        #if ATC_TEST_HOOKS
        environmentApplicationForTesting?()
        #endif
        let overrides = PresentationOverrides(
            context: context,
            formatters: formatters,
            textResolver: textResolver)
        rebuildPresentation(
            loadedPresentationConfiguration.applying(overrides),
            environmentPresentationOverrides: overrides,
            reservedRevision: revision)
    }

    private var effectivePresentationConfiguration: PresentationConfiguration {
        loadedPresentationConfiguration.applying(environmentPresentationOverrides)
    }

    private func rebuildPresentation(
        _ configuration: PresentationConfiguration,
        loadedPresentationConfiguration: PresentationConfiguration? = nil,
        environmentPresentationOverrides: PresentationOverrides? = nil,
        reservedRevision: UInt64? = nil
    ) {
        let revision = reservedRevision ?? reserveLifecycleRevision()
        publish(
            revision: revision,
            changes: [
                .state, .presentationPending, .chartUpdatePending,
                .presentationTextResolver,
            ]) {
            if let loadedPresentationConfiguration {
                self.loadedPresentationConfiguration = loadedPresentationConfiguration
            }
            if let environmentPresentationOverrides {
                self.environmentPresentationOverrides = environmentPresentationOverrides
            }
            self.presentationConfiguration = configuration
            if self.preferenceUpdatePending { return }
            if let presentationTarget = self.presentationTarget {
                self.installPresentation(
                    for: presentationTarget.analysis,
                    chart: presentationTarget.chart,
                    keepsVisiblePresentation:
                        presentationTarget.keepsVisiblePresentation)
                return
            }
            if let readyState = self.readyState,
                let chart = readyState.analysis.primaryChart
            {
                self.installPresentation(
                    for: readyState.analysis,
                    chart: chart,
                    keepsVisiblePresentation: true)
                return
            }
            self.presentationGeneration &+= 1
            self.presentationTask?.cancel()
            self.presentationTask = nil
            self.presentationRequestID = nil
            self.presentationTarget = nil
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
        _ = start(
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
        let revision = reserveLifecycleRevision()
        let generation = self.generation &+ 1
        var changes: PublishedChanges = [
            .state, .presentationPending, .chartUpdatePending,
        ]
        if !selection.isEmpty { changes.insert(.selection) }
        publish(revision: revision, changes: changes) {
            self.cancelInFlightWork(
                generation: generation,
                clearsSelection: true)
            self.publishedValues.state = .idle
        }
    }

    /// Ends ownership of the current request and its loaded presentation
    /// configuration while preserving the session's stored preference and active
    /// environment overrides. Unlike `cancel`, a later preference change cannot
    /// restart the unloaded request.
    public func unload() {
        let revision = reserveLifecycleRevision()
        let generation = self.generation &+ 1
        var changes: PublishedChanges = [
            .state, .currentRecommendation, .presentationPending,
            .chartUpdatePending, .presentationTextResolver,
        ]
        if !selection.isEmpty { changes.insert(.selection) }
        publish(revision: revision, changes: changes) {
            self.cancelInFlightWork(
                generation: generation,
                clearsSelection: true)
            self.publishedValues.state = .idle
            self.request = nil
            self.failedRequestID = nil
            self.publishedValues.currentRecommendation = nil
            self.loadedPresentationConfiguration = PresentationConfiguration()
            self.presentationConfiguration = self.effectivePresentationConfiguration
        }
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
        loadedPresentationConfiguration: PresentationConfiguration? = nil,
        clearsVisibleState: Bool,
        keepsVisibleReadyChart: Bool = false,
        restartsAttemptedFailureEpisodes: Bool = false
    ) -> StartToken {
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
        let nextObservedFailureEpisodes: [AutoChartFailureScope: UUID]
        if observedFailureEpisodes.isEmpty, !restartsAttemptedFailureEpisodes {
            failureEpisodeContext = .coalescing
            nextObservedFailureEpisodes = observedFailureEpisodes
        } else {
            let episodeState = cache.failureEpisodeState(
                for: request.id,
                observedEpisodes: observedFailureEpisodes,
                restartsCurrentEpisodes: restartsAttemptedFailureEpisodes)
            nextObservedFailureEpisodes = episodeState.observedEpisodes
            failureEpisodeContext = episodeState.context
        }
        let shouldClearSelection = clearsVisibleState
            || (changesPreference && !keepsReadyChart)
        let completed: AutoChartAnalysis<RowID>? = cache.completedAnalysis(
            for: request.id)
        let recommendationSource = completed ?? visibleAnalysis
        let completedForPreparation: AutoChartAnalysis<RowID>?
        if preparation != .none,
            let completed,
            Self.canPrepareChart(for: preference, in: completed)
        {
            completedForPreparation = completed
        } else {
            completedForPreparation = nil
        }
        let token = generation &+ 1
        let revision = reserveLifecycleRevision()
        let analyzer = self.analyzer
        var changes: PublishedChanges = [
            .currentRecommendation, .presentationPending,
            .chartUpdatePending, .presentationTextResolver,
        ]
        if !keepsReadyChart { changes.insert(.state) }
        if changesPreference { changes.insert(.preference) }
        if shouldClearSelection, !selection.isEmpty { changes.insert(.selection) }
        let installed = publish(revision: revision, changes: changes) {
            self.cancelInFlightWork(
                generation: token,
                clearsSelection: shouldClearSelection)
            self.request = request
            self.publishedValues.preference = preference
            self.strategy = preparation
            self.presentationConfiguration = presentationConfiguration
            if let loadedPresentationConfiguration {
                self.loadedPresentationConfiguration = loadedPresentationConfiguration
            }
            self.observedFailureEpisodes = nextObservedFailureEpisodes
            self.failedRequestID = nil
            self.preferenceUpdatePending = keepsReadyChart
            if changesRequest || changesPreference {
                self.publishedValues.currentRecommendation = nil
            }
            if let recommendationSource {
                self.beginRecommendationResolution(
                    for: recommendationSource,
                    preference: preference,
                    token: token)
            }
            if !keepsReadyChart {
                if let completedForPreparation {
                    self.publishedValues.state = .preparing(
                        completedForPreparation, nil)
                } else {
                    self.publishedValues.state = .analyzing(nil)
                }
            }
            self.task = Task { [weak self, analyzer] in
                do {
                    let analysis = try await analyzer.analyze(
                        request,
                        preference: preference,
                        preparation: preparation,
                        progress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token else { return }
                                let progressRevision = self.reserveLifecycleRevision()
                                self.publish(
                                    revision: progressRevision,
                                    changes: [.state]
                                ) {
                                    guard self.generation == token else { return }
                                    if let completedForPreparation {
                                        guard progress.phase == .chartPreparation
                                                || progress.phase
                                                    == .presentationPreparation,
                                            case .preparing(let current, _) =
                                                self.publishedValues.state,
                                            current.id == completedForPreparation.id
                                        else { return }
                                        self.publishedValues.state = .preparing(
                                            current, progress)
                                    } else if case .analyzing =
                                        self.publishedValues.state
                                    {
                                        self.publishedValues.state = .analyzing(progress)
                                    }
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
                                let resolutionRevision =
                                    self.reserveLifecycleRevision()
                                self.publish(
                                    revision: resolutionRevision,
                                    changes: [.currentRecommendation]
                                ) {
                                    guard self.generation == token,
                                        self.request?.id == request.id,
                                        self.preference == preference
                                    else { return }
                                    self.recommendationTask?.cancel()
                                    self.recommendationTask = nil
                                    self.publishedValues.currentRecommendation =
                                        resolution.recommendation
                                }
                            }
                        })
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    let completionRevision = self.reserveLifecycleRevision()
                    var completionChanges: PublishedChanges = [
                        .state, .currentRecommendation, .presentationPending,
                        .chartUpdatePending,
                    ]
                    let clearsSelection: Bool
                    if case .tableFallback = analysis.outcome {
                        clearsSelection = !self.selection.isEmpty
                    } else if let chart = analysis.primaryChart {
                        clearsSelection = self.presentationWillClearSelection(
                            analysis: analysis,
                            chart: chart)
                    } else {
                        clearsSelection = !self.selection.isEmpty
                    }
                    if clearsSelection {
                        completionChanges.insert(.selection)
                    }
                    self.publish(
                        revision: completionRevision,
                        changes: completionChanges
                    ) {
                        guard self.generation == token else { return }
                        self.task = nil
                        self.preferenceUpdatePending = false
                        self.recommendationTask?.cancel()
                        self.recommendationTask = nil
                        self.publishedValues.currentRecommendation =
                            analysis.preferenceResolution?.recommendation
                        if case .tableFallback(let fallback) = analysis.outcome {
                            self.publishedValues.selection.removeAll()
                            self.publishedValues.state = .fallback(analysis, fallback)
                            return
                        }
                        guard let chart = analysis.primaryChart else {
                            self.publishedValues.selection.removeAll()
                            self.publishedValues.state = .fallback(analysis, nil)
                            return
                        }
                        self.installPresentation(
                            for: analysis,
                            chart: chart,
                            keepsVisiblePresentation: keepsReadyChart)
                    }
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
        }
        #if ATC_TEST_HOOKS
        if installed, let attemptDidStartForTesting, !AttemptHookScope.isInvoking {
            AttemptHookScope.$isInvoking.withValue(true) {
                attemptDidStartForTesting()
            }
        }
        #endif
        return StartToken(generation: token, lifecycleRevision: revision)
    }

    private func publishFailure(
        _ failure: AutoChartFailure,
        for requestID: AutoChartRequestID,
        recommendationSource: AutoChartAnalysis<RowID>? = nil
    ) {
        let retainedRecommendationSource = recommendationSource
            ?? recommendationSourceFromState(for: requestID)
        let nextObservedFailureEpisodes = cache.recordingFailureEpisode(
            for: requestID,
            episodeID: failure.episodeID,
            observedEpisodes: observedFailureEpisodes)
        let revision = reserveLifecycleRevision()
        let generation = self.generation &+ 1
        var changes: PublishedChanges = [
            .state, .currentRecommendation, .presentationPending,
            .chartUpdatePending,
        ]
        if !selection.isEmpty { changes.insert(.selection) }
        publish(revision: revision, changes: changes) {
            self.cancelInFlightWork(
                generation: generation,
                clearsSelection: true)
            self.failedRequestID = requestID
            self.observedFailureEpisodes = nextObservedFailureEpisodes
            self.publishedValues.state = .failed(failure)
            guard let request = self.request, request.id == requestID else { return }
            self.restoreRecommendation(
                request: request,
                preference: self.publishedValues.preference,
                token: generation,
                fallback: retainedRecommendationSource)
        }
    }

    private func cancelInFlightWork(
        generation: UInt64,
        clearsSelection: Bool,
        preservesPresentation: Bool = false
    ) {
        self.generation = generation
        task?.cancel()
        recommendationTask?.cancel()
        task = nil
        recommendationTask = nil
        preferenceUpdatePending = false
        if !preservesPresentation {
            presentationGeneration &+= 1
            presentationTask?.cancel()
            presentationTask = nil
            presentationRequestID = nil
            presentationTarget = nil
        }
        if clearsSelection, !publishedValues.selection.isEmpty {
            publishedValues.selection.removeAll()
        }
    }

    private func restoreRecommendation(
        request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        token: UInt64,
        fallback: AutoChartAnalysis<RowID>?
    ) {
        guard publishedValues.currentRecommendation == nil,
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
        switch publishedValues.state {
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
            publishedValues.currentRecommendation = catalogRecommendation
            return
        }
        guard case .chart(let chartPreference) = preference,
            case .charts = analysis.outcome
        else {
            publishedValues.currentRecommendation = nil
            return
        }
        let requestedSpecificationID: AutoChartSpecificationID? = switch chartPreference {
        case .recommended: nil
        case .specific(let id): id.specificationID
        }
        let retainsCurrentRecommendation = requestedSpecificationID.map { requestedID in
            publishedValues.currentRecommendation?.id.specificationID == requestedID
        } ?? false
        if !retainsCurrentRecommendation {
            publishedValues.currentRecommendation = nil
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
            let revision = self.reserveLifecycleRevision()
            self.publish(
                revision: revision,
                changes: [.currentRecommendation]
            ) {
                guard self.generation == token,
                    self.request?.id == analysis.request,
                    self.preference == preference,
                    !Task.isCancelled
                else { return }
                self.publishedValues.currentRecommendation = resolved
                self.recommendationTask = nil
            }
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

    private func presentationRequest(
        for chart: AutoChartPreparedChart<RowID>
    ) -> AutoChartPresentationRequest {
        let context = presentationConfiguration.context
        let formatters = presentationConfiguration.formatters ?? AutoChartFormatters(
            locale: context.locale,
            timeZone: context.timeZone)
        return AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: context,
            formatters: formatters,
            textResolver: presentationConfiguration.textResolver)
    }

    private func presentationWillClearSelection(
        analysis: AutoChartAnalysis<RowID>,
        chart: AutoChartPreparedChart<RowID>
    ) -> Bool {
        guard let readyState, let presented = readyState.presented,
            presented.requestID == presentationRequest(for: chart).id
        else { return false }
        return !publishedValues.selection.belongs(
            to: analysis.id,
            preparedChartID: chart.id)
    }

    /// Installs presentation work while an enclosing lifecycle publication owns
    /// the current revision. This method must not emit Observation mutations.
    private func installPresentation(
        for analysis: AutoChartAnalysis<RowID>,
        chart: AutoChartPreparedChart<RowID>,
        keepsVisiblePresentation: Bool
    ) {
        presentationTarget = PresentationTarget(
            analysis: analysis,
            chart: chart,
            keepsVisiblePresentation: keepsVisiblePresentation)
        let request = presentationRequest(for: chart)
        let requestID = request.id
        if let readyState, let presented = readyState.presented,
            presented.requestID == requestID
        {
            if presentationRequestID != nil {
                presentationGeneration &+= 1
                presentationTask?.cancel()
                presentationTask = nil
                presentationRequestID = nil
            }
            presentationTarget = nil
            if !publishedValues.selection.belongs(
                to: analysis.id, preparedChartID: chart.id)
            {
                publishedValues.selection.removeAll()
            }
            publishedValues.state = .ready(analysis, presented)
            return
        }
        guard presentationRequestID != requestID else {
            publishPendingPresentationState(
                analysis: analysis,
                chart: chart,
                keepsVisiblePresentation: keepsVisiblePresentation)
            return
        }

        presentationGeneration &+= 1
        let presentationToken = presentationGeneration
        presentationTask?.cancel()
        presentationRequestID = requestID
        publishPendingPresentationState(
            analysis: analysis,
            chart: chart,
            keepsVisiblePresentation: keepsVisiblePresentation)
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
                let latestAnalysis = self.presentationAnalysis(
                    for: chart, fallback: analysis)
                let revision = self.reserveLifecycleRevision()
                var changes: PublishedChanges = [
                    .state, .presentationPending, .chartUpdatePending,
                ]
                if !self.selection.belongs(
                    to: latestAnalysis.id, preparedChartID: chart.id)
                {
                    changes.insert(.selection)
                }
                self.publish(revision: revision, changes: changes) {
                    guard self.presentationGeneration == presentationToken else {
                        return
                    }
                    self.presentationTask = nil
                    self.presentationRequestID = nil
                    self.presentationTarget = nil
                    if !self.publishedValues.selection.belongs(
                        to: latestAnalysis.id, preparedChartID: chart.id)
                    {
                        self.publishedValues.selection.removeAll()
                    }
                    self.publishedValues.state = .ready(latestAnalysis, presented)
                }
            } catch is CancellationError {
                guard let self, self.presentationGeneration == presentationToken else {
                    return
                }
                let revision = self.reserveLifecycleRevision()
                self.publish(
                    revision: revision,
                    changes: [.presentationPending, .chartUpdatePending]
                ) {
                    guard self.presentationGeneration == presentationToken else {
                        return
                    }
                    self.presentationTask = nil
                    self.presentationRequestID = nil
                    self.presentationTarget = nil
                }
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

    private func publishPendingPresentationState(
        analysis: AutoChartAnalysis<RowID>,
        chart: AutoChartPreparedChart<RowID>,
        keepsVisiblePresentation: Bool
    ) {
        if keepsVisiblePresentation {
            guard let readyState, let presented = readyState.presented,
                presented.preparedChart.id == chart.id
            else { return }
            publishedValues.state = .ready(analysis, presented)
        } else {
            publishedValues.state = .preparing(
                analysis,
                AutoChartProgress(phase: .presentationPreparation))
        }
    }

    private func presentationAnalysis(
        for chart: AutoChartPreparedChart<RowID>,
        fallback: AutoChartAnalysis<RowID>
    ) -> AutoChartAnalysis<RowID> {
        if let presentationTarget,
            presentationTarget.analysis.id == fallback.id,
            presentationTarget.chart.id == chart.id
        {
            return presentationTarget.analysis
        }
        if let readyState,
            readyState.analysis.id == fallback.id,
            readyState.analysis.primaryChart?.id == chart.id
        {
            return readyState.analysis
        }
        if case .preparing(let analysis, _) = state,
            analysis.id == fallback.id,
            analysis.primaryChart?.id == chart.id
        {
            return analysis
        }
        return fallback
    }

    private static func canPrepareChart(
        for preference: AutoChartPreference,
        in analysis: AutoChartAnalysis<RowID>
    ) -> Bool {
        if case .table = preference { return false }
        guard case .charts(let catalog) = analysis.outcome else { return false }
        return catalog.primary != nil
    }

    private static func canResolveKnownPreparedChart(
        _ preference: AutoChartPreference,
        in analysis: AutoChartAnalysis<RowID>
    ) -> Bool {
        guard case .charts(let catalog) = analysis.outcome else { return false }
        switch preference {
        case .automatic, .chart(.recommended):
            return true
        case .table:
            return false
        case .chart(.specific(let id)):
            let currentID = AutoChartRecommendationID(
                policyVersion: AutoTableCharts.recommendationPolicyVersion,
                specificationID: id.specificationID)
            return catalog.recommendation(for: currentID) != nil
        }
    }

    private static func canReusePreparedChart(
        _ chart: AutoChartPreparedChart<RowID>,
        strategy: AutoChartPreparationStrategy,
        analysis: AutoChartAnalysis<RowID>,
        base: AutoChartAnalysis<RowID>
    ) -> Bool {
        guard case .charts(let catalog) = base.outcome else { return false }
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
