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
    public var selection = AutoChartSelectionSet<RowID>()

    /// True while the session is resolving a new presentation payload. A ready
    /// chart may remain visible while this is true.
    public var isPresentationPending: Bool {
        presentationRequestID != nil
    }

    package var isPreferenceUpdatePending: Bool { preferenceUpdatePending }

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
    private var presentationRequestID: AutoChartPresentationRequestID?
    private var preferenceUpdatePending = false

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
    }

    /// Starts or supersedes a request. Replacement requests clear visible state immediately.
    public func load(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference = .automatic,
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
    public func select(_ recommendationID: AutoChartRecommendationID) {
        setPreference(.chart(.specific(recommendationID)))
    }

    /// Reconciles a new preference against the current analysis and prepared-chart cache.
    public func setPreference(_ preference: AutoChartPreference) {
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
                if let pendingID = presentationRequestID,
                    pendingID.preparedChart != presented.preparedChart.id
                {
                    presentationGeneration &+= 1
                    presentationTask?.cancel()
                    presentationTask = nil
                    presentationRequestID = nil
                }
                self.preference = preference
                state = .ready(
                    base.replacingPresentation(
                        preparedCharts: displayedAnalysis.preparedCharts,
                        resolution: resolution),
                    presented)
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
        }
    }

    /// Starts a fresh attempt after a retryable failure.
    public func retry() {
        retry(preference: preference)
    }

    /// Starts a fresh attempt with a new preference after a retryable failure.
    public func retry(preference: AutoChartPreference) {
        guard let request else { return }
        cache.beginRetry(for: request.id)
        start(
            request,
            preference: preference,
            preparation: strategy,
            presentationConfiguration: presentationConfiguration,
            clearsVisibleState: true)
    }

    /// Cancels the current attempt. Cancellation never becomes a failure state.
    public func cancel() {
        generation &+= 1
        presentationGeneration &+= 1
        task?.cancel()
        presentationTask?.cancel()
        task = nil
        presentationTask = nil
        presentationRequestID = nil
        preferenceUpdatePending = false
        state = .idle
    }

    private func start(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        preparation: AutoChartPreparationStrategy,
        presentationConfiguration: PresentationConfiguration,
        clearsVisibleState: Bool,
        keepsVisibleReadyChart: Bool = false
    ) {
        let keepsReadyChart: Bool
        if keepsVisibleReadyChart, case .ready(_, let presented) = state,
            presented != nil,
            self.request?.id == request.id
        {
            keepsReadyChart = true
        } else {
            keepsReadyChart = false
        }
        generation &+= 1
        let token = generation
        task?.cancel()
        presentationGeneration &+= 1
        presentationTask?.cancel()
        presentationTask = nil
        presentationRequestID = nil
        self.request = request
        self.preference = preference
        self.strategy = preparation
        self.presentationConfiguration = presentationConfiguration
        preferenceUpdatePending = keepsReadyChart
        if clearsVisibleState {
            selection.removeAll()
        }
        let completedForPreparation: AutoChartAnalysis<RowID>?
        if preparation != .none,
            let completed: AutoChartAnalysis<RowID> = cache.completedAnalysis(
                for: request.id),
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
                    })
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.task = nil
                self.preferenceUpdatePending = false
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
                self.task = nil
                self.preferenceUpdatePending = false
                state = .failed(failure)
            } catch {
                guard let self, self.generation == token else { return }
                self.task = nil
                self.preferenceUpdatePending = false
                state = .failed(
                    AutoChartFailure(
                        stage: .recommendation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.session.internalFailure",
                        message: String(describing: error)))
            }
        }
    }

    private func schedulePresentation(
        for analysis: AutoChartAnalysis<RowID>,
        chart: AutoChartPreparedChart<RowID>,
        keepsVisiblePresentation: Bool
    ) {
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
                let presented = try await presenter.presentCancellable(
                    chart,
                    request: request)
                try Task.checkCancellation()
                guard let self,
                    self.presentationGeneration == presentationToken
                else { return }
                self.presentationTask = nil
                self.presentationRequestID = nil
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
            } catch {
                guard let self,
                    self.presentationGeneration == presentationToken
                else { return }
                self.presentationTask = nil
                self.presentationRequestID = nil
                self.state = .failed(
                    AutoChartFailure(
                        stage: .presentationPreparation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.session.presentationFailure",
                        message: String(describing: error)))
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
