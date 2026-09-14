import Foundation
import SwiftUI
import Testing

@testable import AutoTableCharts
@testable import AutoTableChartsUI

#if canImport(Accessibility)
import Accessibility
#endif
#if os(macOS)
import AppKit
#endif

private final class PresentationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private func presentationFixture(offset: Double = 0) async throws -> (
    AutoChartAnalysisID, AutoChartPreparedChart<Int>
) {
    let x = AutoChartColumn(id: "x", name: "Category", semantics: .dimension(semanticType: .nominal))
    let y = AutoChartColumn(id: "y", name: "Value", semantics: .measure())
    let dataset = try AutoChartDataset(
        columns: [x, y],
        rows: [[.text("z"), .double(10 + offset)], [.text("ä"), .double(20 + offset)]],
        rowIDs: [1, 2])
    let analysis = try await AutoChartAnalyzer().analyze(try AutoChartRequest(table: dataset))
    let chart = try await analysis.prepare(.bar(category: x.id, measure: y.id))
    return (analysis.id, chart)
}

@Suite struct PresentationCacheRegressionTests {
    @MainActor
    @Test func overridesRespectPresenterCachePolicyAndWeakOwnership() async throws {
        let (analysisID, chart) = try await presentationFixture()
        let calls = PresentationCounter()
        let override = AutoChartTextResolver { message in
            calls.increment()
            return "Override: \(message.defaultText)"
        }
        var presenter: AutoChartPresenter? = AutoChartPresenter()
        weak let weakPresenter = presenter
        let source = try #require(presenter).present(chart)
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        let first = calls.value
        #expect(first > 0)
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        #expect(calls.value == first)
        AutoChartConveniencePresentationCache.removeAll()
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        #expect(calls.value == first)
        presenter?.removeAll()
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        #expect(calls.value > first)

        let alreadyOverridden = try #require(presenter).present(chart, textResolver: override)
        let beforeUnchanged = calls.value
        _ = AutoChartView(
            presentedChart: alreadyOverridden, analysisID: analysisID, textResolver: override)
        #expect(calls.value == beforeUnchanged)

        presenter = nil
        #expect(weakPresenter == nil)
        let beforeFallback = calls.value
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        let afterFallback = calls.value
        _ = AutoChartView(presentedChart: source, analysisID: analysisID, textResolver: override)
        #expect(afterFallback > beforeFallback)
        #expect(calls.value > afterFallback)
    }

    #if canImport(Accessibility)
    @Test func audioGraphCallbacksAreReleasedWithTheViewCache() async throws {
        let (_, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        var cache: AutoChartAudioGraphDescriptorCache? = AutoChartAudioGraphDescriptorCache()
        weak var captured: PresentationCounter?
        do {
            let token = PresentationCounter()
            captured = token
            let formatters = AutoChartFormatters(request: { [token] _, _, _ in
                token.increment()
                return nil
            })
            let presented = presenter.present(chart, formatters: formatters)
            let lazy = try #require(presented.makeLazyAudioGraphDescriptor(cache: cache))
            _ = lazy.descriptor()
        }
        #expect(captured != nil)
        cache = nil
        // The presenter's live memo holds values, not callback captures.
        #expect(captured == nil)
        withExtendedLifetime(presenter) {}
    }

    @Test func weakAXTargetsDoNotRetainDescriptors() async throws {
        let (_, chart) = try await presentationFixture()
        let cache = AutoChartAudioGraphDescriptorCache()
        let lazy = try #require(AutoChartPresenter().present(chart).makeLazyAudioGraphDescriptor(cache: cache))
        weak var target: AXChartDescriptor?
        autoreleasepool {
            let descriptor = lazy.makeChartDescriptor()
            target = descriptor
            lazy.updateChartDescriptor(descriptor)
        }
        #expect(target == nil)
        withExtendedLifetime(cache) {}
    }
    #endif
}

#if os(macOS)
@Suite(.serialized) @MainActor
struct PresentedChartViewRegressionTests {
    @Test func synchronousOverrideSnapshotMatchesPrePresentedChart() async throws {
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let source = presenter.present(chart, formatters: .init(locale: Locale(identifier: "sv_SE")))
        let formatters = AutoChartFormatters(locale: Locale(identifier: "en_US"))
        let resolver = AutoChartTextResolver { "Export: \($0.defaultText)" }
        let expected = presenter.present(chart, formatters: formatters, textResolver: resolver)
        func pixels(_ view: AutoChartView<Int>) throws -> Data {
            let renderer = ImageRenderer(content: view
                .frame(width: 600, height: 400)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(image.dataProvider?.data) as Data
        }
        let overridden = try pixels(AutoChartView(
            presentedChart: source, analysisID: analysisID,
            formatters: formatters, textResolver: resolver))
        let prePresented = try pixels(AutoChartView(presentedChart: expected, analysisID: analysisID))
        #expect(!overridden.isEmpty)
        #expect(overridden == prePresented)
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func mountedOverridesPreserveInteractionAndRefreshSource() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let (nextAnalysisID, nextChart) = try await presentationFixture(offset: 100)
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(chart: presenter.present(chart), analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestState?
        var reports = 0
        hooks.observe = { observed = $0; reports += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func flush() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        flush()
        let initial = try #require(observed)
        #expect(initial.requestID == model.chart.requestID)
        initial.zoomAnchor.wrappedValue = 3
        initial.zoomScale.wrappedValue = 3
        flush()
        #expect(try #require(observed).zoomScale.wrappedValue == 3)

        #if canImport(Accessibility)
        let originalAudio = try #require(observed?.audioGraph)
        let ax = originalAudio.makeChartDescriptor()
        let originalPoint = try #require(ax.series.first?.dataPoints.first)
        #endif
        let reportsBefore = reports
        model.revision += 1
        flush()
        #expect(reports > reportsBefore)
        #if canImport(Accessibility)
        let rebuiltAudio = try #require(observed?.audioGraph)
        #expect(rebuiltAudio.cache === originalAudio.cache)
        rebuiltAudio.updateChartDescriptor(ax)
        #expect(ax.series.first?.dataPoints.first === originalPoint)
        #endif

        // Keep an externally owned selection while toggling presentation-only inputs.
        let mark = try #require(chart.marks.first)
        model.selection = chart.selections(for: mark.sourceRowIDs, analysisID: analysisID)
        flush()
        let savedSelection = model.selection
        let resolver = AutoChartTextResolver { "Changed: \($0.defaultText)" }
        model.resolver = resolver
        flush()
        let overridden = try #require(observed)
        #expect(overridden.requestID.resolverCallback == resolver.callbackIdentity)
        #expect(overridden.zoomScale.wrappedValue == 3)
        #expect(overridden.zoomAnchor.wrappedValue == 3)
        #expect(model.selection == savedSelection)
        #expect(overridden.selectionCount == 1)
        model.resolver = nil
        flush()
        #expect(observed?.requestID == model.chart.requestID)
        #expect(try #require(observed).zoomScale.wrappedValue == 3)
        #expect(model.selection == savedSelection)

        model.resolver = resolver
        model.chart = presenter.present(nextChart)
        model.analysisID = nextAnalysisID
        flush()
        #expect(observed?.requestID.preparedChart == nextChart.id)
        #expect(observed?.requestID.resolverCallback == resolver.callbackIdentity)
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func kpiOverrideResolvesBeforeViewInitializationReturns() async throws {
        #if ATC_TEST_HOOKS
        let y = AutoChartColumn(id: "y", name: "Value", semantics: .measure())
        let dataset = try AutoChartDataset(columns: [y], rows: [[.double(42)]], rowIDs: [1])
        let analysis = try await AutoChartAnalyzer().analyze(try AutoChartRequest(table: dataset))
        let prepared = try await analysis.prepare(.kpi(measure: y.id))
        let source = AutoChartPresenter().present(prepared)
        let view = AutoChartView(
            presentedChart: source, analysisID: analysis.id,
            formatters: AutoChartFormatters(request: { request, _, _ in
                request.context == .kpi ? "forty-two" : nil
            }), textResolver: AutoChartTextResolver { "Localized: \($0.defaultText)" })
        let kpi = try #require(view.presentedChartForTesting?.kpi)
        #expect(kpi.valueText == "forty-two")
        #expect(kpi.title == "Value")
        #expect(kpi.accessibilityText.hasPrefix("Localized:"))
        #expect(kpi.accessibilityText.contains("forty-two"))
        #endif
    }
}

#if ATC_TEST_HOOKS
@MainActor
private final class HostedPresentationModel: ObservableObject {
    @Published var chart: AutoChartPresentedChart<Int>
    @Published var analysisID: AutoChartAnalysisID
    @Published var resolver: AutoChartTextResolver?
    @Published var selection = AutoChartSelectionSet<Int>()
    @Published var revision = 0
    init(chart: AutoChartPresentedChart<Int>, analysisID: AutoChartAnalysisID) {
        self.chart = chart
        self.analysisID = analysisID
    }
}

private struct HostedPresentationView: View {
    @ObservedObject var model: HostedPresentationModel
    let hooks: AutoChartViewTestHooks
    var body: some View {
        let _ = model.revision
        AutoChartView(
            presentedChart: model.chart, analysisID: model.analysisID,
            selection: $model.selection, textResolver: model.resolver)
            .environment(\.autoChartViewTestHooks, hooks)
            .frame(width: 600, height: 400)
    }
}
#endif
#endif
