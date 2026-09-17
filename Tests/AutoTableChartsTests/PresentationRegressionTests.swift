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

private final class PresentationMainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var allMain = true

    func record() {
        lock.withLock {
            count += 1
            allMain = allMain && Thread.isMainThread
        }
    }

    var result: (count: Int, allMain: Bool) {
        lock.withLock { (count, allMain) }
    }
}

private final class PresentationBlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var isReleased = false

    init() {
        group.enter()
    }

    @discardableResult
    func wait(timeout: DispatchTime = .distantFuture) -> Bool {
        group.wait(timeout: timeout) == .success
    }

    func release() {
        let shouldLeave = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    var isOpen: Bool { lock.withLock { isReleased } }
}

private final class PresentationFirstCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = PresentationBlockingGate()
    private var claimed = false

    func pauseFirst() {
        let isFirst = lock.withLock { () -> Bool in
            guard !claimed else { return false }
            claimed = true
            return true
        }
        if isFirst { gate.wait() }
    }

    func release() { gate.release() }
}

private final class PresentationFoundationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Locale, TimeZone)] = []

    func record(locale: Locale, timeZone: TimeZone) {
        lock.withLock { samples.append((locale, timeZone)) }
    }

    var values: [(Locale, TimeZone)] { lock.withLock { samples } }
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

private func waitForPresentationCondition(
    timeout: TimeInterval = 2,
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    } while Date() < deadline
    return predicate()
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
    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func serialSchedulerRemovesCancelledQueuedCallbacks() async throws {
        #if ATC_TEST_HOOKS
        let scheduler = AutoChartCallbackWorkScheduler(
            maximumConcurrentJobs: 1,
            queue: DispatchQueue.global(qos: .userInitiated))
        let firstStarted = PresentationCounter()
        let queuedCalls = PresentationCounter()
        let release = PresentationBlockingGate()
        defer { release.release() }
        let first = Task {
            try await AutoChartCancellableWork.run(on: scheduler) { _ in
                firstStarted.increment()
                release.wait()
                return 1
            }
        }
        #expect(await waitForPresentationCondition { firstStarted.value == 1 })
        let queued = Task {
            try await AutoChartCancellableWork.run(on: scheduler) { _ in
                queuedCalls.increment()
                return 2
            }
        }
        #expect(await waitForPresentationCondition {
            scheduler.statusForTesting.pending == 1
        })
        queued.cancel()
        do {
            _ = try await queued.value
            Issue.record("A cancelled queued callback must not return a value.")
        } catch is CancellationError {}
        #expect(scheduler.statusForTesting.pending == 0)
        #expect(queuedCalls.value == 0)
        release.release()
        #expect(try await first.value == 1)
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func overlappingSchedulerRunsOnlyTwoCallbacksAtOnce() async throws {
        #if ATC_TEST_HOOKS
        let scheduler = AutoChartCallbackWorkScheduler(
            maximumConcurrentJobs: 2,
            queue: DispatchQueue.global(qos: .userInitiated))
        let started = PresentationCounter()
        let thirdCalls = PresentationCounter()
        let release = PresentationBlockingGate()
        defer { release.release() }
        let first = Task {
            try await AutoChartCancellableWork.run(on: scheduler) { _ in
                started.increment()
                release.wait()
                return 1
            }
        }
        let second = Task {
            try await AutoChartCancellableWork.run(on: scheduler) { _ in
                started.increment()
                release.wait()
                return 2
            }
        }
        #expect(await waitForPresentationCondition { started.value == 2 })
        let third = Task {
            try await AutoChartCancellableWork.run(on: scheduler) { _ in
                thirdCalls.increment()
                return 3
            }
        }
        #expect(await waitForPresentationCondition {
            scheduler.statusForTesting.active == 2
                && scheduler.statusForTesting.pending == 1
        })
        third.cancel()
        do {
            _ = try await third.value
            Issue.record("A cancelled third callback must not run.")
        } catch is CancellationError {}
        #expect(thirdCalls.value == 0)
        #expect(scheduler.statusForTesting.pending == 0)
        release.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func cancelledCacheMissCannotEvictAnExistingPayload() async throws {
        #if ATC_TEST_HOOKS
        let (_, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 1)
        let source = presenter.present(chart)
        let originalRequest = source.presentationRequest(
            formatters: source.formatters,
            textResolver: source.textResolver)
        let scheduler = AutoChartCallbackWorkScheduler(
            maximumConcurrentJobs: 1,
            queue: DispatchQueue.global(qos: .userInitiated))
        let started = PresentationCounter()
        let release = PresentationBlockingGate()
        defer { release.release() }
        let slow = AutoChartFormatters(
            cacheIdentity: "cancelled-cache-miss",
            request: { _, _, _ in
                started.increment()
                release.wait()
                return nil
            })
        let slowRequest = source.presentationRequest(
            formatters: slow,
            textResolver: source.textResolver)
        let pending = Task {
            try await presenter.presentCancellable(
                chart, request: slowRequest, scheduler: scheduler)
        }
        #expect(await waitForPresentationCondition { started.value > 0 })
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Cancelled presentation must not publish.")
        } catch is CancellationError {}
        release.release()
        #expect(await waitForPresentationCondition {
            scheduler.statusForTesting.active == 0
        })
        #expect(presenter.cachedPresentation(chart, request: originalRequest) != nil)
        #expect(presenter.cachedPresentation(chart, request: slowRequest) == nil)
        #endif
    }

    @Test func requestUsesTheFoundationSnapshotRecordedInItsCacheKey() async throws {
        let (_, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let source = presenter.present(chart)
        let probe = PresentationFoundationProbe()
        let currentLocale = Locale.current
        let currentTimeZone = TimeZone.current
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
        #expect(request.resolvedFormatters.locale == currentLocale)
        #expect(request.resolvedFormatters.timeZone == currentTimeZone)
        #expect(request.resolvedFormatters.locale.hourCycle == currentLocale.hourCycle)
        #expect(
            request.resolvedFormatters.locale.decimalSeparator
                == currentLocale.decimalSeparator)
        #expect(
            request.resolvedFormatters.locale.groupingSeparator
                == currentLocale.groupingSeparator)
        #expect(
            request.resolvedFormatters.locale.firstDayOfWeek
                == currentLocale.firstDayOfWeek)
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
            $0.0 == currentLocale && $0.1 == currentTimeZone
        })
        withExtendedLifetime(presenter) {}
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func overridesRespectPresenterCachePolicyAndWeakOwnership() async throws {
        #if ATC_TEST_HOOKS
        let (_, chart) = try await presentationFixture()
        let calls = PresentationCounter()
        let override = AutoChartTextResolver { message in
            calls.increment()
            return "Override: \(message.defaultText)"
        }
        let fallback = AutoChartPresenter()
        var presenter: AutoChartPresenter? = AutoChartPresenter(
            releasedPresenterFallbackForTesting: fallback)
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
        #endif
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
@Suite(.serializedMainActorRegression) @MainActor
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

    @Test func cachedOverrideExportsSynchronouslyWithoutInvokingCallbacks() async throws {
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        let source = presenter.present(
            chart,
            formatters: .init(locale: Locale(identifier: "sv_SE")))
        let calls = PresentationCounter()
        let formatters = AutoChartFormatters(locale: Locale(identifier: "en_US"))
        let resolver = AutoChartTextResolver(
            cacheIdentity: "cached-export-resolver",
            { message in
                calls.increment()
                return "Export: \(message.defaultText)"
            })
        let expected = presenter.present(
            chart, formatters: formatters, textResolver: resolver)
        let callsAfterCaching = calls.value

        func pixels(_ view: AutoChartView<Int>) throws -> Data {
            let renderer = ImageRenderer(content: view
                .frame(width: 600, height: 400)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(image.dataProvider?.data) as Data
        }

        let overriddenView = AutoChartView(
            presentedChart: source,
            analysisID: analysisID,
            formatters: formatters,
            textResolver: resolver)
        #expect(calls.value == callsAfterCaching)
        let overridden = try pixels(overriddenView)
        let prePresented = try pixels(AutoChartView(
            presentedChart: expected,
            analysisID: analysisID))
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
    func deferredCallbacksRunOffMainAndResolveProgress() async throws {
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
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(
                model: model, hooks: hooks, scheduling: .overlapping))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.resolverCallback == resolver.callbackIdentity
        })
        let result = probe.result
        #expect(result.count > 0)
        #expect(result.allOffMain)
        #expect(result.sawProgress)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func deferredViewSerializesProgressBehindBlockedPresentation() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let formatterCalls = PresentationCounter()
        let progressCalls = PresentationCounter()
        let release = PresentationFirstCallbackGate()
        defer { release.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "serial-presentation-progress",
            request: { _, _, _ in
                formatterCalls.increment()
                release.pauseFirst()
                return nil
            })
        let resolver = AutoChartTextResolver(
            cacheIdentity: "serial-progress-label",
            { message in
                if message.code == .presentationUpdating {
                    progressCalls.increment()
                    release.pauseFirst()
                }
                return message.defaultText
            })
        model.formatters = formatters
        model.resolver = resolver
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(
                model: model, hooks: hooks, scheduling: .serial))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            formatterCalls.value + progressCalls.value == 1
                && hooks.callbackSchedulerForTesting?.statusForTesting.active == 1
                && (hooks.callbackSchedulerForTesting?.statusForTesting.pending ?? 0) > 0
        })
        #expect(formatterCalls.value + progressCalls.value == 1)
        release.release()
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == formatters.callbackIdentity
                && observed?.requestID.resolverCallback == resolver.callbackIdentity
        })
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func blockedPresentationDoesNotDelayProgressResolution() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let presentationStarted = PresentationCounter()
        let progressCalls = PresentationCounter()
        let presentationGate = PresentationBlockingGate()
        defer { presentationGate.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "blocked-presentation-progress-lane",
            request: { request, _, _ in
                presentationStarted.increment()
                presentationGate.wait()
                return "Blocked: \(request.value.categoryString() ?? "value")"
            })
        let resolver = AutoChartTextResolver(
            cacheIdentity: "blocked-presentation-progress-resolver",
            { message in
                if message.code == .presentationUpdating {
                    progressCalls.increment()
                }
                return message.defaultText
            })
        model.formatters = formatters
        model.resolver = resolver
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            presentationStarted.value > 0 && progressCalls.value > 0
        })
        #expect(observed?.requestID != AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: model.chart.context,
            formatters: formatters,
            textResolver: resolver).id)
        presentationGate.release()
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == formatters.callbackIdentity
                && observed?.requestID.resolverCallback == resolver.callbackIdentity
        })
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func slowProgressResolutionDoesNotDelayChartPublication() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let progressStarted = PresentationBlockingGate()
        let progressRelease = PresentationBlockingGate()
        defer {
            progressStarted.release()
            progressRelease.release()
        }
        let formatters = AutoChartFormatters(
            cacheIdentity: "progress-first-formatters",
            request: { _, _, _ in
                _ = progressStarted.wait(timeout: .now() + 2)
                return nil
            })
        let resolver = AutoChartTextResolver(
            cacheIdentity: "blocked-progress-resolver",
            { message in
                if message.code == .presentationUpdating {
                    progressStarted.release()
                    progressRelease.wait()
                }
                return message.defaultText
            })
        model.formatters = formatters
        model.resolver = resolver
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host, timeout: 1) {
            progressStarted.isOpen
        })
        #expect(await waitForHostedChartUpdate(in: host, timeout: 1) {
            observed?.requestID.formatterCallback == formatters.callbackIdentity
                && observed?.requestID.resolverCallback == resolver.callbackIdentity
        })
        progressRelease.release()
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func independentProgressViewsDoNotShareAResolverSlot() async throws {
        #if ATC_TEST_HOOKS
        let slowCalls = PresentationCounter()
        let fastCalls = PresentationCounter()
        let slowGate = PresentationBlockingGate()
        defer { slowGate.release() }
        let slow = AutoChartTextResolver(cacheIdentity: "slow-session-label") { message in
            slowCalls.increment()
            slowGate.wait()
            return "Slow: \(message.defaultText)"
        }
        let fast = AutoChartTextResolver(cacheIdentity: "fast-session-label") { message in
            fastCalls.increment()
            return "Fast: \(message.defaultText)"
        }
        let harness = HostedViewHarnessForTesting(rootView: HStack {
            AutoChartAccessibleProgressView(
                message: AutoChartProgressAccessibility.preparing,
                textResolver: slow)
            AutoChartAccessibleProgressView(
                message: AutoChartProgressAccessibility.preparing,
                textResolver: fast)
        })
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            slowCalls.value > 0 && fastCalls.value > 0 && !slowGate.isOpen
        })
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func backgroundFoundationNotificationsReachRenderingOnMain() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        let threads = PresentationMainThreadProbe()
        var ownerDidAppear = false
        hooks.presentationOwnerDidAppearForTesting = { ownerDidAppear = true }
        hooks.foundationNotificationForTesting = { threads.record() }
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedDefaultPresentationView(model: model, hooks: hooks))
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            observed != nil && ownerDidAppear
        })
        NotificationCenter.default.post(
            name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            threads.result.count > 0
        })
        let before = threads.result.count
        await Task.detached {
            NotificationCenter.default.post(
                name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        }.value
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            threads.result.count >= before + 1
        })
        await Task.detached {
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }.value
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            threads.result.count >= before + 2
        })
        #expect(threads.result.allMain)
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
        var finished: [(AutoChartPresentationRequestID, AutoChartDeferredPresentationOutcome)] = []
        hooks.observe = { observed = $0 }
        hooks.didPublishDeferredPresentation = { _ in publications += 1 }
        hooks.didFinishDeferredPresentation = { finished.append(($0, $1)) }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == source.requestID
                && finished.contains { $0.0 == source.requestID && $0.1 == .exact }
        })
        #expect(publications == 0)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func defaultImmediateModeUsesCachedOverridesAcrossParentRebuilds() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter()
        let source = presenter.present(chart)
        let resolverCalls = PresentationCounter()
        let formatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US"))
        let resolver = AutoChartTextResolver(
            cacheIdentity: "hosted-default-cached-resolver",
            { message in
                if message.code.rawValue.hasPrefix("chartFamily.") {
                    resolverCalls.increment()
                }
                return "Cached: \(message.defaultText)"
            })
        let expected = presenter.present(
            chart, formatters: formatters, textResolver: resolver)
        let resolverCallsAfterCaching = resolverCalls.value
        let model = HostedPresentationModel(chart: source, analysisID: analysisID)
        model.formatters = formatters
        model.resolver = resolver
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var audioGraphReports = 0
        hooks.observe = { observed = $0 }
        hooks.observeAudioGraph = { _, _ in audioGraphReports += 1 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedDefaultPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == expected.requestID && audioGraphReports > 0
        })
        #expect(resolverCalls.value == resolverCallsAfterCaching)
        let reportsBeforeRebuild = audioGraphReports
        model.revision += 1
        #expect(await waitForHostedChartUpdate(in: host) {
            audioGraphReports > reportsBeforeRebuild
                && observed?.requestID == expected.requestID
        })
        #expect(resolverCalls.value == resolverCallsAfterCaching)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func rapidChartRoundTripDoesNotRestoreAbandonedOverride() async throws {
        #if ATC_TEST_HOOKS
        let (analysisIDA, chartA) = try await presentationFixture()
        let (analysisIDB, chartB) = try await presentationFixture(offset: 100)
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let sourceA = presenter.present(chartA)
        let sourceB = presenter.present(chartB)
        let model = HostedPresentationModel(chart: sourceA, analysisID: analysisIDA)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var publications: [AutoChartPresentationRequestID] = []
        var finished: [(AutoChartPresentationRequestID, AutoChartDeferredPresentationOutcome)] = []
        hooks.observe = { observed = $0 }
        hooks.didPublishDeferredPresentation = { publications.append($0) }
        hooks.didFinishDeferredPresentation = { finished.append(($0, $1)) }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == sourceA.requestID
        })

        let oldAFormatters = AutoChartFormatters(
            cacheIdentity: "abandoned-a-override",
            request: { request, _, _ in
                "Old A: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = oldAFormatters
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == oldAFormatters.callbackIdentity
        })
        let publicationCountAfterOldA = publications.count

        let bStarted = PresentationCounter()
        let bRelease = PresentationBlockingGate()
        defer { bRelease.release() }
        let blockedBFormatters = AutoChartFormatters(
            cacheIdentity: "abandoned-b-override",
            request: { request, _, _ in
                bStarted.increment()
                bRelease.wait()
                return "Old B: \(request.value.categoryString() ?? "value")"
            })
        model.chart = sourceB
        model.analysisID = analysisIDB
        model.formatters = blockedBFormatters
        #expect(await waitForHostedChartUpdate(in: host) {
            bStarted.value > 0
                && observed?.requestID.preparedChart == chartB.id
        })

        model.formatters = nil
        model.chart = sourceA
        model.analysisID = analysisIDA
        #expect(await waitForHostedChartUpdate(in: host, timeout: 1) {
            observed?.requestID == sourceA.requestID
        })
        #expect(observed?.requestID.formatterCallback != oldAFormatters.callbackIdentity)
        bRelease.release()
        #expect(await waitForHostedChartUpdate(in: host) {
            finished.contains {
                $0.0.formatterCallback == blockedBFormatters.callbackIdentity
                    && $0.1 == .cancelled
            }
        })
        #expect(observed?.requestID == sourceA.requestID)
        #expect(publications.count == publicationCountAfterOldA)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func replacingSourceForSameChartDoesNotShowPriorOverride() async throws {
        #if ATC_TEST_HOOKS
        let (analysisID, chart) = try await presentationFixture()
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let model = HostedPresentationModel(
            chart: presenter.present(chart), analysisID: analysisID)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        var reports = 0
        hooks.observe = { observed = $0; reports += 1 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: host) { observed != nil })

        let old = AutoChartFormatters(
            cacheIdentity: "same-chart-old-source",
            request: { request, _, _ in
                guard request.context == .axisTick,
                    request.column?.id == "x"
                else { return nil }
                return "Old: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = old
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.formatterCallback == old.callbackIdentity
        })

        let fresh = AutoChartFormatters(
            cacheIdentity: "same-chart-new-source",
            request: { request, _, _ in
                guard request.context == .axisTick,
                    request.column?.id == "x"
                else { return nil }
                return "New: \(request.value.categoryString() ?? "value")"
            })
        let newSource = presenter.present(chart, formatters: fresh)
        let started = PresentationCounter()
        let release = PresentationBlockingGate()
        defer { release.release() }
        let slow = AutoChartFormatters(
            cacheIdentity: "same-chart-slow-update",
            request: { request, _, _ in
                started.increment()
                release.wait()
                return "Slow: \(request.value.categoryString() ?? "value")"
            })
        model.chart = newSource
        model.formatters = slow
        #expect(await waitForHostedChartUpdate(in: host) { started.value > 0 })
        let beforeInspection = reports
        model.revision += 1
        #expect(await waitForHostedChartUpdate(in: host) {
            reports > beforeInspection
        })
        #expect(observed?.requestID == newSource.requestID)
        #expect(observed?.renderedXLabels == newSource.renderedData.compactMap(\.xLabel))
        release.release()
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func mountingTwoChartsDoesNotClearTheSharedSelectionBinding() async throws {
        #if ATC_TEST_HOOKS
        let (analysisIDA, chartA) = try await presentationFixture()
        let (analysisIDB, chartB) = try await presentationFixture(offset: 100)
        let (analysisIDC, chartC) = try await presentationFixture(offset: 200)
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chartA), analysisID: analysisIDA)
        let hooksA = AutoChartViewTestHooks()
        let hooksB = AutoChartViewTestHooks()
        var observedA: AutoChartViewTestHookState?
        var observedB: AutoChartViewTestHookState?
        hooksA.observe = { observedA = $0 }
        hooksB.observe = { observedB = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedSharedSelectionView(
                model: model, hooksA: hooksA, hooksB: hooksB),
            size: NSSize(width: 600, height: 500))
        let host = harness.host
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: host) {
            observedA?.requestID == model.chart.requestID
        })

        let mark = try #require(chartA.marks.first)
        model.selection = chartA.selections(
            for: mark.sourceRowIDs, analysisID: analysisIDA)
        let saved = model.selection
        let linkedRows = saved.unionedSourceRows
        #expect(!linkedRows.isEmpty)
        model.secondaryChart = presenter.present(chartB)
        model.secondaryAnalysisID = analysisIDB
        #expect(await waitForHostedChartUpdate(in: host) {
            observedB?.requestID.preparedChart == chartB.id
        })
        #expect(model.selection == saved)
        #expect(model.selection.unionedSourceRows == linkedRows)
        #expect(observedB?.selectionCount == 0)
        #expect(observedB?.hasSelectionSummary == false)
        #expect(observedB?.hasForeignSelectionNotice == true)
        #expect(observedA?.selectionCount == 1)

        model.secondaryChart = presenter.present(chartC)
        model.secondaryAnalysisID = analysisIDC
        #expect(await waitForHostedChartUpdate(in: host) {
            observedB?.requestID.preparedChart == chartC.id
        })
        #expect(model.selection == saved)
        #expect(observedB?.selectionCount == 0)
        model.secondaryAnalysisID = AutoChartAnalysisID()
        model.revision += 1
        #expect(await waitForHostedChartUpdate(in: host) {
            observedB?.requestID.preparedChart == chartC.id
                && observedB?.selectionCount == 0
        })
        #expect(model.selection == saved)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func foreignSelectionNoticeClearsAHostOwnedBinding() async throws {
        #if ATC_TEST_HOOKS
        let (analysisIDA, chartA) = try await presentationFixture()
        let (analysisIDB, chartB) = try await presentationFixture(offset: 100)
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chartB), analysisID: analysisIDB)
        let mark = try #require(chartA.marks.first)
        model.selection = chartA.selections(
            for: mark.sourceRowIDs, analysisID: analysisIDA)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            observed?.hasForeignSelectionNotice == true
        })
        #expect(!model.selection.isEmpty)
        let pressClear = try #require(hooks.pressForeignSelectionClearForTesting)
        pressClear()
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            model.selection.isEmpty && observed?.hasForeignSelectionNotice == false
        })
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
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }
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

        let savedSelection = model.selection
        model.chart = sourceB
        model.analysisID = nextAnalysisID
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID.preparedChart == chartB.id
                && observed?.zoomScale.wrappedValue == 1
                && observed?.selectionCount == 0
        })
        #expect(observed?.requestID == sourceB.requestID)
        #expect(model.selection == savedSelection)

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
        #expect(model.selection == savedSelection)
        withExtendedLifetime(presenter) {}
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func equivalentReanalysisKeepsZoomButResetsSelectionProvenance() async throws {
        #if ATC_TEST_HOOKS
        let (analysisIDA, chartA) = try await presentationFixture()
        let (analysisIDB, chartB) = try await presentationFixture()
        let (analysisIDC, chartC) = try await presentationFixture(offset: 100)
        #expect(chartA.id != chartB.id)
        #expect(chartA.core.fingerprint == chartB.core.fingerprint)
        let presenter = AutoChartPresenter()
        let model = HostedPresentationModel(
            chart: presenter.present(chartA), analysisID: analysisIDA)
        let hooks = AutoChartViewTestHooks()
        var observed: AutoChartViewTestHookState?
        hooks.observe = { observed = $0 }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) { observed != nil })
        let first = try #require(observed)
        first.zoomAnchor.wrappedValue = 3
        first.zoomScale.wrappedValue = 3
        let mark = try #require(chartA.marks.first)
        model.selection = chartA.selections(
            for: mark.sourceRowIDs, analysisID: analysisIDA)
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            observed?.zoomScale.wrappedValue == 3 && observed?.selectionCount == 1
        })

        model.chart = presenter.present(chartB)
        model.analysisID = analysisIDB
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            observed?.requestID.preparedChart == chartB.id
                && observed?.zoomScale.wrappedValue == 3
                && observed?.selectionCount == 0
                && observed?.hasForeignSelectionNotice == true
        })
        model.chart = presenter.present(chartC)
        model.analysisID = analysisIDC
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            observed?.requestID.preparedChart == chartC.id
                && observed?.zoomScale.wrappedValue == 1
        })
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
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

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
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }

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
        var publications: [AutoChartPresentationRequestID] = []
        var finished: [(AutoChartPresentationRequestID, AutoChartDeferredPresentationOutcome)] = []
        hooks.observe = { observed = $0; reports += 1 }
        hooks.didPublishDeferredPresentation = { publications.append($0) }
        hooks.didFinishDeferredPresentation = { finished.append(($0, $1)) }
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }
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
        let publicationsBeforeRemovingOverride = publications.count
        let exactFinishesBeforeRemovingOverride = finished.filter {
            $0.0 == model.chart.requestID && $0.1 == .exact
        }.count
        model.formatters = nil
        #expect(await waitForHostedChartUpdate(in: host) {
            observed?.requestID == model.chart.requestID
                && finished.filter {
                    $0.0 == model.chart.requestID && $0.1 == .exact
                }.count > exactFinishesBeforeRemovingOverride
        })
        #expect(publications.count == publicationsBeforeRemovingOverride)
        #expect(observed?.selectedCategory == initialCategory)
        #expect(try #require(observed).zoomScale.wrappedValue == 3)
        #expect(model.selection == savedSelection)

        let slowCalls = PresentationCounter()
        let slowRelease = PresentationBlockingGate()
        defer { slowRelease.release() }
        let slowFormatters = AutoChartFormatters(
            cacheIdentity: "slow-superseded",
            request: { request, _, _ in
                slowCalls.increment()
                slowRelease.wait()
                return "Superseded: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = slowFormatters
        let slowStarted = await waitForHostedChartUpdate(in: host) { slowCalls.value > 0 }
        #expect(slowStarted)
        let reportsBeforePendingInspection = reports
        model.revision += 1
        #expect(await waitForHostedChartUpdate(in: host) {
            reports > reportsBeforePendingInspection
        })
        #expect(observed?.requestID == model.chart.requestID)
        #expect(observed?.renderedXLabels == model.chart.renderedData.compactMap(\.xLabel))
        let latestFormatters = AutoChartFormatters(
            cacheIdentity: "latest-formatters",
            request: { request, _, _ in
                "Latest: \(request.value.categoryString() ?? "value")"
            })
        model.formatters = latestFormatters
        #expect(await waitForHostedChartUpdate(in: host, timeout: 1) {
            observed?.requestID.formatterCallback == latestFormatters.callbackIdentity
        })
        #expect(!publications.contains {
            $0.formatterCallback == slowFormatters.callbackIdentity
        })
        slowRelease.release()
        #expect(await waitForHostedChartUpdate(in: host) {
            finished.contains {
                $0.0.formatterCallback == slowFormatters.callbackIdentity
                    && $0.1 == .cancelled
            }
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
        let harness = HostedViewHarnessForTesting(
            rootView: HostedPresentationView(model: model, hooks: hooks))
        let host = harness.host
        defer { harness.close() }
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
    @Published var secondaryChart: AutoChartPresentedChart<Int>?
    @Published var secondaryAnalysisID: AutoChartAnalysisID?
    @Published var revision = 0
    init(chart: AutoChartPresentedChart<Int>, analysisID: AutoChartAnalysisID) {
        self.chart = chart
        self.analysisID = analysisID
    }
}

private struct HostedSharedSelectionView: View {
    @ObservedObject var model: HostedPresentationModel
    let hooksA: AutoChartViewTestHooks
    let hooksB: AutoChartViewTestHooks

    var body: some View {
        VStack {
            AutoChartView(
                presentedChart: model.chart,
                analysisID: model.analysisID,
                selection: $model.selection,
                presentation: .explorer(plotHeight: 180))
                .environment(\.autoChartViewTestHooks, hooksA)
            if let chart = model.secondaryChart,
                let analysisID = model.secondaryAnalysisID
            {
                AutoChartView(
                    presentedChart: chart,
                    analysisID: analysisID,
                    selection: $model.selection,
                    presentation: .explorer(plotHeight: 180))
                    .environment(\.autoChartViewTestHooks, hooksB)
            }
        }
        .frame(width: 600, height: 500)
    }
}

private struct HostedPresentationView: View {
    @ObservedObject var model: HostedPresentationModel
    let hooks: AutoChartViewTestHooks
    var scheduling: AutoChartDeferredCallbackScheduling? = nil
    @ViewBuilder var body: some View {
        let chart = AutoChartView(
            presentedChart: model.chart, analysisID: model.analysisID,
            selection: $model.selection,
            formatters: model.formatters,
            textResolver: model.resolver,
            overridePresentationMode: .deferred)
            .environment(\.autoChartViewTestHooks, hooks)
            .environment(\.autoChartViewRevisionForTesting, model.revision)
            .frame(width: 600, height: 400)
        if let scheduling {
            chart.autoChartDeferredCallbackScheduling(scheduling)
        } else {
            chart
        }
    }
}

private struct HostedDefaultPresentationView: View {
    @ObservedObject var model: HostedPresentationModel
    let hooks: AutoChartViewTestHooks
    var body: some View {
        AutoChartView(
            presentedChart: model.chart,
            analysisID: model.analysisID,
            selection: $model.selection,
            formatters: model.formatters,
            textResolver: model.resolver)
            .environment(\.autoChartViewTestHooks, hooks)
            .environment(\.autoChartViewRevisionForTesting, model.revision)
            .frame(width: 600, height: 400)
    }
}

@MainActor
final class HostedViewHarnessForTesting<Content: View> {
    let window: NSWindow
    let host: NSHostingView<Content>

    init(rootView: Content, size: NSSize = NSSize(width: 600, height: 400)) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: rootView)
        window.contentView = host
        window.orderFront(nil)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
func waitForHostedChartUpdate(
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
