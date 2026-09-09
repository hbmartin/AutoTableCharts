#if canImport(SwiftUI) && canImport(Charts)
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
}

/// Package default shown while an alternative is prepared.
public struct AutoChartPreparationPlaceholder<RowID: Hashable & Sendable>: View {
    public let analysis: AutoChartAnalysis<RowID>
    public let progress: AutoChartProgress?
    public let selection: AutoChartSelectionSet<RowID>

    public init(
        analysis: AutoChartAnalysis<RowID>,
        progress: AutoChartProgress?,
        selection: AutoChartSelectionSet<RowID> = .init()
    ) {
        self.analysis = analysis
        self.progress = progress
        self.selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(analysis.preferenceResolution?.recommendation?.specification.title ?? "Chart")
                .font(.headline)
            ProgressView()
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
        var context: AutoChartPresentationContext?
        var formatterLocaleIdentifier: String?
        var formatterTimeZoneIdentifier: String?
        var formatterCallback: UUID?
        var resolverCallback: UUID?
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
                    selection: session.selection)
            case .ready(let analysis, let presented):
                if let presented {
                    AutoChartView(
                        presentedChart: presented,
                        analysisID: analysis.id,
                        selection: $session.selection)
                        .foregroundStyle(theme.legendColor)
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
    }

    private var readyPreparedChartID: AutoChartPreparedChartID? {
        guard case .ready(let analysis, _) = session.state else { return nil }
        return analysis.primaryChart?.id
    }

    private var environmentPresentationIdentity: EnvironmentPresentationIdentity {
        EnvironmentPresentationIdentity(
            context: presentationContext,
            formatterLocaleIdentifier: formatters?.locale.identifier,
            formatterTimeZoneIdentifier: formatters?.timeZone.identifier,
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
                        ProgressView()
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
