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

    private let cache: AutoChartCache
    private let analyzer: AutoChartAnalyzer
    private let presenter: AutoChartPresenter
    private var request: AutoChartRequest<RowID>?
    private var strategy: AutoChartPreparationStrategy = .preferredOrPrimary
    private var presentationContext = AutoChartPresentationContext()
    private var formatters: AutoChartFormatters?
    private var textResolver = AutoChartTextResolver.default
    private var loadedPresentationContext = AutoChartPresentationContext()
    private var loadedFormatters: AutoChartFormatters?
    private var loadedTextResolver = AutoChartTextResolver.default
    private var environmentPresentationContext: AutoChartPresentationContext?
    private var environmentFormatters: AutoChartFormatters?
    private var environmentTextResolver: AutoChartTextResolver?
    private var generation: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        cache: AutoChartCache = AutoChartCache(),
        presenter: AutoChartPresenter = AutoChartPresenter()
    ) {
        self.cache = cache
        self.analyzer = AutoChartAnalyzer(cache: cache)
        self.presenter = presenter
    }

    deinit { task?.cancel() }

    /// Starts or supersedes a request. Replacement requests clear visible state immediately.
    public func load(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference = .automatic,
        preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
        presentationContext: AutoChartPresentationContext = .init(),
        formatters: AutoChartFormatters? = nil,
        textResolver: AutoChartTextResolver = .default
    ) {
        loadedPresentationContext = presentationContext
        loadedFormatters = formatters
        loadedTextResolver = textResolver
        start(
            request,
            preference: preference,
            preparation: preparation,
            presentationContext: effectivePresentationContext,
            formatters: effectiveFormatters,
            textResolver: effectiveTextResolver,
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
        start(
            request,
            preference: preference,
            preparation: strategy,
            presentationContext: presentationContext,
            formatters: formatters,
            textResolver: textResolver,
            clearsVisibleState: false)
    }

    /// Rebuilds presentation for the current prepared chart without replacing
    /// formatter or text-resolver configuration.
    public func setPresentationContext(_ context: AutoChartPresentationContext) {
        loadedPresentationContext = context
        rebuildEffectivePresentation()
    }

    /// Replaces the context and formatter configuration while preserving the
    /// text resolver supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?
    ) {
        loadedPresentationContext = context
        loadedFormatters = formatters
        rebuildEffectivePresentation()
    }

    /// Replaces the context and text resolver while preserving the formatter
    /// configuration supplied by `load` or a prior presentation update.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        textResolver: AutoChartTextResolver
    ) {
        loadedPresentationContext = context
        loadedTextResolver = textResolver
        rebuildEffectivePresentation()
    }

    /// Replaces the complete presentation configuration without repeating analysis.
    public func setPresentationContext(
        _ context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver
    ) {
        loadedPresentationContext = context
        loadedFormatters = formatters
        loadedTextResolver = textResolver
        rebuildEffectivePresentation()
    }

    /// Applies optional SwiftUI environment overrides on top of the values
    /// supplied by `load`, restoring those values when an override disappears.
    package func applyPresentationEnvironment(
        context: AutoChartPresentationContext?,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver?
    ) {
        environmentPresentationContext = context
        environmentFormatters = formatters
        environmentTextResolver = textResolver
        rebuildEffectivePresentation()
    }

    private var effectivePresentationContext: AutoChartPresentationContext {
        environmentPresentationContext ?? loadedPresentationContext
    }

    private var effectiveFormatters: AutoChartFormatters? {
        environmentFormatters ?? loadedFormatters
    }

    private var effectiveTextResolver: AutoChartTextResolver {
        environmentTextResolver ?? loadedTextResolver
    }

    private func rebuildEffectivePresentation() {
        rebuildPresentation(
            context: effectivePresentationContext,
            formatters: effectiveFormatters,
            textResolver: effectiveTextResolver)
    }

    private func rebuildPresentation(
        context: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver
    ) {
        presentationContext = context
        self.formatters = formatters
        self.textResolver = textResolver
        guard case .ready(let analysis, _) = state,
            let chart = analysis.primaryChart
        else { return }
        state = .ready(
            analysis,
            presenter.present(
                chart,
                context: context,
                formatters: formatters,
                textResolver: textResolver))
    }

    /// Starts a fresh attempt after a retryable failure.
    public func retry() {
        guard let request else { return }
        cache.beginRetry(for: request.id)
        start(
            request,
            preference: preference,
            preparation: strategy,
            presentationContext: presentationContext,
            formatters: formatters,
            textResolver: textResolver,
            clearsVisibleState: true)
    }

    /// Cancels the current attempt. Cancellation never becomes a failure state.
    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        state = .idle
    }

    private func start(
        _ request: AutoChartRequest<RowID>,
        preference: AutoChartPreference,
        preparation: AutoChartPreparationStrategy,
        presentationContext: AutoChartPresentationContext,
        formatters: AutoChartFormatters?,
        textResolver: AutoChartTextResolver,
        clearsVisibleState: Bool
    ) {
        generation &+= 1
        let token = generation
        task?.cancel()
        self.request = request
        self.preference = preference
        self.strategy = preparation
        self.presentationContext = presentationContext
        self.formatters = formatters
        self.textResolver = textResolver
        if clearsVisibleState {
            selection.removeAll()
        }
        if preparation != .none,
            let completed: AutoChartAnalysis<RowID> = cache.completedAnalysis(
                for: request.id),
            !completed.resolve(preference).usesTable
        {
            state = .preparing(completed, nil)
        } else {
            state = .analyzing(nil)
        }
        let analyzer = self.analyzer
        let presenter = self.presenter
        task = Task { [weak self, analyzer, presenter] in
            do {
                let analysis = try await analyzer.analyze(
                    request,
                    preference: preference,
                    preparation: preparation,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            switch progress.phase {
                            case .chartPreparation, .presentationPreparation:
                                if case .preparing(let analysis, _) = self.state {
                                    self.state = .preparing(analysis, progress)
                                }
                            default:
                                self.state = .analyzing(progress)
                            }
                        }
                    })
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                if !selection.belongs(to: analysis) { selection.removeAll() }
                if case .tableFallback(let fallback) = analysis.outcome {
                    state = .fallback(analysis, fallback)
                    return
                }
                guard let chart = analysis.primaryChart else {
                    state = .fallback(analysis, nil)
                    return
                }
                state = .preparing(
                    analysis,
                    AutoChartProgress(phase: .presentationPreparation))
                let presented = presenter.present(
                    chart,
                    context: self.presentationContext,
                    formatters: self.formatters,
                    textResolver: self.textResolver)
                guard generation == token, !Task.isCancelled else { return }
                if !selection.belongs(to: chart) { selection.removeAll() }
                state = .ready(analysis, presented)
            } catch is CancellationError {
                // Supersession and explicit cancellation intentionally publish no failure.
            } catch let failure as AutoChartFailure {
                guard let self, self.generation == token else { return }
                state = .failed(failure)
            } catch {
                guard let self, self.generation == token else { return }
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
}
