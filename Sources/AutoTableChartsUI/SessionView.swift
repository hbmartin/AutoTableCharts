#if canImport(SwiftUI) && canImport(Charts)
import Dispatch
import Foundation
import SwiftUI
import Charts
import AutoTableCharts

public struct AutoChartPalette: @unchecked Sendable {
    public var marks: [Color]
    public init(marks: [Color] = []) {
        self.marks = marks
    }
}

public struct AutoChartTheme: @unchecked Sendable {
    public var axisColor: Color
    public var legendColor: Color
    public var markColors: [Color]
    public var titleFont: Font
    public var labelFont: Font
    public var distinguishesMarksWithoutColor: Bool

    public init(
        axisColor: Color = .secondary,
        legendColor: Color = .primary,
        markColors: [Color] = [.blue, .orange, .green, .purple, .pink],
        titleFont: Font = .headline,
        labelFont: Font = .caption,
        distinguishesMarksWithoutColor: Bool = true
    ) {
        self.axisColor = axisColor
        self.legendColor = legendColor
        self.markColors = markColors
        self.titleFont = titleFont
        self.labelFont = labelFont
        self.distinguishesMarksWithoutColor = distinguishesMarksWithoutColor
    }

    public static let `default` = AutoChartTheme()
}

/// Controls synchronous host callback concurrency for mounted deferred charts.
/// An already running callback cannot be interrupted; cancelled queued calls
/// are removed before they start.
public enum AutoChartDeferredCallbackScheduling: Hashable, Sendable {
    /// Preserves the per-view one-at-a-time callback guarantee, including labels.
    case serial
    /// Lets one newer presentation proceed past a blocked older callback and
    /// resolves progress labels on an independent lane.
    case overlapping

    var maximumConcurrentJobs: Int { self == .serial ? 1 : 2 }
}

private struct AutoChartPresentationContextKey: EnvironmentKey {
    static let defaultValue: AutoChartPresentationContext? = nil
}

private struct AutoChartFormattersKey: EnvironmentKey {
    static let defaultValue: AutoChartFormatters? = nil
}

private struct AutoChartTextResolverKey: EnvironmentKey {
    static let defaultValue: AutoChartTextResolver? = nil
}

private struct AutoChartPaletteKey: EnvironmentKey {
    static let defaultValue = AutoChartPalette()
}

private struct AutoChartThemeKey: EnvironmentKey {
    static let defaultValue = AutoChartTheme.default
}

private struct AutoChartDeferredCallbackSchedulingKey: EnvironmentKey {
    static let defaultValue = AutoChartDeferredCallbackScheduling.overlapping
}

extension EnvironmentValues {
    public var autoChartPresentationContext: AutoChartPresentationContext? {
        get { self[AutoChartPresentationContextKey.self] }
        set { self[AutoChartPresentationContextKey.self] = newValue }
    }

    public var autoChartFormatters: AutoChartFormatters? {
        get { self[AutoChartFormattersKey.self] }
        set { self[AutoChartFormattersKey.self] = newValue }
    }

    public var autoChartTextResolver: AutoChartTextResolver? {
        get { self[AutoChartTextResolverKey.self] }
        set { self[AutoChartTextResolverKey.self] = newValue }
    }

    public var autoChartPalette: AutoChartPalette {
        get { self[AutoChartPaletteKey.self] }
        set { self[AutoChartPaletteKey.self] = newValue }
    }

    public var autoChartTheme: AutoChartTheme {
        get { self[AutoChartThemeKey.self] }
        set { self[AutoChartThemeKey.self] = newValue }
    }
    public var autoChartDeferredCallbackScheduling: AutoChartDeferredCallbackScheduling {
        get { self[AutoChartDeferredCallbackSchedulingKey.self] }
        set { self[AutoChartDeferredCallbackSchedulingKey.self] = newValue }
    }
}

extension View {
    public func autoChartPresentationContext(
        _ value: AutoChartPresentationContext
    ) -> some View { environment(\.autoChartPresentationContext, value) }

    public func autoChartFormatters(_ value: AutoChartFormatters) -> some View {
        environment(\.autoChartFormatters, value)
    }

    public func autoChartTextResolver(_ value: AutoChartTextResolver) -> some View {
        environment(\.autoChartTextResolver, value)
    }

    public func autoChartPalette(_ value: AutoChartPalette) -> some View {
        environment(\.autoChartPalette, value)
    }

    public func autoChartTheme(_ value: AutoChartTheme) -> some View {
        environment(\.autoChartTheme, value)
    }
    public func autoChartDeferredCallbackScheduling(
        _ value: AutoChartDeferredCallbackScheduling
    ) -> some View {
        environment(\.autoChartDeferredCallbackScheduling, value)
    }
}

enum AutoChartProgressAccessibility {
    static let preparing = AutoChartMessage(
        category: .accessibility,
        code: .presentationPending,
        defaultText: "Preparing chart")
    static let updating = AutoChartMessage(
        category: .accessibility,
        code: .presentationUpdating,
        defaultText: "Updating chart")
}

enum AutoChartProgressTextResolution {
    static func resolve(
        _ message: AutoChartMessage,
        using resolver: AutoChartTextResolver,
        on scheduler: AutoChartCallbackWorkScheduler? = nil
    ) async -> String? {
        guard resolver.callbackIdentity != nil else { return message.defaultText }
        let workScheduler = scheduler ?? AutoChartCallbackWorkScheduler(
            maximumConcurrentJobs: 2,
            queue: DispatchQueue.global(qos: .userInitiated))
        do {
            return try await AutoChartCancellableWork.run(on: workScheduler) { cancellation in
                try cancellation.checkCancellation()
                return resolver(message)
            }
        } catch is CancellationError {
            return nil
        } catch {
            assertionFailure("Progress text resolution failed: \(error)")
            return nil
        }
    }
}

private final class AutoChartProgressResolutionWorker: ObservableObject {
    let scheduler = AutoChartCallbackWorkScheduler(
        maximumConcurrentJobs: 2,
        queue: DispatchQueue.global(qos: .userInitiated))
}

struct AutoChartAccessibleProgressView: View {
    let message: AutoChartMessage
    let textResolver: AutoChartTextResolver?
    let scheduler: AutoChartCallbackWorkScheduler?

    @Environment(\.autoChartTextResolver) private var environmentTextResolver
    @State private var accessibilityText: String
    @StateObject private var worker = AutoChartProgressResolutionWorker()

    private struct ResolutionID: Hashable {
        let message: AutoChartMessage
        let resolverCallback: AutoChartHostCallbackCacheIdentity?
        let scheduler: ObjectIdentifier
    }

    init(
        message: AutoChartMessage,
        textResolver: AutoChartTextResolver? = nil,
        scheduler: AutoChartCallbackWorkScheduler? = nil
    ) {
        self.message = message
        self.textResolver = textResolver
        self.scheduler = scheduler
        _accessibilityText = State(initialValue: message.defaultText)
    }

    var body: some View {
        let resolver = textResolver ?? environmentTextResolver
        let resolutionScheduler = scheduler ?? worker.scheduler
        ProgressView()
            .accessibilityLabel(accessibilityText)
            .task(id: ResolutionID(
                message: message,
                resolverCallback: resolver?.callbackIdentity,
                scheduler: ObjectIdentifier(resolutionScheduler))
            ) {
                if accessibilityText != message.defaultText {
                    accessibilityText = message.defaultText
                }
                guard let resolver else { return }
                let resolved = await AutoChartProgressTextResolution.resolve(
                    message,
                    using: resolver,
                    on: resolutionScheduler)
                guard let resolved, !Task.isCancelled else { return }
                if accessibilityText != resolved {
                    accessibilityText = resolved
                }
            }
    }
}

/// Package default shown while an alternative is prepared.
public struct AutoChartPreparationPlaceholder<RowID: Hashable & Sendable>: View {
    public let analysis: AutoChartAnalysis<RowID>
    public let progress: AutoChartProgress?
    public let selection: AutoChartSelectionSet<RowID>
    package let textResolver: AutoChartTextResolver?

    public init(
        analysis: AutoChartAnalysis<RowID>,
        progress: AutoChartProgress?,
        selection: AutoChartSelectionSet<RowID> = .init()
    ) {
        self.init(
            analysis: analysis,
            progress: progress,
            selection: selection,
            resolvedTextResolver: nil)
    }

    package init(
        analysis: AutoChartAnalysis<RowID>,
        progress: AutoChartProgress?,
        selection: AutoChartSelectionSet<RowID>,
        textResolver: AutoChartTextResolver
    ) {
        self.init(
            analysis: analysis,
            progress: progress,
            selection: selection,
            resolvedTextResolver: textResolver)
    }

    private init(
        analysis: AutoChartAnalysis<RowID>,
        progress: AutoChartProgress?,
        selection: AutoChartSelectionSet<RowID>,
        resolvedTextResolver: AutoChartTextResolver?
    ) {
        self.analysis = analysis
        self.progress = progress
        self.selection = selection
        self.textResolver = resolvedTextResolver
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(analysis.preferenceResolution?.recommendation?.specification.title ?? "Chart")
                .font(.headline)
            AutoChartAccessibleProgressView(
                message: AutoChartProgressAccessibility.preparing,
                textResolver: textResolver)
            if let progress {
                Text(progress.phase.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !analysis.diagnostics.isEmpty {
                Text("\(analysis.diagnostics.count) diagnostics")
                    .font(.caption)
            }
            if selection.isEmpty {
                Text("Selection remains available while this chart is prepared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "\(selection.count) selected marks · "
                        + "\(selection.unionedSourceRows.count) source rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// State-driven chart host with customizable loading, table fallback, and failure content.
public struct AutoChartSessionView<
    RowID: Hashable & Sendable,
    Loading: View,
    Fallback: View,
    Failure: View
>: View {
    @Bindable private var session: AutoChartSession<RowID>
    private let loading: (AutoChartProgress?) -> Loading
    private let fallback: (AutoChartAnalysis<RowID>, AutoChartFallback?) -> Fallback
    private let failure: (AutoChartFailure) -> Failure

    @Environment(\.autoChartFormatters) private var formatters
    @Environment(\.autoChartTextResolver) private var textResolver
    @Environment(\.autoChartPresentationContext) private var presentationContext
    @Environment(\.autoChartTheme) private var theme

    private struct EnvironmentPresentationIdentity: Hashable {
        var context: AutoChartPresentationContextIdentity?
        var formatterFoundation: AutoChartFoundationPresentationIdentity?
        var formatterCallback: AutoChartHostCallbackCacheIdentity?
        var resolverCallback: AutoChartHostCallbackCacheIdentity?
    }

    public init(
        session: AutoChartSession<RowID>,
        @ViewBuilder loading: @escaping (AutoChartProgress?) -> Loading,
        @ViewBuilder fallback: @escaping (
            AutoChartAnalysis<RowID>, AutoChartFallback?
        ) -> Fallback,
        @ViewBuilder failure: @escaping (AutoChartFailure) -> Failure
    ) {
        self.session = session
        self.loading = loading
        self.fallback = fallback
        self.failure = failure
    }

    public var body: some View {
        Group {
            switch session.state {
            case .idle:
                loading(nil)
            case .analyzing(let progress):
                loading(progress)
            case .preparing(let analysis, let progress):
                AutoChartPreparationPlaceholder(
                    analysis: analysis,
                    progress: progress,
                    selection: session.selection,
                    textResolver: session.presentationTextResolver)
            case .ready(let analysis, let presented):
                if let presented {
                    ZStack(alignment: .topTrailing) {
                        AutoChartView(
                            resolvedPresentedChart: presented,
                            analysisID: analysis.id,
                            selection: $session.selection,
                            presentation: .explorer())
                            .foregroundStyle(theme.legendColor)
                        if session.isChartUpdatePending {
                            AutoChartAccessibleProgressView(
                                message: AutoChartProgressAccessibility.updating,
                                textResolver: session.presentationTextResolver)
                                .controlSize(.small)
                                .padding(8)
                        }
                    }
                } else {
                    loading(nil)
                }
            case .fallback(let analysis, let reason):
                fallback(analysis, reason)
            case .failed(let error):
                failure(error)
            }
        }
        .task(id: environmentPresentationIdentity) {
            applyEnvironmentPresentation()
        }
        .onChange(of: readyPreparedChartID) { _, id in
            guard id != nil else { return }
            applyEnvironmentPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            applyEnvironmentPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSSystemTimeZoneDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            applyEnvironmentPresentation()
        }
    }

    private var readyPreparedChartID: AutoChartPreparedChartID? {
        guard case .ready(let analysis, _) = session.state else { return nil }
        return analysis.primaryChart?.id
    }

    private var environmentPresentationIdentity: EnvironmentPresentationIdentity {
        EnvironmentPresentationIdentity(
            context: presentationContext.map(AutoChartPresentationContextIdentity.init),
            formatterFoundation: formatters.map {
                AutoChartFoundationPresentationIdentity(
                    locale: $0.locale,
                    timeZone: $0.timeZone)
            },
            formatterCallback: formatters?.callbackIdentity,
            resolverCallback: textResolver?.callbackIdentity)
    }

    private func applyEnvironmentPresentation() {
        session.applyPresentationEnvironment(
            context: presentationContext,
            formatters: formatters,
            textResolver: textResolver)
    }

}

extension AutoChartSessionView where
    Loading == AnyView, Fallback == AnyView, Failure == AnyView
{
    public init(session: AutoChartSession<RowID>) {
        self.init(
            session: session,
            loading: { progress in
                AnyView(
                    VStack(spacing: 8) {
                        AutoChartAccessibleProgressView(
                            message: AutoChartProgressAccessibility.preparing,
                            textResolver: session.presentationTextResolver)
                        if let progress { Text(progress.phase.rawValue).font(.caption) }
                    })
            },
            fallback: { _, reason in
                AnyView(
                    ContentUnavailableView(
                        "Table",
                        systemImage: "tablecells",
                        description: Text(
                            reason?.message.defaultText
                                ?? "This result is safest to view as a table.")))
            },
            failure: { failure in
                AnyView(
                    ContentUnavailableView(
                        "Chart unavailable",
                        systemImage: "chart.xyaxis.line",
                        description: Text(failure.localizedDescription)))
            })
    }
}
#endif
