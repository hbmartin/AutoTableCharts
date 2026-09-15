import Dispatch
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

private final class PresentationFoundationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(String, String)] = []

    func record(locale: Locale, timeZone: TimeZone) {
        lock.withLock {
            samples.append((locale.identifier, timeZone.identifier))
        }
    }

    var values: [(String, String)] { lock.withLock { samples } }
}

private final class PresentationCallbackConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0
    private var callbackCount = 0
    private var allOffMain = true
    private var sawProgress = false

    func resolve(_ message: AutoChartMessage) -> String {
        let isProgress = message.code == .presentationUpdating
        guard isProgress || message.code.rawValue.hasPrefix("chartFamily.") else {
            return message.defaultText
        }
        lock.withLock {
            active += 1
            callbackCount += 1
            maximumActive = max(maximumActive, active)
            allOffMain = allOffMain && !Thread.isMainThread
            sawProgress = sawProgress || isProgress
        }
        Thread.sleep(forTimeInterval: 0.003)
        lock.withLock { active -= 1 }
        return message.defaultText
    }

    var result: (count: Int, maximumActive: Int, allOffMain: Bool, sawProgress: Bool) {
        lock.withLock { (callbackCount, maximumActive, allOffMain, sawProgress) }
    }
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
    @Test func requestUsesTheFoundationSnapshotRecordedInItsCacheKey() async throws {
        let (_, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let source = presenter.present(chart)
        let probe = PresentationFoundationProbe()
        let formatters = AutoChartFormatters(
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent,
            cacheIdentity: "foundation-snapshot",
            request: { _, locale, timeZone in
                probe.record(locale: locale, timeZone: timeZone)
                return nil
            })
        let context = AutoChartPresentationContext(
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent)
        let request = AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: context,
            formatters: formatters,
            textResolver: .default)

        #expect(request.formatters.locale == .autoupdatingCurrent)
        #expect(request.formatters.timeZone == .autoupdatingCurrent)
        #expect(
            request.id.formatterFoundation.localeIdentifier
                == request.resolvedFormatters.locale.identifier)
        #expect(
            request.id.formatterFoundation.timeZoneIdentifier
                == request.resolvedFormatters.timeZone.identifier)
        #expect(
            request.id.context.localeIdentifier
                == request.id.context.foundation.localeIdentifier)
        #expect(
            request.id.context.timeZoneIdentifier
                == request.id.context.foundation.timeZoneIdentifier)

        _ = source.rePresent(request: request)
        #expect(!probe.values.isEmpty)
        #expect(probe.values.allSatisfy {
            $0.0 == request.id.formatterFoundation.localeIdentifier
                && $0.1 == request.id.formatterFoundation.timeZoneIdentifier
        })
        withExtendedLifetime(presenter) {}
    }

    @Test func overridesRespectPresenterCachePolicyAndWeakOwnership() async throws {
        let (_, chart) = try await presentationFixture()
        let calls = PresentationCounter()
        let override = AutoChartTextResolver { message in
            calls.increment()
            return "Override: \(message.defaultText)"
        }
        let fallback = AutoChartPresenter()
        var presenter: AutoChartPresenter? = AutoChartPresenter(
            releasedPresenterFallback: fallback)
        weak let weakPresenter = presenter
        let source = try #require(presenter).present(chart)
        let request = source.presentationRequest(
            formatters: source.formatters, textResolver: override)
        _ = try await source.rePresentCancellable(
            request: request)
        let first = calls.value
        #expect(first > 0)
        _ = try await source.rePresentCancellable(
            request: request)
        #expect(calls.value == first)
        fallback.removeAll()
        _ = try await source.rePresentCancellable(
            request: request)
        #expect(calls.value == first)
        presenter?.removeAll()
        _ = try await source.rePresentCancellable(
            request: request)
        #expect(calls.value > first)

        let alreadyOverridden = try #require(presenter).present(chart, textResolver: override)
        let beforeUnchanged = calls.value
        let unchangedRequest = alreadyOverridden.presentationRequest(
            formatters: alreadyOverridden.formatters, textResolver: override)
        _ = try await alreadyOverridden.rePresentCancellable(
            request: unchangedRequest)
        #expect(calls.value == beforeUnchanged)

        presenter = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while weakPresenter != nil, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(weakPresenter == nil)
        let beforeFallback = calls.value
        _ = try await source.rePresentCancellable(
            request: request)
        let afterFallback = calls.value
        _ = try await source.rePresentCancellable(
            request: request)
        #expect(afterFallback > beforeFallback)
        #expect(calls.value == afterFallback)
        fallback.removeAll()
        _ = try await source.rePresentCancellable(
            request: request)
        #expect(calls.value > afterFallback)
    }

    #if canImport(Accessibility)
    @Test func audioGraphCallbacksAreReleasedWithTheViewCache() async throws {
        let (_, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        var cache: AutoChartAudioGraphViewCache? = AutoChartAudioGraphViewCache()
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
        let cache = AutoChartAudioGraphViewCache()
        let lazy = try #require(AutoChartPresenter().present(chart).makeLazyAudioGraphDescriptor(cache: cache))
        weak var target: AXChartDescriptor?
        autoreleasepool {
            let descriptor = lazy.makeChartDescriptor()
            let originalXAxis = descriptor.xAxis
            let originalPoint = descriptor.series.first?.dataPoints.first
            target = descriptor
            lazy.updateChartDescriptor(descriptor)
            lazy.updateChartDescriptor(descriptor)
            #expect(descriptor.xAxis === originalXAxis)
            #expect(descriptor.series.first?.dataPoints.first === originalPoint)
        }
        #expect(target == nil)
        withExtendedLifetime(cache) {}
    }
    #endif
}

#if os(macOS)
@Suite(.serialized) @MainActor
struct PresentedChartViewRegressionTests {
    @Test func uncachedOverrideExportsSynchronouslyWithoutSpinner() async throws {
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let source = presenter.present(chart, formatters: .init(locale: Locale(identifier: "sv_SE")))
        let formatters = AutoChartFormatters(locale: Locale(identifier: "en_US"))
        let calls = PresentationCounter()
        let resolver = AutoChartTextResolver {
            calls.increment()
            return "Export: \($0.defaultText)"
        }
        func pixels(_ view: AutoChartView<Int>) throws -> Data {
            let renderer = ImageRenderer(content: view
                .frame(width: 600, height: 400)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(image.dataProvider?.data) as Data
        }
        let overriddenView = AutoChartView(
            presentedChart: source, analysisID: analysisID,
            formatters: formatters, textResolver: resolver)
        #expect(calls.value > 0)
        let overridden = try pixels(overriddenView)
        let expected = presenter.present(
            chart,
            formatters: formatters,
            textResolver: AutoChartTextResolver {
                "Export: \($0.defaultText)"
            })
        let prePresented = try pixels(AutoChartView(presentedChart: expected, analysisID: analysisID))
        #expect(!overridden.isEmpty)
        #expect(overridden == prePresented)
    }

    @Test func deferredOverrideMissPerformsNoCallbackWorkDuringViewInitialization() async throws {
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let source = presenter.present(chart)
        let calls = PresentationCounter()
        let resolver = AutoChartTextResolver { message in
            calls.increment()
            return message.defaultText
        }

        _ = AutoChartView(
            presentedChart: source,
            analysisID: analysisID,
            textResolver: resolver,
            overridePresentationMode: .deferred)

        #expect(calls.value == 0)
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func deferredCallbacksRunOffMainAndAreSerializedWithProgress() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let probe = PresentationCallbackConcurrencyProbe()
        let resolver = AutoChartTextResolver(
            cacheIdentity: "deferred-thread-probe",
            probe.resolve)
        model.resolver = resolver
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.resolverCallback == resolver.callbackIdentity
        })
        let result = probe.result
        #expect(result.count > 0)
        #expect(result.maximumActive == 1)
        #expect(result.allOffMain)
        #expect(result.sawProgress)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func deferredExactHitDoesNotPublishState() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        let source = presenter.present(chart)
        let model = HostedPresentationModel(chart: source, analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var publications = 0
        hooks.observe = { observed = $0 }
        hooks.didPublishDeferredPresentation = { _ in publications += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == source.requestID
        })
        try? await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(publications == 0)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func replacingAWhileItsOverrideIsBlockedKeepsBVisibleAndResetsInteraction() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chartA) = try await presentationFixture()
        let (nextAnalysisID, chartB) = try await presentationFixture(offset: 100)
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let sourceA = presenter.present(chartA)
        let sourceB = presenter.present(chartB)
        let model = HostedPresentationModel(chart: sourceA, analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var publications: [AutoChartPresentationRequestID] = []
        hooks.observe = { observed = $0 }
        hooks.didPublishDeferredPresentation = { publications.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(await waitForHostedChartUpdate(in: host) { observed != nil })

        let mark = try #require(chartA.marks.first)
        model.selection = chartA.selections(for: mark.sourceRowIDs, analysisID: analysisID)
        let initial = try #require(observed)
        initial.zoomAnchor.wrappedValue = 3
        initial.zoomScale.wrappedValue = 3
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.selectionCount == 1 && observed?.zoomScale.wrappedValue == 3
        })

        let slowStarted = PresentationCounter()
        let slowRelease = DispatchGroup()
        slowRelease.enter()
        let slow = AutoChartFormatters(
            cacheIdentity: "blocked-a-override",
            request: { request, _, _ in
                slowStarted.increment()
                slowRelease.wait()
                return "Blocked: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = slow
        #expect(await waitForHostedChartUpdate(in: host) { slowStarted.value > 0 })

        model.chart = sourceB
        model.analysisID = nextAnalysisID
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.preparedChart == chartB.id
                && observed?.zoomScale.wrappedValue == 1
                && model.selection.isEmpty
        })
        #expect(observed?.requestID == sourceB.requestID)
        #expect(model.selection.isEmpty)

        let latest = AutoChartFormatters(
            cacheIdentity: "latest-b-override",
            request: { request, _, _ in
                "Latest: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = latest
        slowRelease.leave()
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.preparedChart == chartB.id
                && observed?.requestID.formatterCallback == latest.callbackIdentity
        })
        #expect(publications.allSatisfy { $0.preparedChart == chartB.id })
        #expect(publications.contains {
            $0.preparedChart == chartB.id
                && $0.formatterCallback == latest.callbackIdentity
        })
        #expect(observed?.zoomScale.wrappedValue == 1)
        #expect(model.selection.isEmpty)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func mountedKPIUsesOverridePayload() async throws {
        #if ATC_TEST_HOOKS
        let measure = AutoChartColumn(
            id: "revenue", name: "Revenue", semantics: .measure())
        let dataset = try AutoChartDataset(
            columns: [measure], rows: [[.double(42)]], rowIDs: [1])
        let analysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: dataset))
        let chart = try await analysis.prepare(.kpi(measure: measure.id))
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysis.id)
        let formatters = AutoChartFormatters(
            cacheIdentity: "mounted-kpi",
            request: { request, _, _ in
                request.context == .kpi ? "KPI override" : nil
            })
        model.formatters = formatters
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == formatters.callbackIdentity
                && observed?.kpiValueText == "KPI override"
        })
        #expect(observed?.kpiTitle == "Revenue")
        #expect(observed?.kpiAccessibilityText?.contains("KPI override") == true)
        withExtendedLifetime(presenter) {}
        #endif
    }

    #if canImport(Accessibility)
    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func audioGraphCacheAndAXObjectsSurviveParentRebuild() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        weak var initialCache: AutoChartAudioGraphViewCache?
        var target: AXChartDescriptor?
        weak var initialPoint: AXDataPoint?
        var observations = 0
        var reusedCache = false
        var reusedPoint = false
        hooks.observeAudioGraph = { cache, descriptor in
            observations += 1
            if target == nil {
                initialCache = cache
                let created = descriptor.makeChartDescriptor()
                target = created
                initialPoint = created.series.first?.dataPoints.first
            } else if let target {
                reusedCache = initialCache === cache
                descriptor.updateChartDescriptor(target)
                reusedPoint = initialPoint === target.series.first?.dataPoints.first
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        #expect(await waitForHostedChartUpdate(in: host) { observations > 0 })
        model.revision += 1
        #expect(await waitForHostedChartUpdate(in: host) { observations > 1 })
        #expect(reusedCache)
        #expect(reusedPoint)
        #expect(initialCache != nil)
        #expect(initialPoint != nil)
        withExtendedLifetime(presenter) {}
        #endif
    }
    #endif

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func mountedOverridesPreserveInteractionAndRefreshSource() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let (nextAnalysisID, nextChart) = try await presentationFixture(offset: 100)
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(chart: presenter.present(chart), analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var reports = 0
        hooks.observe = { observed = $0; reports += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(await waitForHostedChartUpdate(in: host) { observed != nil })
        let initial = try #require(observed)
        #expect(initial.requestID == model.chart.requestID)
        initial.zoomAnchor.wrappedValue = 3
        initial.zoomScale.wrappedValue = 3
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.zoomScale.wrappedValue == 3
        })
        #expect(try #require(observed).zoomScale.wrappedValue == 3)

        // Keep an externally owned selection while toggling presentation-only inputs.
        let mark = try #require(chart.marks.first)
        model.selection = chart.selections(for: mark.sourceRowIDs, analysisID: analysisID)
        #expect(await waitForHostedChartUpdate(in: host) { observed?.selectionCount == 1 })
        let savedSelection = model.selection
        let initialCategory = try #require(observed?.selectedCategory)
        let formatters = AutoChartFormatters(
            cacheIdentity: "mounted-category-labels",
            request: { request, _, _ in
                guard request.context == .axisTick,
                    request.column?.id == "x"
                else { return nil }
                return "Changed: \(request.value.categoryString() ?? "missing")"
            })
        model.formatters = formatters
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == formatters.callbackIdentity
                && observed?.selectedCategory?.hasPrefix("Changed: ") == true
        })
        let overridden = try #require(observed)
        #expect(overridden.requestID.formatterCallback == formatters.callbackIdentity)
        #expect(overridden.selectedCategory != initialCategory)
        #expect(overridden.zoomScale.wrappedValue == 3)
        #expect(overridden.zoomAnchor.wrappedValue == 3)
        #expect(model.selection == savedSelection)
        #expect(overridden.selectionCount == 1)
        model.formatters = nil
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == model.chart.requestID
        })
        #expect(observed?.selectedCategory == initialCategory)
        #expect(try #require(observed).zoomScale.wrappedValue == 3)
        #expect(model.selection == savedSelection)

        let slowCalls = PresentationCounter()
        let slowRelease = DispatchGroup()
        slowRelease.enter()
        let slowFormatters = AutoChartFormatters(
            cacheIdentity: "slow-superseded",
            request: { request, _, _ in
                slowCalls.increment()
                slowRelease.wait()
                return "Superseded: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = slowFormatters
        let slowStarted = await waitForHostedChartUpdate(in: host) { slowCalls.value > 0 }
        let latestFormatters = AutoChartFormatters(
            cacheIdentity: "latest-formatters",
            request: { request, _, _ in
                "Latest: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = latestFormatters
        slowRelease.leave()
        #expect(slowStarted)
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == latestFormatters.callbackIdentity
        })
        #expect(observed?.requestID.formatterCallback != slowFormatters.callbackIdentity)
        #expect(observed?.zoomScale.wrappedValue == 3)

        model.chart = presenter.present(nextChart)
        model.analysisID = nextAnalysisID
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.preparedChart == nextChart.id
                && observed?.requestID.formatterCallback == latestFormatters.callbackIdentity
        })
        #expect(observed?.requestID.preparedChart == nextChart.id)
        #expect(observed?.requestID.formatterCallback == latestFormatters.callbackIdentity)
        #expect(reports > 0)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func mountedDonutSelectionTracksReorderedAnglesWithoutResettingZoom() async throws {
        #if ATC_TEST_HOOKS
        let category = AutoChartColumn(
            id: "category", name: "Category",
            semantics: .dimension(semanticType: .nominal))
        let measure = AutoChartColumn(
            id: "measure", name: "Value",
            semantics: .measure(semantics: .init(rollup: .additive)))
        let dataset = try AutoChartDataset(
            columns: [category, measure],
            rows: [[.text("z"), .double(10)], [.text("ä"), .double(10)]],
            rowIDs: [1, 2])
        let analysis = try await AutoChartAnalyzer().analyze(try AutoChartRequest(table: dataset))
        let chart = try await analysis.prepare(
            AutoChartSpecification(
                family: .donut,
                encoding: .init(x: category.id, y: measure.id),
                aggregation: .sum,
                sort: .ascending))
        let initialFormatters = AutoChartFormatters(
            cacheIdentity: "donut-order-initial",
            request: { request, _, _ in
                guard request.context == .axisTick, request.column?.id == category.id else {
                    return nil
                }
                return request.value == .text("z") ? "A" : "Z"
            })
        let overrideFormatters = AutoChartFormatters(
            cacheIdentity: "donut-order-reversed",
            request: { request, _, _ in
                guard request.context == .axisTick, request.column?.id == category.id else {
                    return nil
                }
                return request.value == .text("z") ? "Z" : "A"
            })
        let presenter = AutoChartPresenter()
        let source = presenter.present(chart, formatters: initialFormatters)
        let model = HostedPresentationModel(chart: source, analysisID: analysis.id)
        let selectedDatum = try #require(source.renderedData.first { $0.xSourceValue == .text("z") })
        let matchingMarks = chart.marks.filter { $0.identity == selectedDatum.id }
        let selectedMark = try #require(matchingMarks.first)
        model.selection = chart.selections(
            for: selectedMark.sourceRowIDs, analysisID: analysis.id)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HostedPresentationView(model: model, hooks: hooks))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(await waitForHostedChartUpdate(in: host) { observed?.selectedAngle == 5 })
        let initial = try #require(observed)
        initial.zoomAnchor.wrappedValue = 3
        initial.zoomScale.wrappedValue = 3
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.zoomScale.wrappedValue == 3
        })

        model.formatters = overrideFormatters
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == overrideFormatters.callbackIdentity
                && observed?.selectedAngle == 15
        })
        #expect(observed?.selectionCount == 1)
        #expect(observed?.zoomScale.wrappedValue == 3)
        #expect(observed?.zoomAnchor.wrappedValue == 3)
        withExtendedLifetime(presenter) {}
        #endif
    }
}

#if ATC_TEST_HOOKS
@MainActor
private final class HostedPresentationModel: ObservableObject {
    @Published var chart: AutoChartPresentedChart<Int>
    @Published var analysisID: AutoChartAnalysisID
    @Published var formatters: AutoChartFormatters?
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
        AutoChartView(
            presentedChart: model.chart, analysisID: model.analysisID,
            selection: $model.selection,
            formatters: model.formatters,
            textResolver: model.resolver,
            overridePresentationMode: .deferred)
            .environment(\.autoChartViewTestHooks, hooks)
            .environment(\.autoChartViewTestRevision, model.revision)
            .frame(width: 600, height: 400)
    }
}

@MainActor
private func waitForHostedChartUpdate(
    in host: NSView,
    timeout: TimeInterval = 2,
    predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        host.layoutSubtreeIfNeeded()
        if predicate() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    } while Date() < deadline
    host.layoutSubtreeIfNeeded()
    return predicate()
}
#endif
#endif
