import Dispatch
import Foundation
import SwiftUI
import Testing

#if os(macOS)
import AppKit
#endif

#if canImport(Accessibility)
import Accessibility
#endif

@testable import AutoTableCharts
@testable import AutoTableChartsUI

#if canImport(Accessibility)
@Suite struct AudioGraphDescriptorTests {
    @Test func descriptorPreservesSeriesCategoriesAndSpokenUnits() throws {
        let input = AutoChartAudioGraphDescriptor(
            title: "Value by type",
            xAxis: .categorical(title: "Type", order: ["Office", "Retail"]),
            yTitle: "Value",
            yRange: 0...20,
            yValueDescription: { "$\(Int($0))" },
            additionalAxis: nil,
            series: [
                .init(
                    name: "Portfolio",
                    isContinuous: false,
                    points: [
                        .init(
                            x: .category("Office"),
                            y: 20,
                            label: "Office, $20",
                            additionalValue: nil)
                    ])
            ])
        let descriptor = input.makeChartDescriptor()
        let xAxis = try #require(
            descriptor.xAxis as? AXCategoricalDataAxisDescriptor)
        let yAxis = try #require(descriptor.yAxis)

        #expect(descriptor.title == "Value by type")
        #expect(xAxis.categoryOrder == ["Office", "Retail"])
        #expect(yAxis.valueDescriptionProvider(20) == "$20")
        #expect(descriptor.series.first?.dataPoints.first?.label == "Office, $20")
    }

    @Test func partialSizeValuesSuppressBothAxisAndPointPayloads() throws {
        let input = AutoChartAudioGraphDescriptor(
            title: "Bubble",
            xAxis: .numeric(title: "X", range: 0...1, valueDescription: { String($0) }),
            yTitle: "Y",
            yRange: 0...1,
            yValueDescription: { String($0) },
            additionalAxis: (
                title: "Market value",
                range: 1...2,
                valueDescription: { String($0) }),
            series: [
                .init(
                    name: "Series",
                    isContinuous: false,
                    points: [
                        .init(x: .number(0), y: 0, label: "Complete", additionalValue: 1),
                        .init(x: .number(1), y: 1, label: "Missing size", additionalValue: nil),
                    ])
            ])
        let descriptor = input.makeChartDescriptor()

        #expect(descriptor.additionalAxes.isEmpty)
        #expect(
            descriptor.series.flatMap(\.dataPoints).allSatisfy {
                $0.__additionalValues.isEmpty
            })
    }

    @Test func presenterMarksFacetedLineAudioSeriesContinuous() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request)
        let specification = AutoChartSpecification(
            family: .faceted,
            encoding: .init(x: "start", y: "value", facet: "category"),
            facetBaseFamily: .line)
        let chart = try await analysis.prepare(specification)
        let descriptor = try #require(
            AutoChartPresenter().present(chart).makeAudioGraphDescriptor())

        #expect(!descriptor.series.isEmpty)
        #expect(descriptor.series.allSatisfy { $0.isContinuous })
    }

    @Test func presenterUsesCountAndDisplayAwareSizeAxisTitles() async throws {
        let x = AutoChartColumn(id: "x", name: "x", semantics: .measure())
        let y = AutoChartColumn(id: "y", name: "y", semantics: .measure())
        let size = AutoChartColumn(
            id: "size", name: "raw_size", displayName: "Market capitalization",
            semantics: .measure())
        let firstCategory = AutoChartColumn(
            id: "first", name: "first",
            semantics: .dimension(semanticType: .nominal))
        let secondCategory = AutoChartColumn(
            id: "second", name: "second",
            semantics: .dimension(semanticType: .nominal))
        let dataset = try AutoChartDataset(
            columns: [x, y, size, firstCategory, secondCategory],
            rows: [
                [.double(1), .double(2), .double(3), .text("A"), .text("One")],
                [.double(2), .double(4), .double(6), .text("B"), .text("Two")],
            ],
            rowIDs: [1, 2])
        let analysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: dataset))

        let bubble = try await analysis.prepare(
            AutoChartSpecification(
                family: .bubble,
                encoding: .init(x: x.id, y: y.id, size: size.id)))
        let bubbleDescriptor = try #require(
            AutoChartPresenter().present(bubble).makeAudioGraphDescriptor())
        #expect(bubbleDescriptor.additionalAxis?.title == "Market capitalization")

        let heatmap = try await analysis.prepare(
            .heatmap(x: firstCategory.id, y: secondCategory.id))
        let presentedHeatmap = AutoChartPresenter().present(heatmap)
        let heatmapDescriptor = try #require(
            presentedHeatmap.makeAudioGraphDescriptor())
        #expect(heatmapDescriptor.yTitle == "Count")

        let localizedPresented = AutoChartPresenter().present(
            heatmap,
            formatters: .init(),
            textResolver: AutoChartTextResolver { message in
                "localized:\(message.defaultText)"
            })
        let localized = try #require(localizedPresented.makeAudioGraphDescriptor())
        #expect(localized.title == "localized:Heatmap")
        #expect(localized.yTitle == "localized:Count")
    }

    @Test func lazyAudioGraphDescriptorBuildsFormatterBackedContentOnce() async throws {
        let x = AutoChartColumn(
            id: "x", name: "x", semantics: .dimension(semanticType: .nominal))
        let y = AutoChartColumn(id: "y", name: "y", semantics: .measure())
        let dataset = try AutoChartDataset(
            columns: [x, y],
            rows: [[.text("A"), .double(2)], [.text("B"), .double(4)]],
            rowIDs: [1, 2])
        let analysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: dataset))
        let chart = try await analysis.prepare(.bar(category: x.id, measure: y.id))
        let calls = V3Counter()
        let measureRequest = V3LockedBox<AutoChartFormattingRequest>()
        let formatters = AutoChartFormatters(request: { request, _, _ in
            guard request.context == .markAccessibility else { return nil }
            if request.column?.id == x.id {
                calls.increment()
                return "render-time"
            }
            if request.column?.id == y.id {
                measureRequest.store(request)
                return "measure-value"
            }
            return nil
        })

        let presented = AutoChartPresenter().present(chart, formatters: formatters)
        #expect(calls.value == 0)
        #expect(measureRequest.value == nil)

        await MainActor.run {
            _ = AutoChartView(
                presentedChart: presented,
                analysisID: analysis.id,
                formatters: formatters)
        }
        #expect(calls.value == 0)
        #expect(measureRequest.value == nil)

        let cache = AutoChartAudioGraphViewCache()
        let lazy = try #require(presented.makeLazyAudioGraphDescriptor(cache: cache))
        _ = lazy.makeChartDescriptor()
        let firstBuildCalls = calls.value
        #expect(firstBuildCalls > 0)
        _ = lazy.makeChartDescriptor()
        #expect(calls.value == firstBuildCalls)

        let secondLazy = try #require(presented.makeLazyAudioGraphDescriptor(cache: cache))
        let target = secondLazy.makeChartDescriptor()
        #expect(calls.value == firstBuildCalls)
        let originalXAxis = target.xAxis
        let originalPoint = try #require(target.series.first?.dataPoints.first)
        secondLazy.updateChartDescriptor(target)
        #expect(calls.value == firstBuildCalls)
        #expect(target.xAxis === originalXAxis)
        #expect(target.series.first?.dataPoints.first === originalPoint)

        let independent = try #require(presented.makeLazyAudioGraphDescriptor())
        _ = independent.makeChartDescriptor()
        #expect(calls.value > firstBuildCalls)

        let descriptor = secondLazy.descriptor()
        #expect(descriptor.yValueDescription(2) == "measure-value")
        let request = try #require(measureRequest.value)
        #expect(request.column?.id == y.id)
        #expect(request.value == .double(2))
        #expect(request.context == .markAccessibility)
        #expect(request.purpose == .value)
    }

    @Test func emptyAndAllNullBarsExposeNoAudioGraph() async throws {
        let category = AutoChartColumn(
            id: "category", name: "Category",
            semantics: .dimension(semanticType: .nominal))
        let measure = AutoChartColumn(
            id: "measure", name: "Measure", semantics: .measure())

        for rows in [
            [[AutoChartValue.text("A"), .null], [.text("B"), .null]],
            [],
        ] {
            let dataset = try AutoChartDataset(
                columns: [category, measure], rows: rows, rowIDs: Array(rows.indices))
            let analysis = try await AutoChartAnalyzer().analyze(
                try AutoChartRequest(table: dataset))
            let chart = try await analysis.prepare(
                .bar(category: category.id, measure: measure.id))
            let presented = AutoChartPresenter().present(chart)

            #expect(presented.renderedData.isEmpty)
            #expect(presented.makeAudioGraphDescriptor() == nil)
            #expect(presented.makeLazyAudioGraphDescriptor() == nil)
        }
    }

    @Test func unsupportedFamiliesExposeNoLazyAudioGraphDescriptor() async throws {
        let measure = AutoChartColumn(
            id: "measure", name: "Measure", semantics: .measure())
        let singleValue = try AutoChartDataset(
            columns: [measure], rows: [[.double(1)]], rowIDs: [1])
        let kpiAnalysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: singleValue))
        let kpi = try await kpiAnalysis.prepare(.kpi(measure: measure.id))
        #expect(AutoChartPresenter().present(kpi).makeLazyAudioGraphDescriptor() == nil)

        let rangeAnalysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: domainDataset()))
        let range = try await rangeAnalysis.prepare(
            .range(label: "category", start: "start", end: "end"))
        #expect(AutoChartPresenter().present(range).makeLazyAudioGraphDescriptor() == nil)
    }

    @Test @MainActor
    func viewOverridesRepresentTheCompletePresentationPayload() async throws {
        let category = AutoChartColumn(
            id: "category", name: "Category",
            semantics: .dimension(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "Facet",
            semantics: .dimension(semanticType: .nominal))
        let measure = AutoChartColumn(
            id: "measure", name: "Measure", semantics: .measure())
        let dataset = try AutoChartDataset(
            columns: [category, measure, facet],
            rows: [
                [.text("z"), .double(1), .text("z")],
                [.text("ä"), .double(1), .text("ä")],
            ],
            rowIDs: [1, 2])
        let analysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: dataset))
        let chart = try await analysis.prepare(
            AutoChartSpecification(
                family: .faceted,
                encoding: .init(x: category.id, y: measure.id, facet: facet.id),
                facetBaseFamily: .bar,
                sort: .ascending))
        let presenter = AutoChartPresenter(maximumEntries: 0)
        let swedish = presenter.present(
            chart,
            formatters: .init(locale: Locale(identifier: "sv_SE")))
        let resolverCalls = V3Counter()
        let formatterCalls = V3Counter()
        let callbackThreads = V3ThreadRecorder()
        let americanFormatters = AutoChartFormatters(
            locale: Locale(identifier: "en_US"),
            request: { _, _, _ in
                formatterCalls.increment()
                callbackThreads.recordCurrentThread()
                return nil
            })
        let americanResolver = AutoChartTextResolver { message in
            resolverCalls.increment()
            callbackThreads.recordCurrentThread()
            return "US: \(message.defaultText)"
        }

        _ = AutoChartView(
            presentedChart: swedish,
            analysisID: analysis.id,
            formatters: americanFormatters,
            textResolver: americanResolver)
        #expect(resolverCalls.value > 0)
        #expect(formatterCalls.value > 0)
        let afterFirstOverride = resolverCalls.value
        let formatterCallsAfterFirstOverride = formatterCalls.value
        _ = AutoChartView(
            presentedChart: swedish, analysisID: analysis.id,
            formatters: americanFormatters, textResolver: americanResolver)
        #expect(resolverCalls.value > afterFirstOverride)
        #expect(formatterCalls.value > formatterCallsAfterFirstOverride)
        #if ATC_TEST_HOOKS && os(macOS)
        let hooks = AutoChartViewTestHooks()
        var hostedPayload: AutoChartViewTestHookState?
        hooks.observe = { hostedPayload = $0 }
        let harness = HostedViewHarnessForTesting(rootView:
            AutoChartView(
                presentedChart: swedish,
                analysisID: analysis.id,
                formatters: americanFormatters,
                textResolver: americanResolver)
                .environment(\.autoChartViewTestHooks, hooks)
                .frame(width: 600, height: 400))
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            hostedPayload?.requestID.formatterCallback
                == americanFormatters.callbackIdentity
                && hostedPayload?.requestID.resolverCallback
                    == americanResolver.callbackIdentity
        })
        #endif
        let callbackThreadResult = callbackThreads.result
        #expect(callbackThreadResult.count > 0)
        #expect(callbackThreadResult.allMainThread)
        let american = presenter.present(
            chart,
            formatters: americanFormatters,
            textResolver: americanResolver)

        #if ATC_TEST_HOOKS && os(macOS)
        #expect(hostedPayload?.requestID == american.requestID)
        #expect(hostedPayload?.displayTitle == american.title)
        #expect(hostedPayload?.renderedXLabels
            == american.renderedData.compactMap(\.xLabel))
        #expect(hostedPayload?.facetDisplayValues
            == american.facetPanels.map(\.displayValue))
        #expect(hostedPayload?.sharedXCategoryDomain
            == american.sharedXCategoryDomain)
        #endif

        #expect(swedish.sharedXCategoryDomain == ["z", "ä"])
        #expect(american.sharedXCategoryDomain == ["ä", "z"])
        #expect(american.renderedData.compactMap(\.xLabel) == ["ä", "z"])
        #expect(swedish.facetPanels.map(\.displayValue) == ["z", "ä"])
        #expect(american.facetPanels.map(\.displayValue) == ["ä", "z"])
        #expect(american.title == "US: Small multiples")
        let descriptor = try #require(american.makeAudioGraphDescriptor())
        guard case .categorical(_, let audioOrder) = descriptor.xAxis else {
            Issue.record("Expected a categorical Audio Graph x axis")
            return
        }
        #expect(audioOrder == american.sharedXCategoryDomain)
        #expect(
            descriptor.series.flatMap(\.points).map(\.label).allSatisfy {
                $0.contains("ä") || $0.contains("z")
            })

        let cache = AutoChartAudioGraphViewCache()
        let existingAXDescriptor = try #require(
            swedish.makeLazyAudioGraphDescriptor(cache: cache)).makeChartDescriptor()
        let originalFrame = CGRect(x: 1, y: 2, width: 300, height: 200)
        existingAXDescriptor.contentFrame = originalFrame
        let overriddenAudioGraph = try #require(american.makeLazyAudioGraphDescriptor(cache: cache))
        overriddenAudioGraph.updateChartDescriptor(existingAXDescriptor)
        let updatedPoint = try #require(existingAXDescriptor.series.first?.dataPoints.first)
        overriddenAudioGraph.updateChartDescriptor(existingAXDescriptor)
        #expect(existingAXDescriptor.series.first?.dataPoints.first === updatedPoint)
        let updatedXAxis = try #require(
            existingAXDescriptor.xAxis as? AXCategoricalDataAxisDescriptor)
        #expect(existingAXDescriptor.contentFrame == originalFrame)
        #expect(existingAXDescriptor.title == american.title)
        #expect(updatedXAxis.categoryOrder == american.sharedXCategoryDomain)
        #expect(existingAXDescriptor.yAxis?.title == descriptor.yTitle)
        #expect(
            existingAXDescriptor.series.flatMap(\.dataPoints).map(\.label)
                == descriptor.series.flatMap(\.points).map(\.label))
        withExtendedLifetime(presenter) {}
    }

    @Test func singletonExtremeAudioGraphRangesRemainFiniteAndOrdered() async throws {
        for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            let x = AutoChartColumn(id: "x", name: "X", semantics: .measure())
            let y = AutoChartColumn(id: "y", name: "Y", semantics: .measure())
            let dataset = try AutoChartDataset(
                columns: [x, y],
                rows: [[.double(value), .double(value)]],
                rowIDs: [1])
            let analysis = try await AutoChartAnalyzer().analyze(
                try AutoChartRequest(table: dataset))
            let chart = try await analysis.prepare(.scatter(x: x.id, y: y.id))
            let descriptor = try #require(
                AutoChartPresenter().present(chart).makeAudioGraphDescriptor())
            guard case .numeric(_, let xRange, _) = descriptor.xAxis else {
                Issue.record("Expected a numeric Audio Graph x axis")
                continue
            }

            for range in [xRange, descriptor.yRange] {
                #expect(range.lowerBound.isFinite)
                #expect(range.upperBound.isFinite)
                #expect(range.lowerBound < range.upperBound)
                #expect(range.contains(value))
            }

            let axDescriptor = descriptor.makeChartDescriptor()
            let xAxis = try #require(
                axDescriptor.xAxis as? AXNumericDataAxisDescriptor)
            let yAxis = try #require(axDescriptor.yAxis)
            for axis in [xAxis, yAxis] {
                #expect(axis.range.lowerBound.isFinite)
                #expect(axis.range.upperBound.isFinite)
                #expect(axis.range.lowerBound < axis.range.upperBound)
                #expect(axis.range.contains(value))
                #expect(axis.gridlinePositions.allSatisfy { $0.isFinite })
                #expect(
                    zip(axis.gridlinePositions, axis.gridlinePositions.dropFirst())
                        .allSatisfy { $0 <= $1 })
            }
        }
    }
}
#endif

private struct V3Record: Sendable {
    let id: Int
    let category: String
    let series: String
    let value: Double
    let secondValue: Double
    let start: Date
    let end: Date
}

private struct LegacyV3Column: Encodable {
    let id: AutoChartColumnID
    let name: String
    let displayName: String?
    let hints: AutoChartColumnHints
}

/// Mirrors the synthesized Codable shape shipped in 0.1.0. These fixtures
/// intentionally remain separate from the current hints model so compatibility
/// tests fail if a required released field disappears again.
private enum ReleasedV1AggregationSafety: String, Codable {
    case unknown, rowLevel, safe, alreadyAggregated, unsafe
}

private struct ReleasedV1ColumnHints: Codable {
    let semanticType: AutoChartSemanticType?
    let role: AutoChartAnalyticRole?
    let unit: AutoChartUnit?
    let aggregation: AutoChartAggregation?
    let aggregationSafety: ReleasedV1AggregationSafety
    let grain: String?
}

private struct ReleasedV1Column: Codable {
    let id: AutoChartColumnID
    let name: String
    let displayName: String?
    let hints: ReleasedV1ColumnHints
}

private func releasedV1MeasureHints(
    aggregation: AutoChartAggregation?,
    safety: ReleasedV1AggregationSafety
) -> ReleasedV1ColumnHints {
    ReleasedV1ColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: nil,
        aggregation: aggregation,
        aggregationSafety: safety,
        grain: nil)
}

private struct V3CatalogPayload: Encodable {
    let featured: [AutoChartRecommendation]
    let cataloged: [AutoChartRecommendation]
    let preferred: AutoChartRecommendation?
}

private func v3Records() -> [V3Record] {
    [
        V3Record(
            id: 10, category: "North", series: "Actual", value: 10,
            secondValue: 4, start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600)),
        V3Record(
            id: 20, category: "South", series: "Actual", value: 20,
            secondValue: 8, start: Date(timeIntervalSince1970: 86_400),
            end: Date(timeIntervalSince1970: 90_000)),
        V3Record(
            id: 30, category: "North", series: "Plan", value: 30,
            secondValue: 12, start: Date(timeIntervalSince1970: 172_800),
            end: Date(timeIntervalSince1970: 176_400)),
    ]
}

private func domainDataset(
    records: [V3Record] = v3Records(),
    key: AutoChartDataKey = .contentAddressed(identity: "v3-fixture")
) throws -> AutoChartDataset<Int> {
    try AutoChartDataset(records: records, rowID: \.id, key: key) {
        Identifier<V3Record>("id", name: "Record ID") { $0.id }
        AutoChartDimension<V3Record>("category", name: "Region") { $0.category }
        AutoChartDimension<V3Record>("series", name: "Scenario", role: .series) { $0.series }
        Measure<V3Record>(
            "value",
            name: "Value",
            unit: .currency(code: "USD"),
            semantics: .init(
                source: .rowLevel,
                rollup: .additive,
                preferredTransform: .sum)
        ) { $0.value }
        Measure<V3Record>("second", name: "Second") { $0.secondValue }
        Interval<V3Record>(
            startID: "start", startName: "Start",
            endID: "end", endName: "End",
            grain: "hour",
            start: { $0.start }, end: { $0.end })
    }
}

private func wideDomainDataset() throws -> AutoChartDataset<Int> {
    let dimensionCount = 8
    let measureCount = 8
    let dimensions = (0..<dimensionCount).map { index in
        AutoChartColumn(
            id: .init(rawValue: "dimension-\(index)"),
            name: "Dimension \(index)",
            semantics: .dimension(semanticType: .nominal))
    }
    let measures = (0..<measureCount).map { index in
        AutoChartColumn(
            id: .init(rawValue: "measure-\(index)"),
            name: "Measure \(index)",
            semantics: .measure(semantics: .init(rollup: .additive)))
    }
    let rows: [[AutoChartValue]] = (0..<4).map { row in
        dimensions.indices.map { column in
            .text("D\(column)-R\(row)")
        } + measures.indices.map { column in
            .double(Double((column + 1) * (row + 1)))
        }
    }
    return try AutoChartDataset(
        columns: dimensions + measures,
        rows: rows,
        rowIDs: Array(0..<rows.count),
        key: .trusted(identity: "wide-v3-fixture", revision: "1"))
}

private func recommendation(
    _ specification: AutoChartSpecification,
    score: Double = 1
) -> AutoChartRecommendation {
    AutoChartRecommendation(
        specification: specification,
        score: score,
        rationale: [
            AutoChartMessage(
                category: .rationale,
                code: .recommendationRationale,
                defaultText: "Test recommendation.")
        ])
}

private final class V3Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}

private final class V3LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    func store(_ value: Value) {
        lock.withLock { storage = value }
    }

    var value: Value? {
        lock.withLock { storage }
    }
}

private final class V3OneShotBlockingCallback: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private let blockedInvocation: Int
    private var invocationCount = 0
    private var completedInvocationCount = 0
    private var armed: Bool
    private var blocked = false
    private var timedOut = false

    init(blockedInvocation: Int = 1, startsArmed: Bool = true) {
        self.blockedInvocation = blockedInvocation
        self.armed = startsArmed
    }

    var isBlocked: Bool { lock.withLock { blocked } }
    var completedInvocations: Int { lock.withLock { completedInvocationCount } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func arm() {
        lock.withLock {
            invocationCount = 0
            armed = true
        }
    }

    func invoke() {
        let shouldBlock = lock.withLock {
            invocationCount += 1
            return armed && invocationCount == blockedInvocation
        }
        if shouldBlock {
            lock.withLock { blocked = true }
            let outcome = released.wait(timeout: .now() + 5)
            lock.withLock {
                blocked = false
                timedOut = timedOut || outcome == .timedOut
            }
        }
        lock.withLock { completedInvocationCount += 1 }
    }

    func release() {
        released.signal()
    }
}

private final class V3ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0
    private var observedMainThread = false
    private var allMainThread = true

    func recordCurrentThread() {
        lock.withLock {
            callbackCount += 1
            observedMainThread = observedMainThread || Thread.isMainThread
            allMainThread = allMainThread && Thread.isMainThread
        }
    }

    var result: (count: Int, observedMainThread: Bool, allMainThread: Bool) {
        lock.withLock { (callbackCount, observedMainThread, allMainThread) }
    }
}

private actor V3AsyncTestGate {
    private var releaseContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    var activePauseCount: Int { releaseContinuations.count }

    func pause() async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    releaseContinuations[token] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPause(token) }
        }
    }

    func waitUntilPaused(
        _ expectedCount: Int = 1,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while releaseContinuations.count < expectedCount, !Task.isCancelled {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return !Task.isCancelled
    }

    func release() {
        let continuations = Array(releaseContinuations.values)
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancelPause(_ token: UUID) {
        releaseContinuations.removeValue(forKey: token)?.resume()
    }
}

@MainActor
private func waitForV3Condition(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard !Task.isCancelled, clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

private struct CountingRow: AutoChartRow {
    let chartRowID: Int
    let category: String
    let value: Double
    let cellReads: V3Counter

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        cellReads.increment()
        return columnID == "category" ? .text(category) : .double(value)
    }
}

private struct CountingTable: AutoChartTable {
    let chartRows: [CountingRow]
    let chartDataKey: AutoChartDataKey
    let chartColumns = [
        AutoChartColumn(
            id: "category", name: "Category",
            semantics: .dimension(semanticType: .nominal)),
        AutoChartColumn(
            id: "value", name: "Value",
            semantics: .measure()),
    ]
    var chartMetadata: AutoChartTableMetadata { .init() }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AutoChartProgress] = []
    func append(_ value: AutoChartProgress) { lock.withLock { values.append(value) } }
    var phases: [AutoChartProgressPhase] { lock.withLock { values.map(\.phase) } }
}

@Suite struct V3ValueAndDatasetTests {
    @Test func columnHintsAlwaysFollowMutableSemantics() throws {
        var column = AutoChartColumn(id: "value", name: "Value")
        column.semantics = .measure(
            unit: .currency(code: "USD"),
            semantics: .init(source: .rowLevel, rollup: .additive))

        #expect(column.hints.role == .measure)
        #expect(column.hints.unit == .currency(code: "USD"))
        #expect(column.hints.measureSemantics?.rollup == .additive)
        #expect(try JSONDecoder().decode(
            AutoChartColumn.self,
            from: JSONEncoder().encode(column)) == column)
    }

    @Test func legacyAndPackageBridgeHintsRemainExactUntilSemanticsChange() throws {
        let legacyHints = AutoChartColumnHints(
            semanticType: .quantitative,
            role: .dimension,
            unit: .currency(code: "USD"),
            measureSemantics: .init(rollup: .additive),
            grain: "account")
        var bridged = AutoChartColumn(
            id: "legacy-value", name: "Legacy Value", hints: legacyHints)
        #expect(bridged.hints == legacyHints)

        let encodedLegacy = try JSONEncoder().encode(
            LegacyV3Column(
                id: bridged.id,
                name: bridged.name,
                displayName: bridged.displayName,
                hints: legacyHints))
        let decoded = try JSONDecoder().decode(
            AutoChartColumn.self, from: encodedLegacy)
        #expect(decoded.hints == legacyHints)

        let roundTripped = try JSONDecoder().decode(
            AutoChartColumn.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped.hints == legacyHints)
        #expect(roundTripped == decoded)

        let canonical = AutoChartColumn(
            id: bridged.id,
            name: bridged.name,
            displayName: bridged.displayName,
            semantics: bridged.semantics)
        #expect(bridged != canonical)
        #expect(Set([bridged, canonical]).count == 2)

        let bridgedDataset = try AutoChartDataset(
            columns: [bridged],
            rows: [[.double(1)]],
            rowIDs: [1],
            key: .contentAddressed(identity: "effective-hints"))
        let canonicalDataset = try AutoChartDataset(
            columns: [canonical],
            rows: [[.double(1)]],
            rowIDs: [1],
            key: .contentAddressed(identity: "effective-hints"))
        #expect(
            try AutoChartRequest(table: bridgedDataset).id
                != AutoChartRequest(table: canonicalDataset).id)

        let unchanged = bridged
        let sameSemantics = bridged.semantics
        bridged.semantics = sameSemantics
        #expect(bridged == unchanged)

        bridged.semantics = .identifier(semanticType: .nominal)
        #expect(bridged.hints.role == .identifier)
        #expect(bridged.hints.semanticType == .nominal)
        #expect(bridged.hints.measureSemantics == nil)
    }

    @Test func datasetDecodesVersionTwoDataKeys() throws {
        let json = Data(
            #"{"columns":[],"rows":[],"rowIDs":[],"metadata":{"isTruncated":false},"key":{"identity":"legacy","revision":"7"}}"#.utf8)
        let dataset = try JSONDecoder().decode(AutoChartDataset<Int>.self, from: json)
        #expect(dataset.chartDataKey == .trusted(identity: "legacy", revision: "7"))
    }

    @Test func everyStandardValueConversionPreservesItsType() {
        #expect(Optional<Int>.none.autoChartValue == .null)
        #expect(Optional(3).autoChartValue == .integer(3))
        #expect(true.autoChartValue == .boolean(true))
        #expect(Int(-1).autoChartValue == .integer(-1))
        #expect(Int8(-2).autoChartValue == .integer(-2))
        #expect(Int16(-3).autoChartValue == .integer(-3))
        #expect(Int32(-4).autoChartValue == .integer(-4))
        #expect(Int64(-5).autoChartValue == .integer(-5))
        #expect(UInt(6).autoChartValue == .integer(6))
        #expect(UInt8(7).autoChartValue == .integer(7))
        #expect(UInt16(8).autoChartValue == .integer(8))
        #expect(UInt32(9).autoChartValue == .integer(9))
        #expect(UInt64.max.autoChartValue == .decimal(Decimal(string: String(UInt64.max))!))
        #expect(Float(1.25).autoChartValue == .double(1.25))
        #expect(Double(2.5).autoChartValue == .double(2.5))
        #expect(Decimal(3).autoChartValue == .decimal(3))
        #expect("text".autoChartValue == .text("text"))
        #expect("substring".dropFirst(3).autoChartValue == .text("string"))
        let date = Date(timeIntervalSince1970: 123)
        #expect(date.autoChartValue == .date(date))
        let data = Data([1, 2, 3])
        #expect(data.autoChartValue == .binary(data))
    }

    @Test func domainBuilderDeclaresIdentifiersMeasuresDimensionsAndPairedIntervals()
        throws
    {
        let dataset = try domainDataset()
        #expect(dataset.chartRows.map(\.chartRowID) == [10, 20, 30])
        #expect(dataset.chartColumns.map(\.id) == [
            "id", "category", "series", "value", "second", "start", "end",
        ])
        #expect(dataset.chartColumns[0].hints.role == .identifier)
        #expect(dataset.chartColumns[2].hints.role == .series)
        #expect(dataset.chartColumns[3].hints.role == .measure)
        #expect(dataset.chartColumns[5].hints.role == .intervalStart)
        #expect(dataset.chartColumns[6].hints.role == .intervalEnd)
        #expect(dataset.chartRows[1].chartValue(for: "value") == .double(20))
    }

    @Test func columnCodingWritesCurrentSemanticsAndReleasedHintsShape() throws {
        let column = AutoChartColumn(
            id: "value", name: "Value",
            semantics: .measure(
                unit: .percent(fractional: true),
                semantics: .init(rollup: .nonAdditive)))
        let data = try JSONEncoder().encode(column)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["semantics"] != nil)
        #expect(object["normalizedHints"] == nil)
        #expect(object["hints"] != nil)
        #expect(try JSONDecoder().decode(AutoChartColumn.self, from: data) == column)

        let released = try JSONDecoder().decode(ReleasedV1Column.self, from: data)
        #expect(released.id == column.id)
        #expect(released.name == column.name)
        #expect(released.displayName == column.displayName)
        #expect(released.hints.semanticType == .quantitative)
        #expect(released.hints.role == .measure)
        #expect(released.hints.unit == .percent(fractional: true))
        #expect(released.hints.aggregation == nil)
        #expect(released.hints.aggregationSafety == .unsafe)
        #expect(released.hints.grain == nil)
    }

    @Test func semanticOrderingAndProvenanceRoundTripThroughCurrentCoding() throws {
        let column = AutoChartColumn(
            id: "rating",
            name: "credit_rating",
            categoryOrder: ["AAA", "AA", "A"].map(AutoChartValue.text),
            provenance: .init(
                sourceColumns: [.init(entity: "tenant", name: "credit_rating")],
                sourceGrain: .init(entity: "tenant")),
            semantics: .dimension(semanticType: .ordinal))
        let metadata = AutoChartTableMetadata(
            rowGrain: .init(entity: "tenant"),
            semanticModel: .init(
                relationships: [.init(one: "property", many: "lease")]))

        #expect(
            try JSONDecoder().decode(
                AutoChartColumn.self,
                from: JSONEncoder().encode(column)) == column)
        #expect(
            try JSONDecoder().decode(
                AutoChartTableMetadata.self,
                from: JSONEncoder().encode(metadata)) == metadata)
    }

    @Test func currentMeasureSemanticsEncodeConservativeReleasedRollupContracts() throws {
        let cases: [(
            String,
            AutoChartMeasureSemantics,
            AutoChartAggregation?,
            ReleasedV1AggregationSafety
        )] = [
            (
                "unknown upstream mean",
                .init(
                    source: .aggregated(.mean),
                    rollup: .unknown,
                    preferredTransform: .maximum),
                .mean,
                .alreadyAggregated
            ),
            (
                "nonadditive upstream distinct count",
                .init(
                    source: .aggregated(.countDistinct),
                    rollup: .nonAdditive,
                    preferredTransform: .maximum),
                .countDistinct,
                .unsafe
            ),
            (
                "named safe operation outranks preference",
                .init(
                    source: .rowLevel,
                    rollup: .safe(.sum),
                    preferredTransform: .mean),
                .sum,
                .safe
            ),
            (
                "unsafe upstream summary still blocks a named sum",
                .init(
                    source: .aggregated(.mean),
                    rollup: .safe(.sum),
                    preferredTransform: .sum),
                .mean,
                .unsafe
            ),
            (
                "additive upstream count permits a named sum",
                .init(
                    source: .aggregated(.count),
                    rollup: .safe(.sum),
                    preferredTransform: .sum),
                .count,
                .alreadyAggregated
            ),
            (
                "row-level additive defaults to sum",
                .init(
                    source: .rowLevel,
                    rollup: .additive,
                    preferredTransform: .mean),
                nil,
                .safe
            ),
            (
                "derived additive defaults to sum",
                .init(
                    source: .derived,
                    rollup: .additive,
                    preferredTransform: .maximum),
                nil,
                .safe
            ),
            (
                "upstream additive count remains provenance",
                .init(
                    source: .aggregated(.count),
                    rollup: .additive,
                    preferredTransform: .mean),
                .count,
                .alreadyAggregated
            ),
        ]

        for (name, semantics, aggregation, safety) in cases {
            let column = AutoChartColumn(
                id: "value", name: name,
                semantics: .measure(semantics: semantics))
            let released = try JSONDecoder().decode(
                ReleasedV1Column.self,
                from: JSONEncoder().encode(column))
            #expect(released.hints.aggregation == aggregation, Comment(rawValue: name))
            #expect(released.hints.aggregationSafety == safety, Comment(rawValue: name))
        }
    }

    @Test func releasedMeasureHintsDecodeIntoCurrentSafetyAndProvenance() throws {
        let cases: [(
            String,
            ReleasedV1ColumnHints,
            AutoChartMeasureSemantics
        )] = [
            (
                "unknown preferred mean",
                releasedV1MeasureHints(aggregation: .mean, safety: .unknown),
                .init(
                    source: .rowLevel,
                    rollup: .unknown,
                    preferredTransform: .mean)
            ),
            (
                "explicit row-level preference",
                releasedV1MeasureHints(aggregation: .mean, safety: .rowLevel),
                .init(
                    source: .rowLevel,
                    rollup: .unknown,
                    preferredTransform: .mean)
            ),
            (
                "implicit safe sum",
                releasedV1MeasureHints(aggregation: nil, safety: .safe),
                .init(source: .rowLevel, rollup: .safe(.sum))
            ),
            (
                "named safe mean",
                releasedV1MeasureHints(aggregation: .mean, safety: .safe),
                .init(
                    source: .rowLevel,
                    rollup: .safe(.mean),
                    preferredTransform: .mean)
            ),
            (
                "additive upstream sum",
                releasedV1MeasureHints(aggregation: .sum, safety: .alreadyAggregated),
                .init(source: .aggregated(.sum), rollup: .additive)
            ),
            (
                "nonadditive upstream mean",
                releasedV1MeasureHints(
                    aggregation: .mean, safety: .alreadyAggregated),
                .init(source: .aggregated(.mean), rollup: .unknown)
            ),
            (
                "unsafe upstream distinct count",
                releasedV1MeasureHints(aggregation: .countDistinct, safety: .unsafe),
                .init(
                    source: .aggregated(.countDistinct),
                    rollup: .nonAdditive,
                    preferredTransform: .countDistinct)
            ),
        ]

        for (name, hints, expected) in cases {
            let released = ReleasedV1Column(
                id: "value", name: name, displayName: nil, hints: hints)
            let decoded = try JSONDecoder().decode(
                AutoChartColumn.self,
                from: JSONEncoder().encode(released))
            #expect(decoded.hints.measureSemantics == expected, Comment(rawValue: name))
            #expect(decoded.semantics.hints.measureSemantics == expected, Comment(rawValue: name))
        }
    }

    @Test func releasedUnknownAggregationDoesNotInventUpstreamProvenance() throws {
        let current = AutoChartColumn(
            id: "value",
            name: "Value",
            semantics: .measure(
                semantics: .init(
                    source: .rowLevel,
                    rollup: .unknown,
                    preferredTransform: .mean)))

        let released = try JSONDecoder().decode(
            ReleasedV1Column.self,
            from: JSONEncoder().encode(current))
        #expect(released.hints.aggregation == .mean)
        #expect(released.hints.aggregationSafety == .unknown)

        let roundTripped = try JSONDecoder().decode(
            AutoChartColumn.self,
            from: JSONEncoder().encode(released))
        #expect(roundTripped == current)
    }

    @Test func releasedNonadditiveProvenanceSurvivesACompatibilityHop() throws {
        let released = ReleasedV1Column(
            id: "value",
            name: "Value",
            displayName: nil,
            hints: releasedV1MeasureHints(
                aggregation: .mean,
                safety: .alreadyAggregated))

        let current = try JSONDecoder().decode(
            AutoChartColumn.self,
            from: JSONEncoder().encode(released))
        let reencoded = try JSONDecoder().decode(
            ReleasedV1Column.self,
            from: JSONEncoder().encode(current))
        #expect(reencoded.hints.aggregation == .mean)
        #expect(reencoded.hints.aggregationSafety == .alreadyAggregated)
    }

    @Test func absentMeasureSemanticsRemainAbsentAcrossCoding() throws {
        let hints = AutoChartColumnHints(
            semanticType: .quantitative,
            role: .measure)
        let decoded = try JSONDecoder().decode(
            AutoChartColumnHints.self,
            from: JSONEncoder().encode(hints))
        #expect(decoded == hints)
        #expect(decoded.measureSemantics == nil)
    }

    @Test func releasedDefaultMeasureColumnMatchesCurrentDeclaration() throws {
        let released = ReleasedV1Column(
            id: "value",
            name: "Value",
            displayName: nil,
            hints: releasedV1MeasureHints(
                aggregation: nil,
                safety: .unknown))
        let decoded = try JSONDecoder().decode(
            AutoChartColumn.self,
            from: JSONEncoder().encode(released))
        let current = AutoChartColumn(
            id: "value",
            name: "Value",
            semantics: .measure())

        #expect(decoded == current)
        #expect(decoded.hints == current.hints)

        let decodedDataset = try AutoChartDataset(
            columns: [decoded],
            rows: [[.double(1)]],
            rowIDs: [1],
            key: .contentAddressed(identity: "default-measure"))
        let currentDataset = try AutoChartDataset(
            columns: [current],
            rows: [[.double(1)]],
            rowIDs: [1],
            key: .contentAddressed(identity: "default-measure"))
        #expect(
            try AutoChartRequest(table: decodedDataset).id
                == AutoChartRequest(table: currentDataset).id)
    }

    @Test func releasedHopKeepsUnknownAdditiveSourcesConservative() throws {
        for aggregation in [AutoChartAggregation.sum, .count] {
            let current = AutoChartColumn(
                id: "value",
                name: "Value",
                semantics: .measure(
                    semantics: .init(
                        source: .aggregated(aggregation),
                        rollup: .unknown)))
            let released = try JSONDecoder().decode(
                ReleasedV1Column.self,
                from: JSONEncoder().encode(current))
            #expect(released.hints.aggregation == aggregation)
            #expect(released.hints.aggregationSafety == .unknown)

            let roundTripped = try JSONDecoder().decode(
                AutoChartColumn.self,
                from: JSONEncoder().encode(released))
            #expect(
                roundTripped.hints.measureSemantics
                    == AutoChartMeasureSemantics(
                        source: .rowLevel,
                        rollup: .unknown,
                        preferredTransform: aggregation))
            #expect(roundTripped != current)
        }
    }
}

@Suite struct V3IdentityCatalogAndConstraintTests {
    @Test func requestIdentitySeparatesContentContextConstraintsAndPolicy() async throws {
        let trusted = try domainDataset(key: .trusted(identity: "result", revision: "1"))
        let trustedAgain = try domainDataset(key: .trusted(identity: "result", revision: "1"))
        let revised = try domainDataset(key: .trusted(identity: "result", revision: "2"))
        let content = try domainDataset(key: .contentAddressed(identity: "result"))
        var changedRecords = v3Records()
        changedRecords[0] = V3Record(
            id: 10, category: "North", series: "Actual", value: 999,
            secondValue: 4, start: changedRecords[0].start, end: changedRecords[0].end)
        let changed = try domainDataset(records: changedRecords)

        let base = try AutoChartRequest(table: trusted)
        let unchangedContent = try AutoChartRequest(table: domainDataset())
        #expect(try AutoChartRequest(table: trustedAgain).id == base.id)
        #expect(try AutoChartRequest(table: revised).id != base.id)
        #expect(try AutoChartRequest(table: content).id != base.id)
        #expect(try AutoChartRequest(table: changed).id != unchangedContent.id)
        #expect(
            try AutoChartRequest(table: trusted, context: .init(goal: .trend)).id != base.id)
        #expect(
            try AutoChartRequest(
                table: trusted,
                constraints: .init(excludedFamilies: [.bar])).id != base.id)
        #expect(
            try AutoChartRequest(
                table: trusted,
                policyVersion: AutoTableCharts.recommendationPolicyVersion + 1).id != base.id)

        #if DEBUG
        let structurallyChanged = try domainDataset(
            records: Array(v3Records().dropLast()),
            key: .trusted(identity: "result", revision: "1"))
        let changedStructureRequest = try AutoChartRequest(table: structurallyChanged)
        #expect(changedStructureRequest.id != base.id)
        let cache = AutoChartCache()
        let analyzer = AutoChartAnalyzer(cache: cache)
        let originalAnalysis = try await analyzer.analyze(base, preparation: .none)
        let changedAnalysis = try await analyzer.analyze(
            changedStructureRequest, preparation: .none)
        #expect(originalAnalysis.columnProfiles[0].nonNullCount == 3)
        #expect(changedAnalysis.columnProfiles[0].nonNullCount == 2)
        #endif
    }

    @Test func trustedWarmLookupDoesNotReadCellsAgain() async throws {
        let reads = V3Counter()
        let table = CountingTable(
            chartRows: [
                CountingRow(chartRowID: 1, category: "A", value: 10, cellReads: reads),
                CountingRow(chartRowID: 2, category: "B", value: 20, cellReads: reads),
            ],
            chartDataKey: .trusted(identity: "counted", revision: "1"))
        let request = try AutoChartRequest(table: table)
        #expect(reads.value == 0)
        let cache = AutoChartCache()
        let analyzer = AutoChartAnalyzer(cache: cache)
        _ = try await analyzer.analyze(request, preparation: .none)
        let afterColdLoad = reads.value
        #expect(afterColdLoad == 4)
        let second = try AutoChartRequest(table: table)
        _ = try await analyzer.analyze(second, preparation: .none)
        #expect(reads.value == afterColdLoad)
    }

    @Test func catalogBoundsFeaturedEntriesAndRetainsAnOffListPreference() {
        let all = (0..<60).map { index in
            recommendation(
                .bar(
                    category: AutoChartColumnID(rawValue: "category-\(index)"),
                    measure: "value"),
                score: Double(60 - index))
        }
        let catalog = AutoChartRecommendationCatalog(
            featured: Array(all.prefix(9)),
            cataloged: Array(all.prefix(55)),
            preferred: all[59])
        #expect(catalog.featured.count == 5)
        #expect(catalog.cataloged.count == 50)
        #expect(catalog.preferred?.id == all[59].id)
        #expect(catalog.recommendation(for: all[59].id)?.id == all[59].id)
        let options = catalog.pickerOptions(
            resolver: AutoChartTextResolver { message in
                "localized:\(message.defaultText)"
            })
        #expect(options.count == 51)
        #expect(options.last?.id == all[59].id)
        #expect(options.allSatisfy { $0.label.hasPrefix("localized:") })
    }

    @Test func catalogDeduplicatesConstructionAndDecodedPayloads() throws {
        let first = recommendation(.bar(category: "category", measure: "value"), score: 10)
        let duplicate = recommendation(.bar(category: "category", measure: "value"), score: 1)
        let other = recommendation(.bar(category: "other", measure: "value"), score: 5)
        let catalog = AutoChartRecommendationCatalog(
            featured: [first, duplicate, other],
            cataloged: [first, duplicate, other])
        #expect(catalog.cataloged.map(\.id) == [first.id, other.id])
        #expect(catalog.featured.map(\.id) == [first.id, other.id])
        #expect(catalog.recommendation(for: first.id)?.score == 10)
        #expect(catalog.pickerOptions().map(\.id) == [first.id, other.id])

        let payload = V3CatalogPayload(
            featured: [first, duplicate, other],
            cataloged: [first, duplicate, other],
            preferred: nil)
        let decoded = try JSONDecoder().decode(
            AutoChartRecommendationCatalog.self,
            from: JSONEncoder().encode(payload))
        #expect(decoded.cataloged.map(\.id) == [first.id, other.id])
        #expect(decoded.featured.map(\.id) == [first.id, other.id])
    }

    @Test func analyzerCatalogIsScoreOrderedWhileFeaturedRemainsBounded() async throws {
        let request = try AutoChartRequest(
            table: wideDomainDataset(),
            options: .init(maximumRecommendations: 5))
        let analysis = try await AutoChartAnalyzer().analyze(request)
        guard case .charts(let catalog) = analysis.outcome else {
            Issue.record("Expected chart recommendations.")
            return
        }

        #expect(catalog.featured.count == 5)
        #expect(Set(catalog.featured.map(\.specification.family)).count > 1)
        #expect(catalog.cataloged.count <= 50)
        #expect(catalog.featured.allSatisfy { featured in
            catalog.cataloged.contains { $0.id == featured.id }
        })
        #expect(
            zip(catalog.cataloged, catalog.cataloged.dropFirst())
                .allSatisfy { $0.score >= $1.score })
    }

    @Test func facetedExpansionIsBoundedPerBaseFamily() throws {
        let dataset = try wideDomainDataset()
        let maximumColumns = 8
        let result = AutoChartRecommendationEngine.recommendations(
            for: dataset,
            options: .init(
                maximumRecommendations: 5,
                maximumCandidateColumns: maximumColumns))
        let eligibleFacets = result.candidates.filter {
            $0.specification.family == .faceted
        }

        #expect(eligibleFacets.count <= maximumColumns * 3 * maximumColumns)
        let facetedBarXColumns = Set(
            eligibleFacets.compactMap { recommendation in
                recommendation.specification.facetBaseFamily == .bar
                    ? recommendation.specification.encoding.x : nil
            })
        #expect(facetedBarXColumns.count == maximumColumns)
    }

    @Test func facetedShortlistHonorsEventualRequestConstraints() throws {
        let dataset = try wideDomainDataset()
        let constraints = AutoChartRecommendationConstraints(
            includedFamilies: [.faceted],
            requiredColumns: ["dimension-6", "dimension-7", "measure-7"])
        let result = AutoChartRecommendationEngine.recommendations(
            for: dataset,
            options: .init(maximumCandidateColumns: 8),
            constraints: constraints)

        #expect(!result.chartRecommendations.isEmpty)
        #expect(result.chartRecommendations.allSatisfy {
            constraints.allows($0.specification)
        })
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func facetedShortlistingStopsAfterFillingTheValidLimit() {
        #if ATC_TEST_HOOKS
        let candidates = (0..<8).map { index in
            recommendation(
                .bar(
                    category: AutoChartColumnID(rawValue: "category-\(index)"),
                    measure: "value"),
                score: Double(8 - index))
        }
        let validationCount = V3Counter()
        let selected = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            candidates,
            limit: 3,
            isValid: { recommendation in
                validationCount.increment()
                return recommendation.score <= 6
            })

        #expect(validationCount.value == 5)
        #expect(selected.map { $0.score } == [6, 5, 4])
        #expect(selected.compactMap { $0.specification.encoding.x?.rawValue } == [
            "category-2", "category-3", "category-4",
        ])

        let pool = (0..<512).map { index in
            recommendation(
                .bar(category: AutoChartColumnID(rawValue: "x-\(index)"), measure: "y"),
                score: Double(512 - index))
        }
        for validCount in [0, 2] {
            var comparisons = 0
            var validations = 0
            let sparse = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
                pool, limit: 8,
                isValid: { candidate in
                    validations += 1
                    return candidate.score <= Double(validCount)
                },
                onComparison: { comparisons += 1 })
            #expect(sparse.count == validCount)
            #expect(validations == pool.count)
            // A repeated full scan needs >130,000 comparisons for this pool.
            #expect(comparisons < 30 * pool.count)
        }
        let diversified = [
            recommendation(.bar(category: "x0", measure: "y0"), score: 10),
            recommendation(.bar(category: "x0", measure: "y1"), score: 9),
            recommendation(.bar(category: "x1", measure: "y0"), score: 8),
            recommendation(.bar(category: "x1", measure: "y1"), score: 7),
        ]
        let balanced = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            diversified, limit: 4, isValid: { _ in true })
        #expect(balanced.map(\.score) == [10, 7, 9, 8])

        var fullValidations = 0
        let full = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            pool, limit: 3,
            isValid: { _ in fullValidations += 1; return true })
        #expect(fullValidations == 3)
        #expect(full.map(\.score) == [512, 511, 510])

        // Equal scores must use lexical IDs, then preserve input order for exact ties.
        let ties = candidates.reversed().map { original in
            var copy = original
            copy.score = 1
            return copy
        }
        let ordered = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            ties, limit: ties.count, isValid: { _ in true })
        #expect(ordered.map(\.id) == ties.map(\.id).sorted())
        var firstTie = candidates[0]
        firstTie.score = 1
        var secondTie = firstTie
        secondTie.score = 1
        firstTie.rationale = [.init(category: .rationale, code: .recommendationRationale,
                                   defaultText: "first")]
        secondTie.rationale = [.init(category: .rationale, code: .recommendationRationale,
                                    defaultText: "second")]
        let exactTies = AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            [firstTie, secondTie], limit: 2, isValid: { _ in true })
        #expect(exactTies.map { $0.rationale.first?.defaultText } == ["first", "second"])
        #expect(AutoChartRecommendationEngine.balancedFacetBasesForTesting(
            pool, limit: 0, isValid: { _ in Issue.record("Unexpected validation"); return true }
        ).isEmpty)
        #endif
    }

    @Test func catalogDecodingReappliesAllCollectionInvariants() throws {
        let all = (0..<60).map { index in
            recommendation(
                .bar(
                    category: AutoChartColumnID(rawValue: "category-\(index)"),
                    measure: "value"),
                score: Double(60 - index))
        }
        let invalid = V3CatalogPayload(
            featured: [all[55]] + Array(all.prefix(7)),
            cataloged: Array(all.prefix(55)),
            preferred: all[0])
        let decoded = try JSONDecoder().decode(
            AutoChartRecommendationCatalog.self,
            from: JSONEncoder().encode(invalid))

        #expect(decoded.cataloged.count == 50)
        #expect(decoded.featured.count == 5)
        #expect(decoded.featured.allSatisfy { featured in
            decoded.cataloged.contains { $0.id == featured.id }
        })
        #expect(decoded.preferred == nil)

        let offList = V3CatalogPayload(
            featured: [],
            cataloged: Array(all.prefix(55)),
            preferred: all[59])
        let decodedOffList = try JSONDecoder().decode(
            AutoChartRecommendationCatalog.self,
            from: JSONEncoder().encode(offList))
        #expect(decodedOffList.preferred?.id == all[59].id)
    }

    @Test func constraintsFilterFamiliesAndColumnsBeforeCataloging() async throws {
        let dataset = try domainDataset()
        let constraints = AutoChartRecommendationConstraints(
            includedFamilies: [.bar, .rankedDot],
            requiredColumns: ["category", "value"],
            excludedColumns: ["second"])
        let request = try AutoChartRequest(table: dataset, constraints: constraints)
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .none)
        let catalog = try #require(analysis.outcome.catalog)
        #expect(!catalog.cataloged.isEmpty)
        #expect(catalog.cataloged.allSatisfy { constraints.allows($0.specification) })
    }

    @Test func constraintsFilterAggregationsAndParticipateInRequestIdentity() async throws {
        let dataset = try domainDataset()
        let unconstrained = try AutoChartRequest(table: dataset)
        let constraints = AutoChartRecommendationConstraints(
            includedAggregations: [.none])
        let request = try AutoChartRequest(table: dataset, constraints: constraints)
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .none)
        let catalog = try #require(analysis.outcome.catalog)

        #expect(request.id != unconstrained.id)
        #expect(!catalog.cataloged.isEmpty)
        #expect(catalog.cataloged.allSatisfy {
            $0.specification.aggregation == .none
                && constraints.allows($0.specification)
        })

        let roundTripped = try JSONDecoder().decode(
            AutoChartRecommendationConstraints.self,
            from: JSONEncoder().encode(constraints))
        #expect(roundTripped == constraints)
    }

    @Test func decisionTraceKeepsCatalogedRecommendationsClassifiedAsRecommended()
        async throws
    {
        let request = try AutoChartRequest(
            table: domainDataset(),
            options: .init(maximumRecommendations: 1, includesDecisionTrace: true))
        let analysis = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let catalog = try #require(analysis.outcome.catalog)
        let trace = try #require(analysis.decisionTrace)
        #expect(catalog.featured.count == 1)
        #expect(catalog.cataloged.count > catalog.featured.count)

        let decisions = Dictionary(
            uniqueKeysWithValues: trace.candidates.map { ($0.specificationID, $0.disposition) })
        for (rank, recommendation) in catalog.cataloged.enumerated() {
            guard let disposition = decisions[recommendation.specification.id],
                case .recommended(let tracedRank, _) = disposition
            else {
                Issue.record("A retained catalog recommendation was not classified as recommended.")
                continue
            }
            #expect(tracedRank == rank)
        }
    }

    @Test func analysisRetainsAValidOffListPreferenceWithTargetedValidation()
        async throws
    {
        let dataset = try wideDomainDataset()
        let request = try AutoChartRequest(table: dataset)
        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(request, preparation: .none)
        let catalog = try #require(analysis.outcome.catalog)
        #expect(catalog.cataloged.count == AutoChartRecommendationCatalog.maximumCatalogedCount)

        var catalogOptions = request.options
        catalogOptions.maximumRecommendations =
            AutoChartRecommendationCatalog.maximumCatalogedCount
        let candidates = AutoChartRecommendationEngine.recommendations(
            for: dataset,
            context: request.context,
            options: catalogOptions,
            constraints: request.constraints).candidates
        let catalogIDs = Set(catalog.cataloged.map(\.id))
        let offList = try #require(candidates.first { recommendation in
            !catalogIDs.contains(recommendation.id)
                && AutoChartRecommendationEngine.validate(
                    specification: recommendation.specification,
                    for: dataset).isValid
        })

        let resolution = analysis.resolve(.chart(.specific(offList.id)))
        #expect(resolution.recommendation?.id == offList.id)
        #expect(resolution.defaultReason == nil)
        #expect(resolution.replacementPreference == nil)
        let stale = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
            specificationID: offList.specification.id)
        let rebound = analysis.resolve(.chart(.specific(stale)))
        #expect(rebound.recommendation?.id == offList.id)
        #expect(rebound.replacementPreference == .chart(.specific(offList.id)))

        let prepared = try await analyzer.analyze(
            request,
            preference: .chart(.specific(offList.id)),
            preparation: .allCataloged)
        #expect(prepared.primaryChart?.recommendation.id == offList.id)
        #expect(prepared.outcome.catalog?.preferred?.id == offList.id)
        #expect(prepared.outcome.catalog?.pickerOptions().contains {
            $0.id == offList.id
        } == true)
        #expect(prepared.preparedCharts.count == catalog.cataloged.count + 1)

        let repeated = prepared.replacingPresentation(
            preparedCharts: prepared.preparedCharts,
            resolution: prepared.preferenceResolution)
        #expect(repeated.outcome.catalog?.preferred?.id == offList.id)
        #expect(repeated.outcome.catalog?.pickerOptions().contains {
            $0.id == offList.id
        } == true)

        let automatic = prepared.replacingPresentation(
            preparedCharts: prepared.preparedCharts,
            resolution: prepared.resolve(.automatic))
        #expect(automatic.outcome.catalog?.preferred == nil)

        let rankedFallback = prepared.replacingPresentation(
            preparedCharts: prepared.preparedCharts,
            resolution: nil)
        #expect(rankedFallback.primaryChart?.recommendation.id == catalog.primary?.id)
    }
}

@Suite struct V3PreparationCacheAndFailureTests {
    @Test func everyPreparationStrategyHonorsPreferenceWithoutPreparingAnUnwantedPrimary()
        async throws
    {
        let dataset = try domainDataset()
        let request = try AutoChartRequest(table: dataset)
        let cache = AutoChartCache()
        let analyzer = AutoChartAnalyzer(cache: cache)

        let unprepared = try await analyzer.analyze(request, preparation: .none)
        #expect(unprepared.primaryChart == nil)
        let catalog = try #require(unprepared.outcome.catalog)
        let alternative = try #require(catalog.cataloged.dropFirst().first)

        let table = try await analyzer.analyze(
            request, preference: .table, preparation: .allCataloged)
        #expect(table.primaryChart == nil)
        #expect(table.preferenceResolution?.usesTable == true)

        let preferred = try await analyzer.analyze(
            request,
            preference: .chart(.specific(alternative.id)),
            preparation: .preferredOrPrimary)
        #expect(preferred.primaryChart?.recommendation.id == alternative.id)
        #expect(preferred.preparedCharts.count == 1)

        let primary = try await analyzer.analyze(
            request, preference: .automatic, preparation: .primary)
        #expect(primary.primaryChart?.recommendation.id == catalog.primary?.id)

        let all = try await analyzer.analyze(
            request, preference: .automatic, preparation: .allCataloged)
        #expect(all.preparedCharts.count == catalog.cataloged.count)
    }

    @Test func staleAndUnavailablePreferencesProduceTypedReplacementSuggestions()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .none)
        let primary = try #require(analysis.outcome.catalog?.primary)
        let stale = AutoChartRecommendationID(
            policyVersion: 14,
            specificationID: primary.specification.id)
        let staleResolution = analysis.resolve(.chart(.specific(stale)))
        #expect(staleResolution.defaultReason == .policyVersionRebound(
            previous: 14,
            current: 15))
        #expect(staleResolution.recommendation?.id == primary.id)
        #expect(staleResolution.replacementPreference == .chart(.specific(primary.id)))

        let missing = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "missing"))
        let missingResolution = analysis.resolve(.chart(.specific(missing)))
        #expect(missingResolution.defaultReason == .specificationUnavailable)
        #expect(missingResolution.replacementPreference == .chart(.recommended))
        let staleMissing = AutoChartRecommendationID(
            policyVersion: 14,
            specificationID: missing.specificationID)
        let staleMissingResolution = analysis.resolve(.chart(.specific(staleMissing)))
        #expect(staleMissingResolution.recommendation?.id == primary.id)
        #expect(staleMissingResolution.defaultReason == .policyVersionChanged(
            previous: 14, current: 15))
        #expect(staleMissingResolution.replacementPreference == .chart(.recommended))
    }

    @Test func featuredAndCatalogLookupUseTheSameRecommendationRecord() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let original = try #require(analysis.outcome.catalog?.cataloged.first)
        var alteredFeatured = original
        alteredFeatured.score += 999
        let catalog = AutoChartRecommendationCatalog(
            featured: [alteredFeatured], cataloged: [original])
        #expect(catalog.primary == original)
        #expect(catalog.recommendation(for: original.id) == original)
        #expect(catalog.featured == [original])
    }

    @Test func noSafeChartProducesOneAutomaticReplacement() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [AutoChartColumn(id: "label", name: "Label",
                semantics: .dimension(semanticType: .nominal))],
            rows: [[.text("Only text")]],
            rowIDs: [0])
        let analysis = try await AutoChartAnalyzer().analyze(
            AutoChartRequest(table: dataset), preparation: .none)
        let choice = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "unavailable"))
        #expect(analysis.resolve(.chart(.specific(choice))).replacementPreference == .automatic)
    }

    @Test func sharedCacheSupportsSynchronousTypedLookupCostStatisticsAndTrim()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let cache = AutoChartCache()
        let analysis = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .primary)
        #expect(cache.completedAnalysis(for: request.id, as: Int.self)?.id == analysis.id)
        #expect(analysis.estimatedRetainedCost > 0)
        #expect(analysis.primaryChart?.estimatedRetainedCost ?? 0 > 0)
        let statistics = await cache.statistics()
        #expect(statistics.tables.entries >= 1)
        #expect(statistics.analyses.entries >= 1)
        #expect(statistics.preparedCharts.entries >= 1)
        #expect(statistics.retainedCost <= cache.configuration.maximumRetainedCost)
        await cache.trim(to: .minimum)
        #expect(cache.completedAnalysis(for: request.id, as: Int.self) == nil)
        let trimmed = await cache.statistics()
        #expect(trimmed.retainedCost == 0)
    }

    @Test func analysisCacheChargesItsCandidateIndex() async throws {
        let configuration = AutoChartAnalyzerConfiguration(
            tables: .init(maximumEntries: 0),
            analyses: .init(maximumEntries: 1),
            preparedCharts: .init(maximumEntries: 0))
        let analyzer = AutoChartAnalyzer(configuration: configuration)
        let analysis = try await analyzer.analyze(
            AutoChartRequest(table: domainDataset()), preparation: .none)
        #expect(analysis.outcome.catalog?.cataloged.isEmpty == false)
        let statistics = await analyzer.cacheStatistics
        #expect(statistics.analyses.entries == 1)
        #expect(statistics.analyses.retainedCost == analysis.estimatedRetainedCost)
    }

    @Test func completedAnalysisLookupRefreshesLeastRecentlyUsedOrder() async throws {
        let cache = AutoChartCache(
            configuration: .init(analyses: .init(maximumEntries: 2)))
        let analyzer = AutoChartAnalyzer(cache: cache)
        let firstRequest = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(identity: "completed-lru", revision: "1")))
        let secondRequest = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(identity: "completed-lru", revision: "2")))
        let thirdRequest = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(identity: "completed-lru", revision: "3")))

        _ = try await analyzer.analyze(firstRequest, preparation: .none)
        _ = try await analyzer.analyze(secondRequest, preparation: .none)
        #expect(cache.completedAnalysis(for: firstRequest.id, as: Int.self) != nil)
        _ = try await analyzer.analyze(thirdRequest, preparation: .none)

        #expect(cache.completedAnalysis(for: firstRequest.id, as: Int.self) != nil)
        #expect(cache.completedAnalysis(for: secondRequest.id, as: Int.self) == nil)
        #expect(cache.completedAnalysis(for: thirdRequest.id, as: Int.self) != nil)
    }

    @Test func coalescedFailuresShareAnEpisodeAndExplicitRetryStartsANewOne()
        async throws
    {
        let reads = V3Counter()
        let invalid = CountingTable(
            chartRows: [
                CountingRow(chartRowID: 1, category: "A", value: 1, cellReads: reads),
                CountingRow(chartRowID: 1, category: "B", value: 2, cellReads: reads),
            ],
            chartDataKey: .trusted(identity: "invalid", revision: "1"))
        let request = try AutoChartRequest(table: invalid)
        let cache = AutoChartCache()
        let analyzer = AutoChartAnalyzer(cache: cache)
        async let first = captureResult {
            try await analyzer.analyze(request, preparation: .none)
        }
        async let second = captureResult {
            try await analyzer.analyze(request, preparation: .none)
        }
        let results = await (first, second)
        let failures = [results.0, results.1].compactMap { result -> AutoChartFailure? in
            guard case .failure(let error) = result else { return nil }
            return error as? AutoChartFailure
        }
        #expect(failures.count == 2)
        #expect(failures[0].episodeID == failures[1].episodeID)
        #expect(failures[0].stage == .materialization)
        #expect(!failures[0].isRetryable)

        cache.beginRetry(for: request.id)
        let retried = await captureResult {
            try await analyzer.analyze(request, preparation: .none)
        }
        guard case .failure(let error) = retried,
            let retryFailure = error as? AutoChartFailure
        else {
            Issue.record("Expected the invalid dataset retry to fail.")
            return
        }
        #expect(retryFailure.episodeID != failures[0].episodeID)
    }

    @Test func sharedCacheBoundsFailureEpisodesAndKeepsProgressSubscribers() async {
        let cache = AutoChartCache(
            configuration: .init(analyses: .init(maximumEntries: 2)))
        let firstID = AutoChartRequestID(value: 1)
        let secondID = AutoChartRequestID(value: 2)
        let thirdID = AutoChartRequestID(value: 3)
        func failure() -> AutoChartFailure {
            AutoChartFailure(
                stage: .profiling,
                kind: .invalidData,
                isRetryable: false,
                diagnosticID: "ATC.test.failure",
                message: "Expected failure")
        }

        let first = cache.coalescedFailure(
            for: firstID, error: failure(), stage: .profiling)
        _ = cache.coalescedFailure(
            for: secondID, error: failure(), stage: .profiling)
        let third = cache.coalescedFailure(
            for: thirdID, error: failure(), stage: .profiling)
        let repeatedThird = cache.coalescedFailure(
            for: thirdID, error: failure(), stage: .profiling)
        #expect(repeatedThird.episodeID == third.episodeID)

        let recreatedFirst = cache.coalescedFailure(
            for: firstID, error: failure(), stage: .profiling)
        #expect(recreatedFirst.episodeID != first.episodeID)

        let progressCalls = V3Counter()
        let token = cache.registerProgress(for: firstID) { _ in
            progressCalls.increment()
        }
        await cache.trim(to: .minimum)
        cache.reportProgress(
            AutoChartProgress(phase: .profiling),
            for: firstID,
            fallback: nil)
        #expect(progressCalls.value == 1)
        cache.unregisterProgress(for: firstID, token: token)
    }

    @Test func cacheResetKeepsProgressSubscribersWithoutReplayingOldProgress() async {
        let cache = AutoChartCache()
        let requestID = AutoChartRequestID(value: 99)
        let existingCalls = V3Counter()
        let existingToken = cache.registerProgress(for: requestID) { _ in
            existingCalls.increment()
        }
        cache.reportProgress(
            AutoChartProgress(phase: .chartPreparation),
            for: requestID,
            fallback: nil)
        #expect(existingCalls.value == 1)

        await cache.removeAll()
        let newCalls = V3Counter()
        let newToken = cache.registerProgress(for: requestID) { _ in
            newCalls.increment()
        }
        #expect(newCalls.value == 0)

        cache.reportProgress(
            AutoChartProgress(phase: .materialization),
            for: requestID,
            fallback: nil)
        #expect(existingCalls.value == 2)
        #expect(newCalls.value == 1)
        cache.unregisterProgress(for: requestID, token: existingToken)
        cache.unregisterProgress(for: requestID, token: newToken)
    }

    @Test func progressReportsEveryAnalysisAndPreparationPhase() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let recorder = ProgressRecorder()
        _ = try await AutoChartAnalyzer().analyze(
            request,
            preparation: .primary,
            progress: { recorder.append($0) })
        #expect(recorder.phases.contains(.materialization))
        #expect(recorder.phases.contains(.profiling))
        #expect(recorder.phases.contains(.recommendation))
        #expect(recorder.phases.contains(.chartPreparation))
    }
}

@Suite struct V3SpecificationSelectionAndPresentationTests {
    @Test func everyAssociatedValueFamilyCaseProducesTheExpectedReadOnlyFamily() {
        let cases: [(AutoChartFamilySpecification, AutoChartFamily)] = [
            (.kpi(measure: "v", title: ""), .kpi),
            (.bar(category: "c", measure: "v", aggregation: .sum, orientation: .vertical, sort: .source, title: ""), .bar),
            (.rankedDot(category: "c", measure: "v", aggregation: .sum, sort: .descending, title: ""), .rankedDot),
            (.groupedBar(category: "c", measure: "v", series: "s", aggregation: .sum, orientation: .vertical, title: ""), .groupedBar),
            (.stackedBar(category: "c", measure: "v", series: "s", aggregation: .sum, orientation: .vertical, title: ""), .stackedBar),
            (.normalizedBar(category: "c", measure: "v", series: "s", aggregation: .sum, orientation: .vertical, title: ""), .normalizedBar),
            (.line(x: "x", measure: "v", series: nil, aggregation: .none, title: ""), .line),
            (.pointLine(x: "x", measure: "v", series: nil, aggregation: .none, title: ""), .pointLine),
            (.area(x: "x", measure: "v", series: nil, aggregation: .none, title: ""), .area),
            (.scatter(x: "x", y: "v", series: nil, title: ""), .scatter),
            (.bubble(x: "x", y: "v", size: "z", series: nil, title: ""), .bubble),
            (.histogram(value: "v", binCount: 8, title: ""), .histogram),
            (.boxPlot(measure: "v", category: "c", title: ""), .boxPlot),
            (.heatmap(x: "x", y: "y", title: ""), .heatmap),
            (.donut(category: "c", measure: "v", aggregation: .sum, title: ""), .donut),
            (.range(label: "c", start: "start", end: "end", series: nil, title: ""), .range),
            (.faceted(baseFamily: .bar, x: "c", y: "v", facet: "f", series: nil, aggregation: .sum, orientation: .vertical, title: ""), .faceted),
        ]
        #expect(cases.allSatisfy { AutoChartSpecification($0.0).family == $0.1 })
    }

    @Test func unsafeRawRepresentationMustPassAnalysisValidationBeforePreparation()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .none)
        let unsafe = AutoChartUnsafeRawSpecification(
            family: .donut,
            encoding: .init(x: "category", y: "value", size: "second"),
            aggregation: .sum)
        let validation = try await analysis.validation(for: unsafe)
        #expect(!validation.isValid)
        await #expect(throws: AutoChartPreparationError.self) {
            try await analysis.prepare(unsafe)
        }
    }

    @Test func selectionSetsEnforceProvenanceToggleMarksAndUnionSourceRows()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .primary)
        let chart = try #require(analysis.primaryChart)
        let first = try #require(chart.marks.first)
        let second = try #require(chart.marks.dropFirst().first)
        let firstSelection = AutoChartSelection(
            analysisID: analysis.id,
            preparedChartID: chart.id,
            sourceRowIDs: first.sourceRowIDs,
            family: chart.recommendation.specification.family,
            specificationID: chart.recommendation.specification.id,
            markID: first.identity)
        let secondSelection = AutoChartSelection(
            analysisID: analysis.id,
            preparedChartID: chart.id,
            sourceRowIDs: second.sourceRowIDs,
            family: chart.recommendation.specification.family,
            specificationID: chart.recommendation.specification.id,
            markID: second.identity)
        var set = AutoChartSelectionSet([firstSelection])
        #expect(set.belongs(to: analysis))
        #expect(set.belongs(to: chart))
        set.select(secondSelection, toggling: true)
        #expect(set.count == 2)
        #expect(set.unionedSourceRows == first.sourceRowIDs.union(second.sourceRowIDs))
        #expect(set.sourceRows(in: chart) == set.unionedSourceRows)
        set.select(firstSelection, toggling: true)
        #expect(!set.contains(markID: first.identity))

        let derived = chart.selections(for: second.sourceRowIDs, analysisID: analysis.id)
        #expect(derived.belongs(to: analysis))
        #expect(derived.belongs(to: chart))
        #expect(!derived.isEmpty)

        let stale = AutoChartSelection(
            sourceRowIDs: [999],
            family: chart.recommendation.specification.family,
            specificationID: chart.recommendation.specification.id,
            markID: "stale")
        let reconciled = AutoChartSelectionSet([firstSelection, stale, secondSelection])
        #expect(reconciled.count == 2)
        #expect(!reconciled.contains(markID: "stale"))

        let leadingStale = AutoChartSelectionSet([stale, firstSelection, secondSelection])
        #expect(leadingStale.count == 2)
        #expect(!leadingStale.contains(markID: "stale"))
        let duplicatedStale = AutoChartSelectionSet([
            stale, stale, firstSelection, secondSelection,
        ])
        #expect(duplicatedStale.count == 2)
        #expect(!duplicatedStale.contains(markID: "stale"))

        let secondStale = AutoChartSelection(
            analysisID: stale.analysisID,
            preparedChartID: stale.preparedChartID,
            sourceRowIDs: [998],
            family: stale.family,
            specificationID: stale.specificationID,
            markID: "second-stale")
        let interleavedTie = AutoChartSelectionSet([
            firstSelection, stale, secondStale, secondSelection,
        ])
        #expect(interleavedTie.count == 2)
        #expect(interleavedTie.analysisID == analysis.id)

        let aggregate = try await analysis.prepare(
            AutoChartSpecification(
                .bar(
                    category: "category",
                    measure: "value",
                    aggregation: .sum,
                    orientation: .vertical,
                    sort: .source,
                    title: "")))
        let partialAggregateSelection = aggregate.selections(
            for: [10], analysisID: analysis.id)
        let matchingAggregateMark = try #require(
            aggregate.marks.first { $0.sourceRowIDs.contains(10) })
        let matchingAggregateDatum = try #require(
            aggregate.core.data.first { $0.id == matchingAggregateMark.identity })
        let semanticValues = AutoChartSelectionPreparation.semanticValues(
            for: [matchingAggregateDatum],
            specification: aggregate.recommendation.specification,
            measureSemantics: aggregate.core.measureSemantics)
        let derivedAggregateSelection = try #require(partialAggregateSelection.first)
        #expect(
            partialAggregateSelection.unionedSourceRows
                == matchingAggregateMark.sourceRowIDs)
        #expect(derivedAggregateSelection.dimensions == semanticValues.dimensions)
        #expect(derivedAggregateSelection.rangeDimensions == semanticValues.rangeDimensions)
        #expect(derivedAggregateSelection.measure == semanticValues.measure)
        #expect(
            derivedAggregateSelection
                == AutoChartSelection(
                    analysisID: analysis.id,
                    preparedChartID: aggregate.id,
                    sourceRowIDs: matchingAggregateMark.sourceRowIDs,
                    dimensions: semanticValues.dimensions,
                    rangeDimensions: semanticValues.rangeDimensions,
                    measure: semanticValues.measure,
                    family: aggregate.recommendation.specification.family,
                    specificationID: aggregate.recommendation.specification.id,
                    markID: matchingAggregateMark.identity))

        var partialGroup = AutoChartSelectionSet([firstSelection])
        partialGroup.select(
            [firstSelection, secondSelection], togglingAsGroup: true)
        #expect(partialGroup.count == 2)
        partialGroup.select(
            [firstSelection, secondSelection], togglingAsGroup: true)
        #expect(partialGroup.isEmpty)
    }

    @Test func preferenceCodableRoundTrip() throws {
        let recommendationID = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "specific"))
        let preferences: [AutoChartPreference] = [
            .automatic, .table, .chart(.recommended), .chart(.specific(recommendationID)),
        ]
        for preference in preferences {
            #expect(
                try JSONDecoder().decode(
                    AutoChartPreference.self,
                    from: JSONEncoder().encode(preference)) == preference)
        }
    }

    @Test func presenterMemoizesLocalizedPresentationByChartAndContext() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .primary)
        let chart = try #require(analysis.primaryChart)
        let calls = V3Counter()
        let resolver = AutoChartTextResolver { message in
            calls.increment()
            return "L:\(message.defaultText)"
        }
        let formatters = AutoChartFormatters(request: { _, _, _ in
            calls.increment()
            return nil
        })
        let presenter = AutoChartPresenter()
        let context = AutoChartPresentationContext(identity: "localized")
        let first = presenter.present(
            chart, context: context, formatters: formatters, textResolver: resolver)
        let afterFirst = calls.value
        let second = presenter.present(
            chart, context: context, formatters: formatters, textResolver: resolver)
        #expect(first.id == second.id)
        #expect(first.title == second.title)
        #expect(calls.value == afterFirst)
        _ = presenter.present(
            chart,
            context: .init(identity: "localized-2"),
            formatters: formatters,
            textResolver: resolver)
        #expect(calls.value > afterFirst)

        let alternateResolver = AutoChartTextResolver { message in
            "alternate:\(message.defaultText)"
        }
        var untitledSpecification = chart.recommendation.specification
        untitledSpecification.title = ""
        let untitledChart = try await analysis.prepare(untitledSpecification)
        let alternate = presenter.present(
            untitledChart,
            context: context,
            formatters: formatters,
            textResolver: alternateResolver)
        #expect(alternate.title.hasPrefix("alternate:"))

        let reentrantCalls = V3Counter()
        let reentrantResolver = AutoChartTextResolver { message in
            if reentrantCalls.value == 0 {
                reentrantCalls.increment()
                _ = presenter.present(untitledChart, context: context)
            }
            return "reentrant:\(message.defaultText)"
        }
        let reentrant = presenter.present(
            untitledChart,
            context: .init(identity: "reentrant"),
            textResolver: reentrantResolver)
        #expect(reentrant.title.hasPrefix("reentrant:"))
        #expect(reentrantCalls.value == 1)
    }

    @Test func nonSourceFacetOrderIgnoresDeclaredRanksAndBarMagnitude() async throws {
        let category = AutoChartColumn(
            id: "category", name: "category",
            semantics: .dimension(semanticType: .nominal))
        let facet = AutoChartColumn(
            id: "facet", name: "facet",
            categoryOrder: [.text("Mid")],
            semantics: .dimension(semanticType: .nominal))
        let value = AutoChartColumn(
            id: "value", name: "value",
            semantics: .measure(
                semantics: .init(source: .rowLevel, rollup: .additive)))
        let dataset = try AutoChartDataset(
            columns: [category, facet, value],
            rows: [
                [.text("Only"), .text("Zulu"), .double(10)],
                [.text("Only"), .text("Alpha"), .double(30)],
                [.text("Only"), .text("Mid"), .double(20)],
            ],
            rowIDs: [0, 1, 2])
        let analysis = try await AutoChartAnalyzer().analyze(
            try AutoChartRequest(table: dataset))
        let chart = try await analysis.prepare(
            AutoChartSpecification(
                family: .faceted,
                encoding: .init(x: category.id, y: value.id, facet: facet.id),
                aggregation: .sum,
                facetBaseFamily: .bar,
                sort: .descending))
        let presented = AutoChartPresenter().present(chart)

        #expect(presented.facetPanels.map(\.displayValue) == ["Alpha", "Mid", "Zulu"])
    }

    @Test(.timeLimit(.minutes(1)))
    func capturedHostCallbackContextSurvivesOffActorPresentationWork() async {
        let token = AutoChartHostCallbackToken()
        let result = V3LockedBox<Bool>()
        let completed = DispatchSemaphore(value: 0)
        let inheritedContextWasActive: Bool = await withCheckedContinuation {
            continuation in
            DispatchQueue(label: "AutoTableChartsTests.callback-context").async {
                AutoChartHostCallbackActivity.invoke(
                    token,
                    {
                        let context = AutoChartHostCallbackActivity.currentContext
                        Task.detached {
                            result.store(
                                AutoChartHostCallbackActivity.withContext(context) {
                                    AutoChartHostCallbackActivity.hasActiveCallback
                                })
                            completed.signal()
                        }
                        completed.wait()
                    },
                    fallback: ())
                continuation.resume(returning: result.value ?? false)
            }
        }

        #expect(inheritedContextWasActive)
    }

    @Test func presenterEvictsLeastRecentlyUsedPresentationPayloads() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .primary)
        let chart = try #require(analysis.primaryChart)
        let calls = V3Counter()
        let formatters = AutoChartFormatters(request: { _, _, _ in
            calls.increment()
            return nil
        })
        let presenter = AutoChartPresenter(maximumEntries: 1)

        _ = presenter.present(
            chart, context: .init(identity: "first"), formatters: formatters)
        _ = presenter.present(
            chart, context: .init(identity: "second"), formatters: formatters)
        let afterSecond = calls.value
        _ = presenter.present(
            chart, context: .init(identity: "first"), formatters: formatters)

        #expect(calls.value > afterSecond)
    }

    @Test func explicitCallbackIdentitiesSharePresentationEntries() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request)
        let chart = try await analysis.prepare(
            .bar(category: "category", measure: "value", aggregation: .sum))
        let presenter = AutoChartPresenter()
        let firstFormatterCalls = V3Counter()
        let secondFormatterCalls = V3Counter()
        let firstResolverCalls = V3Counter()
        let secondResolverCalls = V3Counter()
        let firstFormatters = AutoChartFormatters(
            cacheIdentity: "domain-format-v1",
            request: { _, _, _ in
                firstFormatterCalls.increment()
                return nil
            })
        let secondFormatters = AutoChartFormatters(
            cacheIdentity: "domain-format-v1",
            request: { _, _, _ in
                secondFormatterCalls.increment()
                return nil
            })
        let firstResolver = AutoChartTextResolver(cacheIdentity: "domain-text-v1") {
            firstResolverCalls.increment()
            return "first:\($0.defaultText)"
        }
        let secondResolver = AutoChartTextResolver(cacheIdentity: "domain-text-v1") {
            secondResolverCalls.increment()
            return "second:\($0.defaultText)"
        }

        let first = presenter.present(
            chart, formatters: firstFormatters, textResolver: firstResolver)
        #expect(firstFormatterCalls.value > 0)
        #expect(firstResolverCalls.value > 0)
        let second = presenter.present(
            chart, formatters: secondFormatters, textResolver: secondResolver)
        #expect(second.requestID == first.requestID)
        #expect(secondFormatterCalls.value == 0)
        #expect(secondResolverCalls.value == 0)
        #expect(second.title == first.title)

        let changedFormatters = AutoChartFormatters(
            cacheIdentity: "domain-format-v2",
            request: { _, _, _ in
                secondFormatterCalls.increment()
                return nil
            })
        let changedResolver = AutoChartTextResolver(cacheIdentity: "domain-text-v2") {
            secondResolverCalls.increment()
            return "changed:\($0.defaultText)"
        }
        let changed = presenter.present(
            chart, formatters: changedFormatters, textResolver: changedResolver)
        #expect(changed.requestID != first.requestID)
        #expect(secondFormatterCalls.value > 0)
        #expect(secondResolverCalls.value > 0)

        let generatedFormattersA = AutoChartFormatters(request: { _, _, _ in nil })
        let generatedFormattersB = AutoChartFormatters(request: { _, _, _ in nil })
        let generatedResolverA = AutoChartTextResolver { _ in nil }
        let generatedResolverB = AutoChartTextResolver { _ in nil }
        #expect(generatedFormattersA.callbackIdentity != generatedFormattersB.callbackIdentity)
        #expect(generatedResolverA.callbackIdentity != generatedResolverB.callbackIdentity)

        let valueFormatterA = AutoChartFormatters(
            cacheIdentity: "value-format-v1", value: { _, _, _, _, _ in nil })
        let valueFormatterB = AutoChartFormatters(
            cacheIdentity: "value-format-v1", value: { _, _, _, _, _ in nil })
        #expect(valueFormatterA.callbackIdentity == valueFormatterB.callbackIdentity)

        let noValueOverride = AutoChartFormatters(value: nil)
        let optionalCacheIdentity: String? = "optional-value-format-v1"
        let compatibleOptionalIdentity = AutoChartFormatters(
            cacheIdentity: optionalCacheIdentity,
            value: { _, _, _, _, _ in nil })
        let generatedValueOverride = AutoChartFormatters(value: { _, _, _, _, _ in nil })
        #expect(noValueOverride.callbackIdentity == nil)
        #expect(compatibleOptionalIdentity.callbackIdentity != nil)
        #expect(generatedValueOverride.callbackIdentity != nil)

        let identityWithoutValue = AutoChartFormatters(cacheIdentity: "unused-value")
        let identityWithNilValue = AutoChartFormatters(
            cacheIdentity: "unused-value", value: nil)
        let optionalValue: AutoChartFormatters.ValueFormatter? = {
            _, _, _, _, _ in nil
        }
        let identityWithOptionalValue = AutoChartFormatters(
            cacheIdentity: optionalCacheIdentity, value: optionalValue)
        #expect(identityWithoutValue.callbackIdentity == nil)
        #expect(identityWithNilValue.callbackIdentity == nil)
        #expect(identityWithOptionalValue.callbackIdentity != nil)
    }

    @Test func presentationContextPreservesAutoupdatingFoundationValues() throws {
        let context = AutoChartPresentationContext(
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent)
        #expect(context.locale == Locale.autoupdatingCurrent)
        #expect(context.timeZone == TimeZone.autoupdatingCurrent)
        #expect(context.locale != Locale(identifier: context.localeIdentifier))
        #expect(context.timeZone != TimeZone(identifier: context.timeZoneIdentifier))
        let liveIdentity = AutoChartPresentationContextIdentity(context)
        #expect(liveIdentity.foundation.usesAutoupdatingLocale)
        #expect(liveIdentity.foundation.usesAutoupdatingTimeZone)
        #expect(liveIdentity.foundation.localeIdentifier == Locale.autoupdatingCurrent.identifier)
        #expect(liveIdentity.foundation.timeZoneIdentifier == TimeZone.autoupdatingCurrent.identifier)

        let roundTripped = try JSONDecoder().decode(
            AutoChartPresentationContext.self,
            from: JSONEncoder().encode(context))
        #expect(roundTripped == context)

        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
                as? [String: Any])
        #expect(encoded["usesAutoupdatingLocale"] as? Bool == true)
        #expect(encoded["usesAutoupdatingTimeZone"] as? Bool == true)

        let utc = try #require(TimeZone(identifier: "UTC"))
        var flaggedAutoupdating = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    AutoChartPresentationContext(
                        locale: Locale(identifier: "en_US"),
                        timeZone: utc)))
                as? [String: Any])
        flaggedAutoupdating["usesAutoupdatingLocale"] = true
        flaggedAutoupdating["usesAutoupdatingTimeZone"] = true
        let restoredAutoupdating = try JSONDecoder().decode(
            AutoChartPresentationContext.self,
            from: JSONSerialization.data(withJSONObject: flaggedAutoupdating))
        #expect(restoredAutoupdating.locale == .autoupdatingCurrent)
        #expect(restoredAutoupdating.timeZone == .autoupdatingCurrent)

        let legacy = Data(
            #"{"identity":"legacy","localeIdentifier":"en_US","timeZoneIdentifier":"UTC"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(
            AutoChartPresentationContext.self, from: legacy)
        #expect(decodedLegacy.locale.identifier == "en_US")
        #expect(decodedLegacy.timeZone.identifier == "GMT")
        #expect(decodedLegacy.localeIdentifier == "en_US")
        #expect(decodedLegacy.timeZoneIdentifier == "UTC")

        var lexical = AutoChartPresentationContext(
            locale: Locale(identifier: "en_US"),
            timeZone: .gmt)
        lexical.localeIdentifier = "iw_IL"
        lexical.timeZoneIdentifier = "UTC"
        #expect(lexical.locale.identifier == "he_IL")
        #expect(lexical.timeZone.identifier == "GMT")
        #expect(lexical.localeIdentifier == "iw_IL")
        #expect(lexical.timeZoneIdentifier == "UTC")
        let lexicalRoundTrip = try JSONDecoder().decode(
            AutoChartPresentationContext.self,
            from: JSONEncoder().encode(lexical))
        #expect(lexicalRoundTrip == lexical)
        #expect(lexicalRoundTrip.localeIdentifier == "iw_IL")
        #expect(lexicalRoundTrip.timeZoneIdentifier == "UTC")
    }

    @MainActor
    @Test func convenienceViewInitializersDeferPresentationWork() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(request, preparation: .primary)
        let chart = try #require(analysis.primaryChart)
        let calls = V3Counter()
        let formatters = AutoChartFormatters(request: { _, _, _ in
            calls.increment()
            return nil
        })

        AutoChartConveniencePresentationCache.removeAll()
        let firstID = AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v1"),
            formatters: formatters,
            textResolver: .default).id
        let identicalID = AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v1"),
            formatters: formatters,
            textResolver: .default).id
        let invalidatedID = AutoChartPresentationRequest(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v2"),
            formatters: formatters,
            textResolver: .default).id
        #expect(firstID == identicalID)
        #expect(firstID != invalidatedID)
        #expect(firstID.context.foundation.localeIdentifier == firstID.context.localeIdentifier)
        #expect(firstID.context.foundation.usesAutoupdatingLocale)
        #expect(firstID.context.foundation.resolvedLocale == Locale.current)
        #expect(
            firstID.formatterFoundation.timeZoneIdentifier
                == formatters.timeZone.identifier)

        _ = AutoChartView(
            preparedChart: chart,
            analysisID: analysis.id,
            presentationContext: .init(identity: "convenience-v1"),
            formatters: formatters)
        _ = AutoChartView(
            analysis: analysis,
            presentationContext: .init(identity: "analysis-v1"),
            formatters: formatters)
        _ = AutoChartPlot(
            preparedChart: chart,
            analysisID: analysis.id,
            presentationContext: .init(identity: "plot-v1"),
            formatters: formatters)
        #expect(calls.value == 0)
    }

    @Test func directViewFallbackFormattersFollowTheEffectiveContext() throws {
        let timeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        let explicitContext = AutoChartPresentationContext(
            identity: "explicit",
            locale: Locale(identifier: "fr_FR"),
            timeZone: timeZone)
        let explicit = AutoChartViewPresentationInputs.resolve(
            explicitContext: explicitContext,
            environmentContext: nil,
            explicitFormatters: nil,
            environmentFormatters: nil,
            explicitTextResolver: nil,
            environmentTextResolver: nil)
        #expect(explicit.context == explicitContext)
        #expect(explicit.formatters.locale == explicitContext.locale)
        #expect(explicit.formatters.timeZone == explicitContext.timeZone)

        let environmentContext = AutoChartPresentationContext(
            identity: "environment",
            locale: Locale(identifier: "de_DE"),
            timeZone: .gmt)
        let inherited = AutoChartViewPresentationInputs.resolve(
            explicitContext: nil,
            environmentContext: environmentContext,
            explicitFormatters: nil,
            environmentFormatters: nil,
            explicitTextResolver: nil,
            environmentTextResolver: nil)
        #expect(inherited.context == environmentContext)
        #expect(inherited.formatters.locale == environmentContext.locale)
        #expect(inherited.formatters.timeZone == environmentContext.timeZone)
    }
}

@MainActor
@Suite struct V3SessionTests {
    @Test func cancellableValidationStopsInsideARowScan() throws {
        let dataset = try domainDataset()
        let snapshot = AutoChartSnapshot(dataset)
        let specification = AutoChartSpecification(
            family: .bar,
            encoding: .init(x: "category", y: "value"),
            aggregation: .none)
        let ordinary = AutoChartRecommendationEngine.validate(
            specification: specification, snapshot: snapshot)
        let hasDuplicate = ordinary.issues.contains(where: {
            $0.messageValue.code == .duplicateMark
        })
        #expect(hasDuplicate)

        var checks = 0
        let cancelled = AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: AutoChartProfiler.profileIndex(snapshot),
            cancellationRequested: {
                checks += 1
                return checks >= 4
            })
        #expect(checks >= 4)
        #expect(cancelled.issues.isEmpty)
    }

    @Test func cachedPreparationKeepsKnownChoiceAndLeavesUnlistedChoiceNeutral()
        async throws
    {
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let primary = try #require(base.outcome.catalog?.primary)
        let known = AutoChartSession<Int>(cache: cache)
        known.load(request, preference: .automatic)
        guard case .preparing = known.state else {
            Issue.record("A completed analysis should enter cached preparation immediately.")
            return
        }
        #expect(known.currentRecommendation?.id == primary.id)
        known.cancel()

        let missing = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "off-catalog-unresolved"))
        let unlisted = AutoChartSession<Int>(cache: cache)
        unlisted.load(request, preference: .chart(.specific(missing)))
        guard case .preparing = unlisted.state else {
            Issue.record("An unresolved cached choice should still prepare as Chart.")
            return
        }
        #expect(unlisted.currentRecommendation == nil)
        unlisted.cancel()
    }

    @Test func unloadRemovesTheRequestBehindLaterPreferenceChanges() async throws {
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let session = AutoChartSession<Int>(cache: cache)
        session.load(request, preference: .automatic)
        _ = try await readyAnalysis(from: session)
        #expect(session.currentRecommendation != nil)

        session.unload()
        #expect(session.currentRecommendation == nil)
        #expect(session.selection.isEmpty)
        guard case .idle = session.state else {
            Issue.record("Unloading must leave the session idle.")
            return
        }
        session.setPreference(.chart(.recommended))
        #expect(session.preference == .chart(.recommended))
        session.retry()
        guard case .idle = session.state else {
            Issue.record("An unloaded request restarted after a preference change.")
            return
        }
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable))
    func retryableFailureRetainsTheSelectedChoiceForSameTypeRetry()
        async throws
    {
        #if ATC_TEST_HOOKS
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let session = AutoChartSession<Int>(cache: cache)
        session.load(request, preference: .chart(.specific(selected.id)))
        #expect(session.currentRecommendation?.id == selected.id)
        session.failCurrentAttemptForTesting(AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.retryableFailure",
            message: "A controlled presentation failure."))
        guard case .failed = session.state else {
            Issue.record("The controlled failure did not become visible.")
            return
        }
        #expect(session.currentRecommendation?.id == selected.id)

        session.retry(preference: .chart(.specific(selected.id)))
        guard case .preparing = session.state else {
            Issue.record("The same selected type did not start cached preparation.")
            return
        }
        #expect(session.currentRecommendation?.id == selected.id)
        session.cancel()
        #endif
    }

    @Test func cancelledProgressTextResolutionDoesNotStartResolver() async {
        let gate = V3AsyncTestGate()
        let calls = V3Counter()
        let resolver = AutoChartTextResolver { message in
            calls.increment()
            return message.defaultText
        }
        let resolution = Task {
            await gate.pause()
            return await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.preparing,
                using: resolver)
        }

        guard await gate.waitUntilPaused() else {
            resolution.cancel()
            await gate.release()
            Issue.record("The cancellation test did not reach its gate.")
            return
        }
        resolution.cancel()
        await gate.release()

        #expect(await resolution.value == nil)
        #expect(calls.value == 0)
    }

    @Test func progressTextResolutionReturnsPromptlyWhenCancelled() async {
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let resolver = AutoChartTextResolver { _ in
            callback.invoke()
            return "Resolved"
        }
        let resolution = Task {
            await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.preparing,
                using: resolver)
        }

        guard await waitForV3Condition({ callback.isBlocked }) else {
            resolution.cancel()
            Issue.record("The progress text resolver did not begin.")
            return
        }
        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        resolution.cancel()
        let resolved = await resolution.value

        #expect(resolved == nil)
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(1))
    }

    @Test func newerProgressResolutionDoesNotWaitForCancelledCallback() async {
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let scheduler = AutoChartCallbackWorkScheduler(
            maximumConcurrentJobs: 2,
            queue: DispatchQueue.global(qos: .userInitiated))
        let resolver = AutoChartTextResolver { message in
            callback.invoke()
            return message.defaultText
        }
        let first = Task {
            await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.preparing,
                using: resolver,
                on: scheduler)
        }

        guard await waitForV3Condition({ callback.isBlocked }) else {
            first.cancel()
            Issue.record("The first progress resolver did not begin.")
            return
        }
        first.cancel()
        #expect(await first.value == nil)

        let second = Task {
            return await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.updating,
                using: resolver,
                on: scheduler)
        }
        #expect(await second.value == AutoChartProgressAccessibility.updating.defaultText)
        #expect(callback.completedInvocations == 1)

        callback.release()
        #expect(await waitForV3Condition({ callback.completedInvocations == 2 }))
        #expect(callback.completedInvocations == 2)
        #expect(!callback.didTimeOut)
    }

    @Test func progressTextResolutionRetainsActiveCallbackContext() async {
        let resolverReached = DispatchSemaphore(value: 0)
        let outerToken = AutoChartHostCallbackToken()
        let resolver = AutoChartTextResolver { _ in
            let result = AutoChartHostCallbackActivity.invoke(
                outerToken,
                { "context-missing" },
                fallback: "context-restored")
            resolverReached.signal()
            return result
        }

        let (resolution, resolverStarted): (Task<String?, Never>, Bool) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = AutoChartHostCallbackActivity.invoke(
                        outerToken,
                        {
                            let resolution = Task {
                                await AutoChartProgressTextResolution.resolve(
                                    AutoChartProgressAccessibility.preparing,
                                    using: resolver)
                            }
                            let started =
                                resolverReached.wait(timeout: .now() + 2) == .success
                            return (resolution, started)
                        },
                        fallback: (Task { nil }, false))
                    continuation.resume(returning: result)
                }
            }

        #expect(resolverStarted)
        #expect(await resolution.value == "context-restored")
    }

    @Test func presentationResolutionReturnsPromptlyWhenCancelled() async throws {
        let request = try AutoChartRequest(table: domainDataset())
        let analysis = try await AutoChartAnalyzer().analyze(
            request,
            preparation: .primary)
        let chart = try #require(analysis.primaryChart)
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let formatters = AutoChartFormatters(request: { _, _, _ in
            callback.invoke()
            return nil
        })
        let presentation = Task {
            try await AutoChartPresenter().presentCancellable(
                chart,
                formatters: formatters)
        }

        guard await waitForV3Condition({ callback.isBlocked }) else {
            presentation.cancel()
            Issue.record("The presentation resolver did not begin.")
            return
        }
        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        presentation.cancel()
        do {
            _ = try await presentation.value
            Issue.record("Cancelled presentation unexpectedly completed.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(1))
    }

    @Test func asyncTestGateRegistersAndReleasesEveryWaiter() async {
        let gate = V3AsyncTestGate()
        let first = Task { await gate.pause() }
        let second = Task { await gate.pause() }

        guard await gate.waitUntilPaused(2) else {
            first.cancel()
            second.cancel()
            await gate.release()
            await first.value
            await second.value
            Issue.record("Both test-gate waiters must pause before release.")
            return
        }
        await gate.release()
        await first.value
        await second.value
        let activePauseCount = await gate.activePauseCount
        #expect(activePauseCount == 0)

        let third = Task { await gate.pause() }
        guard await gate.waitUntilPaused() else {
            third.cancel()
            await gate.release()
            await third.value
            Issue.record("The reused test gate must register its waiter.")
            return
        }
        await gate.release()
        await third.value
    }

    @Test func sessionPresentationRunsOffMainActor() async throws {
        let recorder = V3ThreadRecorder()
        let formatters = AutoChartFormatters(request: { _, _, _ in
            recorder.recordCurrentThread()
            return nil
        })
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(
            try AutoChartRequest(table: domainDataset()),
            formatters: formatters)
        _ = try await readyPresentation(from: session) { _ in true }

        #expect(recorder.result.count > 0)
        #expect(!recorder.result.observedMainThread)
    }

    @Test func revertingToReadyPresentationCancelsPendingReplacement() async throws {
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(
            request,
            presentationContext: .init(identity: "ready-a"))
        _ = try await readyPresentation(from: session) {
            $0.context.identity == "ready-a"
        }

        let blockingFormatters = AutoChartFormatters(request: { _, _, _ in
            callback.invoke()
            return nil
        })
        session.setPresentationContext(
            .init(identity: "pending-b"),
            formatters: blockingFormatters)
        #expect(await waitForV3Condition(timeout: .seconds(5)) { callback.isBlocked })
        #expect(session.isPresentationPending)
        guard case .ready(_, let visible?) = session.state else {
            Issue.record("The existing presentation must remain visible.")
            return
        }
        #expect(visible.context.identity == "ready-a")

        session.setPresentationContext(
            .init(identity: "ready-a"),
            formatters: nil)
        #expect(!session.isPresentationPending)

        callback.release()
        #expect(
            await waitForV3Condition(timeout: .seconds(5)) {
                callback.completedInvocations > 0
            })
        #expect(!callback.didTimeOut)
        guard case .ready(_, let presented) = session.state else {
            Issue.record("The restored presentation must remain ready.")
            return
        }
        #expect(presented?.context.identity == "ready-a")
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func sessionProgressPreservesAttemptModeAndReportsColdPreparation() async throws {
        #if ATC_TEST_HOOKS
        let coldGate = V3AsyncTestGate()
        let coldCache = AutoChartCache(
            testHooks: .chartPreparation { await coldGate.pause() })
        let coldRequest = try AutoChartRequest(table: domainDataset())
        let coldSession = AutoChartSession<Int>(cache: coldCache)
        coldSession.load(coldRequest, preparation: .primary)
        guard await coldGate.waitUntilPaused() else {
            coldSession.cancel()
            await coldGate.release()
            Issue.record("Cold chart preparation did not reach its test gate.")
            return
        }
        let observedColdProgress = await waitForV3Condition {
            guard case .analyzing(let progress) = coldSession.state else { return false }
            return progress?.phase == .chartPreparation
        }
        guard observedColdProgress,
            case .analyzing(let coldProgress) = coldSession.state
        else {
            await coldGate.release()
            Issue.record("Cold chart preparation must remain in analyzing mode.")
            return
        }
        #expect(coldProgress?.phase == .chartPreparation)
        await coldGate.release()
        _ = try await readyAnalysis(from: coldSession)

        let warmGate = V3AsyncTestGate()
        let warmCache = AutoChartCache(
            testHooks: .chartPreparation { await warmGate.pause() })
        let warmRequest = try AutoChartRequest(table: domainDataset())
        _ = try await AutoChartAnalyzer(cache: warmCache).analyze(
            warmRequest, preparation: .none)
        let progressToken = warmCache.registerProgress(for: warmRequest.id) { _ in }
        warmCache.reportProgress(
            AutoChartProgress(phase: .recommendation),
            for: warmRequest.id,
            fallback: nil)

        let warmSession = AutoChartSession<Int>(cache: warmCache)
        warmSession.load(warmRequest, preparation: .primary)
        guard await warmGate.waitUntilPaused() else {
            warmSession.cancel()
            await warmGate.release()
            warmCache.unregisterProgress(for: warmRequest.id, token: progressToken)
            Issue.record("Warm chart preparation did not reach its test gate.")
            return
        }
        let observedWarmProgress = await waitForV3Condition {
            guard case .preparing(_, let progress) = warmSession.state else { return false }
            return progress?.phase == .chartPreparation
        }
        guard observedWarmProgress,
            case .preparing(_, let warmProgress) = warmSession.state
        else {
            await warmGate.release()
            warmCache.unregisterProgress(for: warmRequest.id, token: progressToken)
            Issue.record("Replayed analysis progress must not regress warm preparation.")
            return
        }
        #expect(warmProgress?.phase == .chartPreparation)
        await warmGate.release()
        warmCache.unregisterProgress(for: warmRequest.id, token: progressToken)
        _ = try await readyAnalysis(from: warmSession)
        #endif
    }

    @Test func loadedPresentationUpdatesRemainUnderActiveEnvironmentOverrides()
        async throws
    {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        let loadedFormatters = AutoChartFormatters(request: { _, _, _ in nil })
        let loadedResolver = AutoChartTextResolver { "loaded:\($0.defaultText)" }
        let environmentFormatters = AutoChartFormatters(request: { _, _, _ in nil })
        let environmentResolver = AutoChartTextResolver { "environment:\($0.defaultText)" }

        session.load(
            request,
            presentationContext: .init(identity: "loaded-v1"),
            formatters: loadedFormatters,
            textResolver: loadedResolver)
        _ = try await readyAnalysis(from: session)
        session.applyPresentationEnvironment(
            context: .init(identity: "environment"),
            formatters: environmentFormatters,
            textResolver: environmentResolver)

        session.setPresentationContext(.init(identity: "loaded-v2"))
        let overridden = try await readyPresentation(from: session) {
            $0.context.identity == "environment"
        }
        #expect(overridden.context.identity == "environment")
        #expect(
            overridden.formatters.callbackIdentity
                == environmentFormatters.callbackIdentity)
        #expect(
            overridden.textResolver.callbackIdentity
                == environmentResolver.callbackIdentity)

        session.applyPresentationEnvironment(
            context: nil, formatters: nil, textResolver: nil)
        let restored = try await readyPresentation(from: session) {
            $0.context.identity == "loaded-v2"
        }
        #expect(restored.context.identity == "loaded-v2")
        #expect(restored.formatters.callbackIdentity == loadedFormatters.callbackIdentity)
        #expect(restored.textResolver.callbackIdentity == loadedResolver.callbackIdentity)
    }

    @Test func contextOnlyUpdatesPreserveLoadedPresentationCallbacks() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        let resolver = AutoChartTextResolver { message in
            "loaded:\(message.defaultText)"
        }
        let formatters = AutoChartFormatters(request: { _, _, _ in nil })
        session.load(request, formatters: formatters, textResolver: resolver)
        _ = try await readyAnalysis(from: session)

        session.setPresentationContext(.init(identity: "compact"))
        let presented = try await readyPresentation(from: session) {
            $0.context.identity == "compact"
        }
        #expect(presented.formatters.callbackIdentity == formatters.callbackIdentity)
        #expect(presented.textResolver.callbackIdentity == resolver.callbackIdentity)

        let replacementFormatters = AutoChartFormatters(request: { _, _, _ in nil })
        session.setPresentationContext(
            .init(identity: "regular"), formatters: replacementFormatters)
        let reformatted = try await readyPresentation(from: session) {
            $0.context.identity == "regular"
        }
        #expect(
            reformatted.formatters.callbackIdentity
                == replacementFormatters.callbackIdentity)
        #expect(reformatted.textResolver.callbackIdentity == resolver.callbackIdentity)

        let replacementResolver = AutoChartTextResolver { $0.defaultText }
        session.setPresentationContext(
            .init(identity: "accessible"), textResolver: replacementResolver)
        let relocalized = try await readyPresentation(from: session) {
            $0.context.identity == "accessible"
        }
        #expect(
            relocalized.formatters.callbackIdentity
                == replacementFormatters.callbackIdentity)
        #expect(
            relocalized.textResolver.callbackIdentity
                == replacementResolver.callbackIdentity)
    }

    @Test func preferenceChangesPreserveAllCatalogedPreparationStrategy() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request, preparation: .allCataloged)
        let initial = try await readyAnalysis(from: session)
        let catalog = try #require(initial.outcome.catalog)
        let alternative = try #require(catalog.cataloged.dropFirst().first)
        #expect(initial.preparedCharts.count == catalog.cataloged.count)

        session.setPreference(.chart(.specific(alternative.id)))
        _ = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        let updated = try await readyAnalysis(from: session)
        #expect(updated.primaryChart?.recommendation.id == alternative.id)
        #expect(updated.preparedCharts.count == catalog.cataloged.count)
    }

    @Test func preferenceSetterRetainsVoidFunctionCompatibility() {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let setter: (AutoChartPreference) -> Void = session.setPreference
        setter(.table)
        #expect(session.preference == .table)
    }

    @Test func preloadedPreferenceBecomesOmittedLoadDefaultAndExplicitValueWins()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let inherited = AutoChartSession<Int>(cache: AutoChartCache())
        inherited.setPreference(.table)
        inherited.load(request)
        _ = try await fallbackAnalysis(from: inherited)
        #expect(inherited.preference == .table)

        let overridden = AutoChartSession<Int>(cache: AutoChartCache())
        overridden.setPreference(.table)
        overridden.load(request, preference: .automatic)
        _ = try await readyAnalysis(from: overridden)
        #expect(overridden.preference == .automatic)
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func equivalentPreferenceDoesNotRestartAnalyzingOrPreparingWork() async throws {
        #if ATC_TEST_HOOKS
        let coldGate = V3AsyncTestGate()
        let coldStarts = V3Counter()
        let coldCache = AutoChartCache(
            testHooks: .chartPreparation {
                coldStarts.increment()
                await coldGate.pause()
            })
        let coldRequest = try AutoChartRequest(table: domainDataset())
        let coldSession = AutoChartSession<Int>(cache: coldCache)
        coldSession.load(coldRequest, preparation: .primary)
        guard await coldGate.waitUntilPaused() else {
            coldSession.cancel()
            await coldGate.release()
            Issue.record("Cold analysis did not reach its preparation gate.")
            return
        }
        guard case .analyzing = coldSession.state else {
            coldSession.cancel()
            await coldGate.release()
            Issue.record("Cold preparation must remain in analyzing state.")
            return
        }
        coldSession.setPreference(coldSession.preference)
        await Task.yield()
        #expect(coldStarts.value == 1)
        guard case .analyzing = coldSession.state else {
            coldSession.cancel()
            await coldGate.release()
            Issue.record("Equivalent preference restarted cold analysis.")
            return
        }
        await coldGate.release()
        _ = try await readyAnalysis(from: coldSession)

        let warmGate = V3AsyncTestGate()
        let warmStarts = V3Counter()
        let warmCache = AutoChartCache(
            testHooks: .chartPreparation {
                warmStarts.increment()
                await warmGate.pause()
            })
        let warmRequest = try AutoChartRequest(table: domainDataset())
        _ = try await AutoChartAnalyzer(cache: warmCache).analyze(
            warmRequest, preparation: .none)
        let warmSession = AutoChartSession<Int>(cache: warmCache)
        warmSession.load(warmRequest, preparation: .primary)
        guard await warmGate.waitUntilPaused() else {
            warmSession.cancel()
            await warmGate.release()
            Issue.record("Warm preparation did not reach its test gate.")
            return
        }
        guard case .preparing = warmSession.state else {
            warmSession.cancel()
            await warmGate.release()
            Issue.record("Warm preparation must remain in preparing state.")
            return
        }
        warmSession.setPreference(warmSession.preference)
        await Task.yield()
        #expect(warmStarts.value == 1)
        guard case .preparing = warmSession.state else {
            warmSession.cancel()
            await warmGate.release()
            Issue.record("Equivalent preference restarted warm preparation.")
            return
        }
        await warmGate.release()
        _ = try await readyAnalysis(from: warmSession)
        #endif
    }

    @Test func equivalentPreferenceDoesNotRestartTerminalOrCancelledStates()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())

        let readySession = AutoChartSession<Int>(cache: AutoChartCache())
        readySession.load(request)
        let readyAnalysisValue = try await readyAnalysis(from: readySession)
        let readyPresentationValue = try await readyPresentation(
            from: readySession) { _ in true }
        readySession.setPreference(readySession.preference)
        guard case .ready(let unchangedAnalysis, let unchangedPresentation?) =
            readySession.state
        else {
            Issue.record("Equivalent ready preference changed session state.")
            return
        }
        #expect(unchangedAnalysis.id == readyAnalysisValue.id)
        #expect(unchangedPresentation.requestID == readyPresentationValue.requestID)
        #expect(!readySession.isChartUpdatePending)
        #expect(!readySession.isPresentationPending)

        let fallbackSession = AutoChartSession<Int>(cache: AutoChartCache())
        fallbackSession.load(request, preference: .table)
        let fallback = try await fallbackAnalysis(from: fallbackSession)
        fallbackSession.setPreference(fallbackSession.preference)
        guard case .fallback(let unchangedFallback, _) = fallbackSession.state else {
            Issue.record("Equivalent fallback preference restarted analysis.")
            return
        }
        #expect(unchangedFallback.id == fallback.id)

        let reads = V3Counter()
        let invalid = CountingTable(
            chartRows: [
                CountingRow(
                    chartRowID: 1, category: "A", value: 1, cellReads: reads),
                CountingRow(
                    chartRowID: 1, category: "B", value: 2, cellReads: reads),
            ],
            chartDataKey: .trusted(identity: "equivalent-failure", revision: "1"))
        let failedSession = AutoChartSession<Int>(cache: AutoChartCache())
        failedSession.load(try AutoChartRequest(table: invalid))
        let failure = try await sessionFailure(from: failedSession)
        failedSession.setPreference(failedSession.preference)
        guard case .failed(let unchangedFailure) = failedSession.state else {
            Issue.record("Equivalent failed preference started another attempt.")
            return
        }
        #expect(unchangedFailure.episodeID == failure.episodeID)

        readySession.cancel()
        readySession.setPreference(readySession.preference)
        guard case .idle = readySession.state else {
            Issue.record("Equivalent preference restarted a cancelled session.")
            return
        }
        readySession.setPreference(.table)
        _ = try await fallbackAnalysis(from: readySession)
        #expect(readySession.preference == .table)
    }

    @Test func pendingPresentationSamePreferenceDoesNotRestart() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let analysis = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        session.selection = original.preparedChart.selections(
            for: [10], analysisID: analysis.id)
        let savedSelection = session.selection
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "same-preference-pending-presentation",
            request: { _, _, _ in callback.invoke(); return nil })
        session.setPresentationContext(
            .init(identity: "new-presentation"), formatters: formatters)
        #expect(await waitForV3Condition { callback.isBlocked })
        #expect(session.isPresentationPending)
        session.setPreference(session.preference)
        guard case .ready(_, let stillVisible?) = session.state else {
            Issue.record("An equivalent preference must keep the ready chart visible.")
            return
        }
        #expect(stillVisible.requestID == original.requestID)
        #expect(session.selection == savedSelection)
        #expect(session.isPresentationPending)
        callback.release()
        _ = try await readyPresentation(from: session) {
            $0.context.identity == "new-presentation"
                && $0.requestID.formatterCallback == formatters.callbackIdentity
        }
        #expect(session.selection == savedSelection)
        #expect(!session.isPresentationPending)
    }

    @Test func sameChartPolicyRebindKeepsReadyPresentationAndSelection() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer().analyze(request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let stale = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
            specificationID: selected.specification.id)
        session.load(request, preference: .chart(.specific(stale)))
        let ready = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(for: [10], analysisID: ready.id)
        #expect(!session.selection.isEmpty)

        session.setPreference(.chart(.specific(selected.id)))
        guard case .ready(let updated, let unchanged?) = session.state else {
            Issue.record("A policy-only rebind must remain ready synchronously.")
            return
        }
        #expect(unchanged.requestID == presented.requestID)
        #expect(updated.preferenceResolution?.recommendation?.id == selected.id)
        #expect(updated.preferenceResolution?.replacementPreference == nil)
        #expect(session.selection == presented.preparedChart.selections(for: [10], analysisID: ready.id))
    }

    @Test func sameChartPreferenceChangeKeepsAPendingPresentation() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let recommendation = try #require(initial.primaryChart?.recommendation)
        session.selection = original.preparedChart.selections(
            for: [10], analysisID: initial.id)
        let savedSelection = session.selection

        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let pendingFormatters = AutoChartFormatters(
            cacheIdentity: "same-chart-pending-presentation",
            request: { _, _, _ in callback.invoke(); return nil })
        session.setPresentationContext(
            .init(identity: "pending-context"),
            formatters: pendingFormatters)
        #expect(await waitForV3Condition { callback.isBlocked })
        #expect(session.isPresentationPending)

        session.setPreference(.chart(.specific(recommendation.id)))
        guard case .ready(let updated, let stillVisible?) = session.state else {
            Issue.record("The ready chart must remain visible during presentation.")
            return
        }
        #expect(stillVisible.requestID == original.requestID)
        #expect(updated.preferenceResolution?.recommendation?.id == recommendation.id)
        #expect(session.isPresentationPending)
        #expect(session.selection == savedSelection)

        callback.release()
        _ = try await readyPresentation(from: session) {
            $0.requestID.formatterCallback == pendingFormatters.callbackIdentity
        }
        let final = try await readyAnalysis(from: session)
        #expect(final.preferenceResolution?.recommendation?.id == recommendation.id)
        #expect(session.selection == savedSelection)
    }

    @Test func preferenceChangeKeepsCurrentChartWhilePresentationIsPending()
        async throws
    {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        session.setPresentationContext(
            .init(identity: "blocked-before-preference"),
            formatters: AutoChartFormatters(
                cacheIdentity: "blocked-before-preference",
                request: { _, _, _ in callback.invoke(); return nil }))
        #expect(await waitForV3Condition { callback.isBlocked })
        session.setPreference(.chart(.specific(alternative.id)))
        guard case .ready(_, let stillVisible?) = session.state else {
            Issue.record("Preference analysis must keep the current chart visible.")
            return
        }
        #expect(stillVisible.requestID == original.requestID)
        _ = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        callback.release()
    }

    @Test func revertingPreferenceCancelsAPendingDifferentChart() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        let callback = V3OneShotBlockingCallback(startsArmed: false)
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "pending-different-chart",
            request: { request, _, _ in
                callback.invoke()
                return nil
            })
        session.setPresentationContext(
            .init(identity: "pending-different-chart"), formatters: formatters)
        let visible = try await readyPresentation(from: session) {
            $0.requestID.formatterCallback == formatters.callbackIdentity
        }
        callback.arm()
        session.setPreference(.chart(.specific(alternative.id)))
        #expect(await waitForV3Condition {
            callback.isBlocked && session.isPresentationPending
        })
        session.setPreference(.chart(.specific(original.preparedChart.recommendation.id)))
        #expect(!session.isPresentationPending)
        guard case .ready(let rebound, let stillVisible?) = session.state else {
            Issue.record("The chosen chart must remain ready after reversion.")
            return
        }
        #expect(stillVisible.requestID == visible.requestID)
        #expect(rebound.primaryChart?.recommendation.id
            == original.preparedChart.recommendation.id)
        callback.release()
        #expect(await waitForV3Condition { callback.completedInvocations > 0 })
        await Task.yield()
        guard case .ready(let final, let presented?) = session.state else {
            Issue.record("A cancelled replacement must leave the chosen chart ready.")
            return
        }
        #expect(final.primaryChart?.recommendation.id
            == original.preparedChart.recommendation.id)
        #expect(presented.requestID == visible.requestID)
    }

    @Test func pendingChartRemainsPresentationTargetThroughContextChanges() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        let callback = V3OneShotBlockingCallback(startsArmed: false)
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "pending-target-context",
            request: { _, _, _ in callback.invoke(); return nil })
        session.setPresentationContext(
            .init(identity: "target-before"), formatters: formatters)
        _ = try await readyPresentation(from: session) {
            $0.context.identity == "target-before"
        }

        callback.arm()
        session.setPreference(.chart(.specific(alternative.id)))
        #expect(session.isChartUpdatePending)
        #expect(await waitForV3Condition {
            callback.isBlocked && session.isPresentationPending
        })
        session.setPresentationContext(
            .init(identity: "target-after"), formatters: formatters)
        let final = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
                && $0.context.identity == "target-after"
        }
        #expect(final.preparedChart.recommendation.id == alternative.id)
        #expect(session.preference == .chart(.specific(alternative.id)))
        #expect(!session.isChartUpdatePending)
    }

    @Test func revertingPendingPreferenceAppliesLatestPresentationSettings()
        async throws
    {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        let formatters = AutoChartFormatters(
            cacheIdentity: "reverted-latest-formatters",
            request: { _, _, _ in nil })

        session.setPreference(.chart(.specific(alternative.id)))
        #expect(session.isChartUpdatePending)
        #expect(!session.isPresentationPending)
        session.setPresentationContext(
            .init(identity: "reverted-latest"), formatters: formatters)
        session.setPreference(.chart(.specific(original.preparedChart.recommendation.id)))
        let final = try await readyPresentation(from: session) {
            $0.preparedChart.id == original.preparedChart.id
                && $0.context.identity == "reverted-latest"
                && $0.requestID.formatterCallback == formatters.callbackIdentity
        }
        #expect(final.context.identity == "reverted-latest")
        #expect(!session.isChartUpdatePending)
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func failedReplacementClearsSelectionAndPendingTarget() async throws {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        session.selection = original.preparedChart.selections(
            for: [10], analysisID: initial.id)
        #expect(!session.selection.isEmpty)
        session.presentationFailureForTesting = AutoChartFailure(
            stage: .presentationPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.presentationFailure",
            message: "Injected presentation failure")
        session.setPreference(.chart(.specific(alternative.id)))
        #expect(session.isChartUpdatePending)
        _ = try await sessionFailure(from: session)
        #expect(session.selection.isEmpty)
        #expect(!session.isChartUpdatePending)
        #expect(!session.isPresentationPending)
        #endif
    }

    @Test(.disabled(if: !testHooksAvailable, testHooksUnavailable))
    func backgroundFoundationNotificationsReachSessionOnMain() async throws {
        #if ATC_TEST_HOOKS
        #if os(macOS)
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(try AutoChartRequest(table: domainDataset()))
        _ = try await readyPresentation(from: session) { _ in true }
        let threads = V3ThreadRecorder()
        session.environmentApplicationForTesting = { threads.recordCurrentThread() }
        let harness = HostedViewHarnessForTesting(
            rootView: AutoChartSessionView(session: session))
        defer { harness.close() }
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            threads.result.count > 0
        })
        let mountedCount = threads.result.count
        NotificationCenter.default.post(
            name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        #expect(await waitForHostedChartUpdate(in: harness.host) {
            threads.result.count >= mountedCount + 1
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
        #expect(threads.result.allMainThread)
        #endif
        #endif
    }

    @Test func cancellingAReadySessionClearsItsSelection() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(try AutoChartRequest(table: domainDataset()))
        let analysis = try await readyAnalysis(from: session)
        let chart = try await readyPresentation(from: session) { _ in true }
        session.selection = chart.preparedChart.selections(
            for: [10], analysisID: analysis.id)
        #expect(!session.selection.isEmpty)
        session.cancel()
        #expect(session.selection.isEmpty)
        #expect(!session.isChartUpdatePending)
    }

    @Test func primaryStrategyDoesNotShortcutAnAlternativePreference() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request, preparation: .primary)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })
        session.setPreference(.chart(.specific(alternative.id)))
        guard case .ready(_, let stillVisible?) = session.state else {
            Issue.record("Same-request preference work must keep the chart visible.")
            return
        }
        #expect(stillVisible.requestID == original.requestID)
        #expect(await waitForV3Condition {
            guard case .ready(let analysis, _) = session.state else { return false }
            return analysis.preferenceResolution?.recommendation?.id == alternative.id
        })
        let final = try await readyAnalysis(from: session)
        #expect(final.primaryChart?.recommendation.id == initial.primaryChart?.recommendation.id)
    }

    @Test func newerSharedCacheAnalysisBypassesTheDisplayedAnalysisShortcut()
        async throws
    {
        let cache = AutoChartCache()
        let oldSession = AutoChartSession<Int>(cache: cache)
        let otherSession = AutoChartSession<Int>(cache: cache)
        let request = try AutoChartRequest(table: domainDataset())
        oldSession.load(request)
        let oldAnalysis = try await readyAnalysis(from: oldSession)
        let oldPresentation = try await readyPresentation(from: oldSession) { _ in true }
        await cache.removeAll()
        otherSession.load(request)
        let newerAnalysis = try await readyAnalysis(from: otherSession)
        #expect(newerAnalysis.id != oldAnalysis.id)

        oldSession.setPreference(.chart(.specific(
            oldPresentation.preparedChart.recommendation.id)))
        guard case .ready(let stillDisplayed, let stillVisible?) = oldSession.state else {
            Issue.record("The old chart must stay visible while refreshing analysis.")
            return
        }
        #expect(stillDisplayed.id == oldAnalysis.id)
        #expect(stillVisible.requestID == oldPresentation.requestID)
        _ = try await readyPresentation(from: oldSession) {
            $0.preparedChart.id != oldPresentation.preparedChart.id
        }
        let final = try await readyAnalysis(from: oldSession)
        #expect(final.id == newerAnalysis.id)
    }

    @Test func customStateContentAndEnvironmentPresentationAreComposable() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        let view = AutoChartSessionView(
            session: session,
            loading: { progress in Text(progress?.phase.rawValue ?? "loading") },
            fallback: { _, _ in Text("table") },
            failure: { failure in Text(failure.diagnosticID) })
            .autoChartPresentationContext(.init(identity: "environment-v1"))
            .autoChartFormatters(.init(locale: Locale(identifier: "en_US")))
            .autoChartTextResolver(.default)
            .autoChartPalette(.init(marks: [.purple, .orange]))
            .autoChartTheme(
                .init(
                    axisColor: .secondary,
                    legendColor: .primary,
                    markColors: [.purple],
                    titleFont: .headline,
                    labelFont: .caption,
                    distinguishesMarksWithoutColor: true))
        _ = view

        session.load(request)
        _ = try await readyAnalysis(from: session)
        session.setPresentationContext(.init(identity: "environment-v1"))
        let presented = try await readyPresentation(from: session) {
            $0.context.identity == "environment-v1"
        }
        #expect(presented.context.identity == "environment-v1")
    }

    @Test func independentSessionsWarmStartFromOnePackageCache() async throws {
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let preview = AutoChartSession<Int>(cache: cache)
        preview.load(request)
        let previewAnalysis = try await readyAnalysis(from: preview)

        let viewer = AutoChartSession<Int>(cache: cache)
        viewer.load(request)
        let viewerAnalysis = try await readyAnalysis(from: viewer)

        #expect(viewerAnalysis.id == previewAnalysis.id)
        #expect(viewerAnalysis.primaryChart?.id == previewAnalysis.primaryChart?.id)
        #expect(cache.completedAnalysis(for: request.id, as: Int.self)?.id == previewAnalysis.id)
    }

    @Test func replacementRequestClearsVisibleSelectionAndCannotBeOverwritten()
        async throws
    {
        let cache = AutoChartCache()
        let session = AutoChartSession<Int>(cache: cache)
        let firstRequest = try AutoChartRequest(table: domainDataset())
        session.load(firstRequest)
        let first = try await readyAnalysis(from: session)
        let firstChart = try #require(first.primaryChart)
        session.selection = firstChart.selections(
            for: [10], analysisID: first.id)
        #expect(!session.selection.isEmpty)

        var records = v3Records()
        records[0] = V3Record(
            id: 10, category: "Replacement", series: "Actual", value: 42,
            secondValue: 1, start: records[0].start, end: records[0].end)
        let replacement = try AutoChartRequest(table: domainDataset(records: records))
        session.load(replacement)
        guard case .analyzing = session.state else {
            Issue.record("Replacement must clear stale visible state immediately.")
            return
        }
        #expect(session.selection.isEmpty)
        let final = try await readyAnalysis(from: session)
        #expect(final.request == replacement.id)
    }

    @Test func sameRequestPreferenceChangesReuseAnalysisAndPreparedCharts()
        async throws
    {
        let cache = AutoChartCache()
        let session = AutoChartSession<Int>(cache: cache)
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let ready = try await readyAnalysis(from: session)
        let chartID = ready.primaryChart?.id
        let originalChart = try #require(ready.primaryChart)
        session.selection = originalChart.selections(for: [10], analysisID: ready.id)
        #expect(!session.selection.isEmpty)

        session.setPreference(.table)
        let fallback = try await fallbackAnalysis(from: session)
        #expect(fallback.id == ready.id)
        #expect(fallback.primaryChart == nil)
        #expect(session.selection.isEmpty)

        session.setPreference(.chart(.recommended))
        let restored = try await readyAnalysis(from: session)
        #expect(restored.id == ready.id)
        #expect(restored.primaryChart?.id == chartID)
    }

    @Test func retryStartsANewFailureEpisodeAndCancellationStaysIdle() async throws {
        let reads = V3Counter()
        let invalid = CountingTable(
            chartRows: [
                CountingRow(chartRowID: 1, category: "A", value: 1, cellReads: reads),
                CountingRow(chartRowID: 1, category: "B", value: 2, cellReads: reads),
            ],
            chartDataKey: .trusted(identity: "session-invalid", revision: "1"))
        let request = try AutoChartRequest(table: invalid)
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(request)
        let first = try await sessionFailure(from: session)
        session.retry()
        let second = try await sessionFailure(from: session)
        #expect(second.episodeID != first.episodeID)
        #expect(session.preference == .automatic)

        session.retry(preference: .chart(.recommended))
        let third = try await sessionFailure(from: session)
        #expect(third.episodeID != second.episodeID)
        #expect(session.preference == .chart(.recommended))

        session.retry()
        let fourth = try await sessionFailure(from: session)
        #expect(fourth.episodeID != third.episodeID)
        #expect(session.preference == .chart(.recommended))

        session.load(try AutoChartRequest(table: domainDataset()))
        session.cancel()
        guard case .idle = session.state else {
            Issue.record("Cancellation must return the session to idle.")
            return
        }
        await Task.yield()
        guard case .idle = session.state else {
            Issue.record("Cancelled work must not publish a failure.")
            return
        }
    }

    @Test func supersededFailureCannotReplaceANewerReadyRequest() async throws {
        let reads = V3Counter()
        let invalid = CountingTable(
            chartRows: [
                CountingRow(chartRowID: 1, category: "A", value: 1, cellReads: reads),
                CountingRow(chartRowID: 1, category: "B", value: 2, cellReads: reads),
            ],
            chartDataKey: .trusted(identity: "superseded-invalid", revision: "1"))
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(try AutoChartRequest(table: invalid))
        let valid = try AutoChartRequest(table: domainDataset())
        session.load(valid)
        let analysis = try await readyAnalysis(from: session)
        #expect(analysis.request == valid.id)
    }
}

private extension AutoChartRecommendationOutcome {
    var catalog: AutoChartRecommendationCatalog? {
        guard case .charts(let catalog) = self else { return nil }
        return catalog
    }
}

private func captureResult<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async -> Result<Value, any Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

@MainActor
private func readyAnalysis(
    from session: AutoChartSession<Int>
) async throws -> AutoChartAnalysis<Int> {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        switch session.state {
        case .ready(let analysis, _): return analysis
        case .failed(let failure): throw failure
        default: try await Task.sleep(for: .milliseconds(1))
        }
    }
    throw V3TestError.timedOut
}

@MainActor
private func readyPresentation(
    from session: AutoChartSession<Int>,
    matching predicate: (AutoChartPresentedChart<Int>) -> Bool
) async throws -> AutoChartPresentedChart<Int> {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        switch session.state {
        case .ready(_, let presented?) where predicate(presented):
            return presented
        case .failed(let failure):
            throw failure
        default:
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    throw V3TestError.timedOut
}

@MainActor
private func fallbackAnalysis(
    from session: AutoChartSession<Int>
) async throws -> AutoChartAnalysis<Int> {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        switch session.state {
        case .fallback(let analysis, _): return analysis
        case .failed(let failure): throw failure
        default: try await Task.sleep(for: .milliseconds(1))
        }
    }
    throw V3TestError.timedOut
}

@MainActor
private func sessionFailure(
    from session: AutoChartSession<Int>
) async throws -> AutoChartFailure {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if case .failed(let failure) = session.state { return failure }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw V3TestError.timedOut
}

private enum V3TestError: Error { case timedOut }
