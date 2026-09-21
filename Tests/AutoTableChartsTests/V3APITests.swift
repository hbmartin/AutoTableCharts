import Dispatch
import Foundation
import Observation
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

private func offCatalogRecommendation(
    in dataset: AutoChartDataset<Int>,
    request: AutoChartRequest<Int>,
    catalog: AutoChartRecommendationCatalog
) throws -> AutoChartRecommendation {
    var options = request.options
    options.maximumRecommendations = AutoChartRecommendationCatalog.maximumCatalogedCount
    let catalogIDs = Set(catalog.cataloged.map(\.id))
    let candidates = AutoChartRecommendationEngine.recommendations(
        for: dataset,
        context: request.context,
        options: options,
        constraints: request.constraints).candidates
    return try #require(candidates.first { recommendation in
        !catalogIDs.contains(recommendation.id)
            && AutoChartRecommendationEngine.validate(
                specification: recommendation.specification,
                for: dataset).isValid
    })
}

enum V3SameRequestTransition: CaseIterable, Sendable {
    case retry
    case reload

    var label: String {
        switch self {
        case .retry: "retry"
        case .reload: "load"
        }
    }
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

@MainActor
private final class V3ObservationLoop {
    private var isActive = true

    func track(
        _ values: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        guard isActive else { return }
        withObservationTracking {
            values()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.track(values, onChange: onChange)
                onChange()
            }
        }
    }

    func cancel() {
        isActive = false
    }
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
    private var remainsOpen = false

    var activePauseCount: Int { releaseContinuations.count }

    func pause() async {
        if remainsOpen { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if remainsOpen || Task.isCancelled {
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

    func open() {
        remainsOpen = true
        release()
    }

    private func cancelPause(_ token: UUID) {
        releaseContinuations.removeValue(forKey: token)?.resume()
    }
}

#if ATC_TEST_HOOKS
private struct V3OffCatalogFailureFixture {
    let request: AutoChartRequest<Int>
    let recommendation: AutoChartRecommendation
    let failure: AutoChartFailure
    let preparationGate: V3AsyncTestGate
    let preparationStarts: V3Counter
    let cache: AutoChartCache
    let session: AutoChartSession<Int>

    @MainActor
    func cleanUp() {
        session.cancel()
        Task { await preparationGate.open() }
    }
}

@MainActor
private func makeV3OffCatalogFailureFixture(
    configuration: AutoChartAnalyzerConfiguration = .uncached,
    label: String
) async throws -> V3OffCatalogFailureFixture {
    let dataset = try wideDomainDataset()
    let request = try AutoChartRequest(table: dataset)
    let source = try await AutoChartAnalyzer().analyze(
        request, preparation: .none)
    let catalog = try #require(source.outcome.catalog)
    let recommendation = try offCatalogRecommendation(
        in: dataset, request: request, catalog: catalog)
    let preparationGate = V3AsyncTestGate()
    let preparationStarts = V3Counter()
    let failure = AutoChartFailure(
        stage: .chartPreparation,
        kind: .internalFailure,
        isRetryable: true,
        diagnosticID: "ATC.test.offCatalogPreparation.\(label)",
        message: "Controlled \(label) off-catalog preparation failure")
    let cache = AutoChartCache(
        configuration: configuration,
        testHooks: .chartPreparationByRecommendation { recommendationID in
            guard recommendationID == recommendation.id else { return }
            preparationStarts.increment()
            await preparationGate.pause()
            try Task.checkCancellation()
            throw failure
        })
    return V3OffCatalogFailureFixture(
        request: request,
        recommendation: recommendation,
        failure: failure,
        preparationGate: preparationGate,
        preparationStarts: preparationStarts,
        cache: cache,
        session: AutoChartSession<Int>(cache: cache))
}

private struct V3PreparationGateFixture {
    let cache: AutoChartCache
    let request: AutoChartRequest<Int>
    let gate: V3AsyncTestGate
    let preparationStarts: V3Counter
}

@MainActor
private func makeV3PreparationGateFixture(
    warm: Bool
) async throws -> V3PreparationGateFixture {
    let gate = V3AsyncTestGate()
    let preparationStarts = V3Counter()
    let cache = AutoChartCache(
        testHooks: .chartPreparation {
            preparationStarts.increment()
            await gate.pause()
        })
    let request = try AutoChartRequest(table: domainDataset())
    if warm {
        _ = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
    }
    return V3PreparationGateFixture(
        cache: cache,
        request: request,
        gate: gate,
        preparationStarts: preparationStarts)
}

@MainActor
private func hasExpectedV3PreparationState(
    _ session: AutoChartSession<Int>,
    warm: Bool
) -> Bool {
    if warm, case .preparing = session.state { return true }
    if !warm, case .analyzing = session.state { return true }
    return false
}

@MainActor
private func verifySamePreferenceDoesNotRestartPreparation(
    warm: Bool
) async throws {
    let fixture = try await makeV3PreparationGateFixture(warm: warm)
    let attempts = V3Counter()
    let session = AutoChartSession<Int>(cache: fixture.cache)
    session.attemptDidStartForTesting = { attempts.increment() }
    session.load(fixture.request, preparation: .primary)
    defer {
        session.cancel()
        Task { await fixture.gate.release() }
    }

    guard await fixture.gate.waitUntilPaused() else {
        Issue.record(
            warm
                ? "Warm preparation did not reach its test gate."
                : "Cold analysis did not reach its preparation gate.")
        return
    }
    guard hasExpectedV3PreparationState(session, warm: warm) else {
        Issue.record(
            warm
                ? "Warm preparation must remain in preparing state."
                : "Cold preparation must remain in analyzing state.")
        return
    }

    #expect(attempts.value == 1)
    #expect(fixture.preparationStarts.value == 1)
    session.setPreference(session.preference)
    #expect(attempts.value == 1)
    #expect(fixture.preparationStarts.value == 1)
    guard hasExpectedV3PreparationState(session, warm: warm) else {
        Issue.record(
            warm
                ? "Same preference restarted warm preparation."
                : "Same preference restarted cold analysis.")
        return
    }

    await fixture.gate.release()
    _ = try await readyAnalysis(from: session)
    #expect(fixture.preparationStarts.value == 1)
}
#endif

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

    @Test func observedAndExplicitlyRetriedScopesStartNewEpisodes() {
        let cache = AutoChartCache()
        let requestID = AutoChartRequestID(value: 7)
        let scope = AutoChartFailureScope(requestID: requestID)
        func failure() -> AutoChartFailure {
            AutoChartFailure(
                stage: .recommendation,
                kind: .internalFailure,
                isRetryable: true,
                diagnosticID: "ATC.test.episodeContext",
                message: "Controlled episode-context failure")
        }

        let shared = cache.coalescedFailure(
            for: requestID, error: failure(), stage: .recommendation)
        let freshSession = cache.coalescedFailure(
            for: requestID,
            error: failure(),
            stage: .recommendation,
            episodeContext: .coalescing)
        #expect(freshSession.episodeID == shared.episodeID)

        let observedSession = cache.coalescedFailure(
            for: requestID,
            error: failure(),
            stage: .recommendation,
            episodeContext: .init(
                episodesToReplace: [scope: shared.episodeID]))
        #expect(observedSession.episodeID != shared.episodeID)

        let explicitRetry = cache.coalescedFailure(
            for: requestID,
            error: failure(),
            stage: .recommendation,
            episodeContext: .init(
                episodesToReplace: [scope: observedSession.episodeID]))
        #expect(explicitRetry.episodeID != observedSession.episodeID)

        let concurrentRetry = cache.coalescedFailure(
            for: requestID,
            error: failure(),
            stage: .recommendation,
            episodeContext: .init(
                episodesToReplace: [scope: observedSession.episodeID]))
        #expect(concurrentRetry.episodeID == explicitRetry.episodeID)
    }

    @Test func recreatedRecordsNeverReuseAnIncomingFailureEpisode() {
        let cache = AutoChartCache()
        let requestID = AutoChartRequestID(value: 8)
        let incoming = AutoChartFailure(
            stage: .recommendation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.cacheOwnedEpisode",
            message: "Controlled cache-owned episode failure")

        let first = cache.coalescedFailure(
            for: requestID, error: incoming, stage: .recommendation)
        cache.beginRetry(for: requestID)
        let recreated = cache.coalescedFailure(
            for: requestID, error: incoming, stage: .recommendation)

        #expect(first.episodeID != incoming.episodeID)
        #expect(recreated.episodeID != incoming.episodeID)
        #expect(recreated.episodeID != first.episodeID)
    }

    @Test func successfulWorkRetiresOnlyItsExactFailureScopes() async throws {
        let cache = AutoChartCache()
        let analyzer = AutoChartAnalyzer(cache: cache)
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await analyzer.analyze(request, preparation: .none)
        let catalog = try #require(base.outcome.catalog)
        let first = try #require(catalog.cataloged.first)
        let second = try #require(catalog.cataloged.dropFirst().first)
        func failure(_ stage: AutoChartFailureStage) -> AutoChartFailure {
            AutoChartFailure(
                stage: stage,
                kind: .internalFailure,
                isRetryable: true,
                diagnosticID: "ATC.test.exactSuccess.\(stage)",
                message: "Controlled exact-success failure")
        }

        let requestFailure = cache.coalescedFailure(
            for: request.id,
            error: failure(.recommendation),
            stage: .recommendation)
        let firstFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: first.id,
            error: failure(.chartPreparation),
            stage: .chartPreparation)
        let secondFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: second.id,
            error: failure(.chartPreparation),
            stage: .chartPreparation)

        _ = try await analyzer.analyze(
            request,
            preference: .chart(.specific(first.id)),
            preparation: .preferredOrPrimary)

        let renewedRequestFailure = cache.coalescedFailure(
            for: request.id,
            error: failure(.recommendation),
            stage: .recommendation)
        let renewedFirstFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: first.id,
            error: failure(.chartPreparation),
            stage: .chartPreparation)
        let retainedSecondFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: second.id,
            error: failure(.chartPreparation),
            stage: .chartPreparation)
        #expect(renewedRequestFailure.episodeID != requestFailure.episodeID)
        #expect(renewedFirstFailure.episodeID != firstFailure.episodeID)
        #expect(retainedSecondFailure.episodeID == secondFailure.episodeID)
    }

    @MainActor
    @Test(
        .serializedMainActorRegression,
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func chartPreparationFailureEpisodesAreScopedToRecommendation()
        async throws
    {
        #if ATC_TEST_HOOKS
        let cache = AutoChartCache(
            testHooks: .chartPreparationByRecommendation { _ in
                throw AutoChartFailure(
                    stage: .chartPreparation,
                    kind: .internalFailure,
                    isRetryable: true,
                    diagnosticID: "ATC.test.chartPreparation",
                    message: "Controlled chart preparation failure")
            })
        let analyzer = AutoChartAnalyzer(cache: cache)
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await analyzer.analyze(request, preparation: .none)
        let catalog = try #require(base.outcome.catalog)
        let first = try #require(catalog.cataloged.first)
        let second = try #require(catalog.cataloged.dropFirst().first)

        func failure(
            for recommendation: AutoChartRecommendation
        ) async throws -> AutoChartFailure {
            let result = await captureResult {
                try await analyzer.analyze(
                    request,
                    preference: .chart(.specific(recommendation.id)),
                    preparation: .preferredOrPrimary)
            }
            guard case .failure(let error) = result,
                let failure = error as? AutoChartFailure
            else {
                Issue.record("Expected chart preparation to fail.")
                throw CancellationError()
            }
            return failure
        }

        let firstEpisode = try await failure(for: first)
        let repeatedFirstEpisode = try await failure(for: first)
        let secondEpisode = try await failure(for: second)
        #expect(repeatedFirstEpisode.episodeID == firstEpisode.episodeID)
        #expect(secondEpisode.episodeID != firstEpisode.episodeID)

        let session = AutoChartSession<Int>(cache: cache)
        session.load(
            request,
            preference: .chart(.specific(first.id)),
            preparation: .preferredOrPrimary)
        let sessionFirstEpisode = try await sessionFailure(from: session)
        #expect(sessionFirstEpisode.episodeID == firstEpisode.episodeID)

        let freshSession = AutoChartSession<Int>(cache: cache)
        freshSession.load(
            request,
            preference: .chart(.specific(first.id)),
            preparation: .preferredOrPrimary)
        let freshSessionEpisode = try await sessionFailure(from: freshSession)
        #expect(freshSessionEpisode.episodeID == firstEpisode.episodeID)

        session.unload()
        session.load(
            request,
            preference: .chart(.specific(first.id)),
            preparation: .preferredOrPrimary)
        let reloadedFirstEpisode = try await sessionFailure(from: session)
        #expect(reloadedFirstEpisode.episodeID != firstEpisode.episodeID)

        let replacementRequest = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(
                    identity: "failure-episode-replacement",
                    revision: "1")))
        session.load(replacementRequest, preparation: .preferredOrPrimary)
        _ = try await sessionFailure(from: session)
        session.load(
            request,
            preference: .chart(.specific(first.id)),
            preparation: .preferredOrPrimary)
        let postReplacementEpisode = try await sessionFailure(from: session)
        #expect(postReplacementEpisode.episodeID != reloadedFirstEpisode.episodeID)

        session.retry()
        let retriedFirstEpisode = try await sessionFailure(from: session)
        let retainedSecondEpisode = try await failure(for: second)
        #expect(retriedFirstEpisode.episodeID != postReplacementEpisode.episodeID)
        #expect(retainedSecondEpisode.episodeID == secondEpisode.episodeID)

        cache.beginRetry(for: request.id)
        let requestWideRetryEpisode = try await failure(for: second)
        #expect(requestWideRetryEpisode.episodeID != secondEpisode.episodeID)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func everyDirectPreparationSuccessRetiresItsRecommendationEpisode()
        async throws
    {
        #if ATC_TEST_HOOKS
        func verifySuccess(
            _ label: String,
            operation: (AutoChartAnalysis<Int>, AutoChartRecommendation) async throws -> Void
        ) async throws {
            let calls = V3Counter()
            let cache = AutoChartCache(
                configuration: .init(
                    preparedCharts: .init(maximumEntries: 0)),
                testHooks: .chartPreparationByRecommendation { _ in
                    calls.increment()
                    if calls.value != 2 {
                        throw AutoChartFailure(
                            stage: .chartPreparation,
                            kind: .internalFailure,
                            isRetryable: true,
                            diagnosticID: "ATC.test.directPreparationSuccess.\(label)",
                            message: "Controlled \(label) preparation failure")
                    }
                })
            let analyzer = AutoChartAnalyzer(cache: cache)
            let request = try AutoChartRequest(table: domainDataset())
            let base = try await analyzer.analyze(request, preparation: .none)
            let selected = try #require(base.outcome.catalog?.primary)
            let unrelated = try #require(
                base.outcome.catalog?.cataloged.first { $0.id != selected.id })
            let unrelatedFailure = cache.coalescedFailure(
                for: request.id,
                recommendationID: unrelated.id,
                error: AutoChartFailure(
                    stage: .chartPreparation,
                    kind: .internalFailure,
                    isRetryable: true,
                    diagnosticID: "ATC.test.directPreparationSuccess.unrelated",
                    message: "Controlled unrelated preparation failure"),
                stage: .chartPreparation)

            func failure() async throws -> AutoChartFailure {
                let result = await captureResult {
                    try await analyzer.analyze(
                        request,
                        preference: .chart(.specific(selected.id)),
                        preparation: .preferredOrPrimary)
                }
                guard case .failure(let error) = result,
                    let failure = error as? AutoChartFailure
                else {
                    Issue.record("The controlled \(label) preparation did not fail.")
                    throw CancellationError()
                }
                return failure
            }

            let first = try await failure()
            try await operation(base, selected)
            let repeated = try await failure()
            let retainedUnrelated = cache.coalescedFailure(
                for: request.id,
                recommendationID: unrelated.id,
                error: AutoChartFailure(
                    stage: .chartPreparation,
                    kind: .internalFailure,
                    isRetryable: true,
                    diagnosticID: "ATC.test.directPreparationSuccess.unrelated",
                    message: "Controlled unrelated preparation failure"),
                stage: .chartPreparation)

            #expect(repeated.episodeID != first.episodeID, Comment(rawValue: label))
            #expect(
                retainedUnrelated.episodeID == unrelatedFailure.episodeID,
                Comment(rawValue: label))
            #expect(calls.value == 3, Comment(rawValue: label))
        }

        try await verifySuccess("identifier") { analysis, recommendation in
            _ = try await analysis.prepare(recommendation.id)
        }
        try await verifySuccess("specification") { analysis, recommendation in
            _ = try await analysis.prepare(recommendation.specification)
        }
        try await verifySuccess("validation") { analysis, recommendation in
            let validation = try await analysis.validation(
                for: recommendation.specification)
            #expect(validation.isValid)
        }
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func noSharedCacheStartsFreshEpisodesForExistingFailures() async throws {
        #if ATC_TEST_HOOKS
        let incoming = AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.noSharedCacheEpisode",
            message: "Controlled no-shared-cache failure")
        let request = try AutoChartRequest(table: domainDataset())
        let catalogSource = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let selected = try #require(catalogSource.outcome.catalog?.primary)

        func failure(from analyzer: AutoChartAnalyzer) async throws
            -> AutoChartFailure
        {
            let result = await captureResult {
                try await analyzer.analyze(
                    request,
                    preference: .chart(.specific(selected.id)),
                    preparation: .preferredOrPrimary)
            }
            guard case .failure(let error) = result,
                let failure = error as? AutoChartFailure
            else {
                Issue.record("Expected controlled chart preparation to fail.")
                throw CancellationError()
            }
            return failure
        }

        let direct = AutoChartAnalyzer(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { _ in throw incoming })
        let directFirst = try await failure(from: direct)
        let directSecond = try await failure(from: direct)
        #expect(directFirst.episodeID != incoming.episodeID)
        #expect(directSecond.episodeID != incoming.episodeID)
        #expect(directSecond.episodeID != directFirst.episodeID)

        let sharedCache = AutoChartCache(
            configuration: .uncached,
            testHooks: .chartPreparationByRecommendation { _ in throw incoming })
        let shared = AutoChartAnalyzer(cache: sharedCache)
        let sharedFirst = try await failure(from: shared)
        let sharedSecond = try await failure(from: shared)
        #expect(sharedFirst.episodeID != incoming.episodeID)
        #expect(sharedSecond.episodeID == sharedFirst.episodeID)
        #endif
    }

    @MainActor
    @Test(
        .serializedMainActorRegression,
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func retryingCancelledNonfailureResumesSharedFailureHistory()
        async throws
    {
        #if ATC_TEST_HOOKS
        let gate = V3AsyncTestGate()
        let controlledFailure: @Sendable () -> AutoChartFailure = {
            AutoChartFailure(
                stage: .chartPreparation,
                kind: .internalFailure,
                isRetryable: true,
                diagnosticID: "ATC.test.cancelledRetry",
                message: "Controlled cancelled-retry failure")
        }
        let cache = AutoChartCache(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { _ in
                await gate.pause()
                throw controlledFailure()
            })
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let sharedFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: selected.id,
            error: controlledFailure(),
            stage: .chartPreparation)
        let session = AutoChartSession<Int>(cache: cache)

        session.load(
            request,
            preference: .chart(.specific(selected.id)),
            preparation: .preferredOrPrimary)
        guard await gate.waitUntilPaused() else {
            session.cancel()
            await gate.release()
            Issue.record("The initial preparation did not reach its test gate.")
            return
        }
        session.cancel()
        let cancellationClock = ContinuousClock()
        let cancellationDeadline = cancellationClock.now.advanced(by: .seconds(2))
        while await gate.activePauseCount != 0,
            cancellationClock.now < cancellationDeadline
        {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await gate.activePauseCount == 0)

        session.retry()
        guard await gate.waitUntilPaused() else {
            session.cancel()
            await gate.release()
            Issue.record("The resumed preparation did not reach its test gate.")
            return
        }
        await gate.release()
        let resumedFailure = try await sessionFailure(from: session)
        #expect(resumedFailure.episodeID == sharedFailure.episodeID)
        #endif
    }

    @Test func sharedCacheBoundsFailureEpisodesAndKeepsProgressSubscribers() async {
        let cache = AutoChartCache(
            configuration: .init(analyses: .init(maximumEntries: 2)))
        let firstID = AutoChartRequestID(value: 1)
        let scopedID = AutoChartRequestID(value: 2)
        let firstRecommendationID = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "failure-capacity-first"))
        let secondRecommendationID = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "failure-capacity-second"))
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
            for: scopedID,
            recommendationID: firstRecommendationID,
            error: failure(),
            stage: .chartPreparation)
        let third = cache.coalescedFailure(
            for: scopedID,
            recommendationID: secondRecommendationID,
            error: failure(),
            stage: .chartPreparation)
        let repeatedThird = cache.coalescedFailure(
            for: scopedID,
            recommendationID: secondRecommendationID,
            error: failure(),
            stage: .chartPreparation)
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
@Suite(.serializedMainActorRegression) struct V3SessionTests {
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

    @Test func unloadForgetsRequestStateButRetainsSpecificPreference() async throws {
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let session = AutoChartSession<Int>(cache: cache)
        session.load(request, preference: .chart(.specific(selected.id)))
        let ready = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        #expect(session.currentRecommendation != nil)
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: ready.id)
        #expect(!session.selection.isEmpty)

        session.unload()
        #expect(session.currentRecommendation == nil)
        #expect(session.selection.isEmpty)
        #expect(session.preference == .chart(.specific(selected.id)))
        guard case .idle = session.state else {
            Issue.record("Unloading must leave the session idle.")
            return
        }
        session.retry()
        guard case .idle = session.state else {
            Issue.record("An unloaded request restarted during retry.")
            return
        }

        let replacement = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(identity: "unload-replacement", revision: "1")))
        session.load(replacement)
        let inherited = try await readyAnalysis(from: session)
        #expect(inherited.request == replacement.id)
        #expect(session.preference == .chart(.specific(selected.id)))
        #expect(inherited.preferenceResolution?.recommendation?.id == selected.id)
        #expect(inherited.preferenceResolution?.defaultReason == nil)
    }

    @Test func differentPreferenceAfterUnloadDoesNotRestartWork() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(try AutoChartRequest(table: domainDataset()))
        _ = try await readyAnalysis(from: session)

        session.unload()
        session.setPreference(.table)

        #expect(session.preference == .table)
        guard case .idle = session.state else {
            Issue.record("A preference change restarted an unloaded request.")
            return
        }
        session.retry()
        guard case .idle = session.state else {
            Issue.record("Retry restarted an unloaded request after a preference change.")
            return
        }
    }

    @Test func unloadReleasesLoadedCallbacksAfterUsingThem() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        var formatterCapture: V3Counter? = V3Counter()
        var resolverCapture: V3Counter? = V3Counter()
        weak let weakFormatterCapture = formatterCapture
        weak let weakResolverCapture = resolverCapture
        session.load(
            try AutoChartRequest(table: domainDataset()),
            formatters: AutoChartFormatters(request: { [formatterCapture] _, _, _ in
                formatterCapture?.increment()
                return nil
            }),
            textResolver: AutoChartTextResolver { [resolverCapture] message in
                resolverCapture?.increment()
                return message.defaultText
            })
        formatterCapture = nil
        resolverCapture = nil
        do {
            let presented = try await readyPresentation(from: session) { _ in true }
            #expect(weakFormatterCapture != nil)
            #expect(weakResolverCapture != nil)
            #expect((weakFormatterCapture?.value ?? 0) > 0)
            _ = presented.textResolver(AutoChartMessage(
                category: .rationale,
                code: .recommendationRationale,
                defaultText: "Loaded callback release test"))
            #expect((weakResolverCapture?.value ?? 0) > 0)
        }

        session.unload()
        #expect(session.presentationTextResolver.callbackIdentity == nil)
        #expect(weakFormatterCapture == nil)
        #expect(weakResolverCapture == nil)
    }

    @Test func unloadKeepsEnvironmentPresentationOverrides() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let environmentContext = AutoChartPresentationContext(identity: "environment")
        let environmentFormatters = AutoChartFormatters(
            cacheIdentity: "unload-environment-formatters",
            request: { _, _, _ in nil })
        let environmentResolver = AutoChartTextResolver(
            cacheIdentity: "unload-environment-resolver",
            { $0.defaultText })
        session.applyPresentationEnvironment(
            context: environmentContext,
            formatters: environmentFormatters,
            textResolver: environmentResolver)
        let loadedFormatters = AutoChartFormatters(
            cacheIdentity: "unload-loaded-formatters",
            request: { _, _, _ in nil })
        let loadedResolver = AutoChartTextResolver(
            cacheIdentity: "unload-loaded-resolver",
            { $0.defaultText })
        session.load(
            try AutoChartRequest(table: domainDataset()),
            formatters: loadedFormatters,
            textResolver: loadedResolver)
        let initial = try await readyPresentation(from: session) {
            $0.context.identity == environmentContext.identity
        }
        #expect(initial.formatters.callbackIdentity == environmentFormatters.callbackIdentity)
        #expect(initial.textResolver.callbackIdentity == environmentResolver.callbackIdentity)

        session.unload()

        let replacement = try AutoChartRequest(
            table: domainDataset(
                key: .trusted(identity: "unload-environment-replacement", revision: "1")))
        session.load(replacement)
        let presented = try await readyPresentation(from: session) {
            $0.context.identity == environmentContext.identity
        }
        #expect(presented.formatters.callbackIdentity == environmentFormatters.callbackIdentity)
        #expect(presented.textResolver.callbackIdentity == environmentResolver.callbackIdentity)
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable))
    func retryableFailureRetainsTheSelectedChoiceForSameTypeRetry()
        async throws
    {
        #if ATC_TEST_HOOKS
        let cache = AutoChartCache(configuration: .uncached)
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let session = AutoChartSession<Int>(cache: cache)
        defer { session.cancel() }
        session.load(request, preference: .chart(.specific(selected.id)))
        _ = try await readyAnalysis(from: session)
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
        guard case .analyzing = session.state else {
            Issue.record("The same selected type did not start uncached analysis.")
            return
        }
        #expect(session.currentRecommendation?.id == selected.id)
        session.failCurrentAttemptForTesting(AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.retryableFailure.directRetry",
            message: "A controlled direct-retry failure."))
        session.cancel()

        session.retry(preference: .chart(.specific(selected.id)))
        #expect(session.currentRecommendation?.id == selected.id)
        session.cancel()

        session.retry(preference: .table)
        #expect(session.currentRecommendation == nil)
        session.failCurrentAttemptForTesting(AutoChartFailure(
            stage: .recommendation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.changedPreferenceFailure",
            message: "A controlled changed-preference failure."))
        guard case .failed = session.state else {
            Issue.record("The changed-preference failure did not become visible.")
            return
        }
        #expect(session.currentRecommendation == nil)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func coldPreparationFailureRetainsRecommendationFromNewlyCachedAnalysis()
        async throws
    {
        #if ATC_TEST_HOOKS
        let fixture = try await makeV3OffCatalogFailureFixture(
            configuration: .standard,
            label: "cold-cache")
        defer { fixture.cleanUp() }

        fixture.session.load(
            fixture.request,
            preference: .chart(.specific(fixture.recommendation.id)))
        guard await fixture.preparationGate.waitUntilPaused() else {
            Issue.record("Cold preparation did not reach the failure gate.")
            return
        }
        #expect(
            fixture.cache.completedAnalysis(
                for: fixture.request.id, as: Int.self) != nil)
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        await fixture.preparationGate.open()

        let published = try await sessionFailure(from: fixture.session)
        #expect(published.diagnosticID == fixture.failure.diagnosticID)
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func cachedRetrySynchronouslyRetainsAnOffCatalogRecommendation() async throws {
        let dataset = try wideDomainDataset()
        let request = try AutoChartRequest(table: dataset)
        let cache = AutoChartCache()
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let catalog = try #require(base.outcome.catalog)
        let offCatalog = try offCatalogRecommendation(
            in: dataset, request: request, catalog: catalog)
        let session = AutoChartSession<Int>(cache: cache)
        defer { session.cancel() }

        session.load(
            request,
            preference: .chart(.specific(offCatalog.id)),
            preparation: .preferredOrPrimary)
        _ = try await readyAnalysis(from: session)
        #expect(session.currentRecommendation?.id == offCatalog.id)

        session.retry()

        guard case .preparing = session.state else {
            Issue.record("The cached retry did not begin preparation immediately.")
            return
        }
        #expect(session.currentRecommendation?.id == offCatalog.id)
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func uncachedPreparationFailureRetainsResolvedOffCatalogRecommendation()
        async throws
    {
        #if ATC_TEST_HOOKS
        let fixture = try await makeV3OffCatalogFailureFixture(
            label: "uncached-failure")
        defer { fixture.cleanUp() }

        fixture.session.load(
            fixture.request,
            preference: .chart(.specific(fixture.recommendation.id)))
        guard await fixture.preparationGate.waitUntilPaused() else {
            Issue.record("Off-catalog preparation did not reach its gate.")
            return
        }
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        await fixture.preparationGate.open()

        let published = try await sessionFailure(from: fixture.session)
        #expect(published.diagnosticID == fixture.failure.diagnosticID)
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        #expect(
            fixture.session.preference
                == .chart(.specific(fixture.recommendation.id)))
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)),
        arguments: V3SameRequestTransition.allCases)
    func uncachedRetryAndReloadRetainResolvedOffCatalogRecommendation(
        _ transition: V3SameRequestTransition
    ) async throws {
        #if ATC_TEST_HOOKS
        let fixture = try await makeV3OffCatalogFailureFixture(
            label: "pending-\(transition.label)")
        defer { fixture.cleanUp() }
        fixture.session.load(
            fixture.request,
            preference: .chart(.specific(fixture.recommendation.id)))
        guard await fixture.preparationGate.waitUntilPaused() else {
            Issue.record("Initial \(transition.label) preparation did not pause.")
            return
        }
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)

        switch transition {
        case .retry:
            fixture.session.retry()
        case .reload:
            fixture.session.load(
                fixture.request,
                preference: .chart(.specific(fixture.recommendation.id)))
        }
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        #expect(await waitForV3Condition {
            fixture.preparationStarts.value >= 2
        }, Comment(rawValue: transition.label))
        await fixture.preparationGate.open()

        let published = try await sessionFailure(from: fixture.session)
        #expect(
            published.diagnosticID == fixture.failure.diagnosticID,
            Comment(rawValue: transition.label))
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id,
            Comment(rawValue: transition.label))
        guard case .failed = fixture.session.state else {
            Issue.record("The \(transition.label) failure was not terminal.")
            return
        }
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func retryAfterCancelledFailureSynchronouslyRetainsResolvedRecommendation()
        async throws
    {
        #if ATC_TEST_HOOKS
        let fixture = try await makeV3OffCatalogFailureFixture(
            label: "cancelled-failure")
        defer { fixture.cleanUp() }
        fixture.session.load(
            fixture.request,
            preference: .chart(.specific(fixture.recommendation.id)))
        guard await fixture.preparationGate.waitUntilPaused() else {
            Issue.record("Cancelled-failure preparation did not pause.")
            return
        }
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        await fixture.preparationGate.open()
        _ = try await sessionFailure(from: fixture.session)
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)

        fixture.session.cancel()
        guard case .idle = fixture.session.state else {
            Issue.record("Cancelling the failure did not return the session to idle.")
            return
        }
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)

        fixture.session.retry()
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        let repeated = try await sessionFailure(from: fixture.session)
        #expect(repeated.diagnosticID == fixture.failure.diagnosticID)
        #expect(
            fixture.session.currentRecommendation?.id == fixture.recommendation.id)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func explicitRetryStartsNewEpisodesFromEveryNonidleState() async throws {
        #if ATC_TEST_HOOKS
        func controlledFailure(_ label: String) -> AutoChartFailure {
            AutoChartFailure(
                stage: .chartPreparation,
                kind: .internalFailure,
                isRetryable: true,
                diagnosticID: "ATC.test.explicitRetry.\(label)",
                message: "Controlled \(label) retry failure")
        }

        do {
            let calls = V3Counter()
            let failure = controlledFailure("ready")
            let cache = AutoChartCache(
                configuration: .init(
                    preparedCharts: .init(maximumEntries: 0)),
                testHooks: .chartPreparationByRecommendation { _ in
                    calls.increment()
                    if calls.value > 1 { throw failure }
                })
            let request = try AutoChartRequest(table: domainDataset())
            let base = try await AutoChartAnalyzer(cache: cache).analyze(
                request, preparation: .none)
            let selected = try #require(base.outcome.catalog?.primary)
            let session = AutoChartSession<Int>(cache: cache)
            session.load(
                request,
                preference: .chart(.specific(selected.id)),
                preparation: .preferredOrPrimary)
            _ = try await readyPresentation(from: session) { _ in true }
            let shared = cache.coalescedFailure(
                for: request.id,
                recommendationID: selected.id,
                error: failure,
                stage: .chartPreparation)

            session.retry()
            let retried = try await sessionFailure(from: session)
            #expect(retried.episodeID != shared.episodeID)
        }

        do {
            let failure = controlledFailure("fallback")
            let cache = AutoChartCache(
                configuration: .init(
                    preparedCharts: .init(maximumEntries: 0)),
                testHooks: .chartPreparationByRecommendation { _ in
                    throw failure
                })
            let request = try AutoChartRequest(table: domainDataset())
            let base = try await AutoChartAnalyzer(cache: cache).analyze(
                request, preparation: .none)
            let selected = try #require(base.outcome.catalog?.primary)
            let shared = cache.coalescedFailure(
                for: request.id,
                recommendationID: selected.id,
                error: failure,
                stage: .chartPreparation)
            let session = AutoChartSession<Int>(cache: cache)
            session.load(request, preference: .table)
            _ = try await fallbackAnalysis(from: session)

            session.retry(preference: .chart(.specific(selected.id)))
            let retried = try await sessionFailure(from: session)
            #expect(retried.episodeID != shared.episodeID)
        }

        for warm in [false, true] {
            let label = warm ? "preparing" : "analyzing"
            let gate = V3AsyncTestGate()
            let failure = controlledFailure(label)
            let cache = AutoChartCache(
                configuration: .init(
                    preparedCharts: .init(maximumEntries: 0)),
                testHooks: .chartPreparationByRecommendation { _ in
                    await gate.pause()
                    throw failure
                })
            let request = try AutoChartRequest(table: domainDataset())
            let catalogSource: AutoChartAnalysis<Int>
            if warm {
                catalogSource = try await AutoChartAnalyzer(cache: cache).analyze(
                    request, preparation: .none)
            } else {
                catalogSource = try await AutoChartAnalyzer().analyze(
                    request, preparation: .none)
            }
            let selected = try #require(catalogSource.outcome.catalog?.primary)
            let shared = cache.coalescedFailure(
                for: request.id,
                recommendationID: selected.id,
                error: failure,
                stage: .chartPreparation)
            let session = AutoChartSession<Int>(cache: cache)
            session.load(
                request,
                preference: .chart(.specific(selected.id)),
                preparation: .preferredOrPrimary)
            guard await gate.waitUntilPaused() else {
                session.cancel()
                await gate.release()
                Issue.record("The \(label) retry did not reach its test gate.")
                continue
            }
            if warm {
                guard case .preparing = session.state else {
                    session.cancel()
                    await gate.release()
                    Issue.record("The warm attempt was not preparing.")
                    continue
                }
            } else {
                guard case .analyzing = session.state else {
                    session.cancel()
                    await gate.release()
                    Issue.record("The cold attempt was not analyzing.")
                    continue
                }
            }

            session.retry()
            await gate.release()
            let retryClock = ContinuousClock()
            let retryDeadline = retryClock.now.advanced(by: .seconds(2))
            while retryClock.now < retryDeadline {
                if case .failed = session.state { break }
                if await gate.activePauseCount > 0 { await gate.release() }
                try? await Task.sleep(for: .milliseconds(1))
            }
            let retried = try await sessionFailure(from: session)
            #expect(retried.episodeID != shared.episodeID)
        }
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func pendingRecommendationTracksPreferenceThroughCancellationAndFailure()
        async throws
    {
        #if ATC_TEST_HOOKS
        let request = try AutoChartRequest(table: domainDataset())
        let catalogSource = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let primary = try #require(catalogSource.outcome.catalog?.primary)
        let alternative = try #require(
            catalogSource.outcome.catalog?.cataloged.first { $0.id != primary.id })
        let gate = V3AsyncTestGate()
        let replacementHooksFinished = V3Counter()
        let uncancelledReplacements = V3Counter()
        let cache = AutoChartCache(
            configuration: .uncached,
            testHooks: .chartPreparationByRecommendation { recommendationID in
                guard recommendationID == alternative.id else { return }
                defer { replacementHooksFinished.increment() }
                await gate.pause()
                try Task.checkCancellation()
                uncancelledReplacements.increment()
            })

        let cancelled = AutoChartSession<Int>(cache: cache)
        cancelled.load(
            request,
            preference: .chart(.specific(primary.id)),
            preparation: .preferredOrPrimary)
        let cancelledAnalysis = try await readyAnalysis(from: cancelled)
        let cancelledPresentation = try await readyPresentation(from: cancelled) { _ in true }
        #expect(cache.completedAnalysis(for: request.id, as: Int.self) == nil)
        cancelled.selection = cancelledPresentation.preparedChart.selections(
            for: [10], analysisID: cancelledAnalysis.id)
        cancelled.setPreference(.chart(.specific(alternative.id)))
        guard await gate.waitUntilPaused() else {
            cancelled.cancel()
            await gate.release()
            Issue.record("The cancellation case did not reach chart preparation.")
            return
        }
        guard case .ready(_, let stillVisible?) = cancelled.state else {
            cancelled.cancel()
            await gate.release()
            Issue.record("The previous chart must remain visible while replacing it.")
            return
        }
        #expect(stillVisible.requestID == cancelledPresentation.requestID)
        #expect(cancelled.currentRecommendation?.id == alternative.id)
        #expect(cancelled.isChartUpdatePending)

        cancelled.cancel()
        #expect(cancelled.currentRecommendation?.id == alternative.id)
        #expect(cancelled.selection.isEmpty)
        #expect(!cancelled.isChartUpdatePending)
        #expect(!cancelled.isPresentationPending)
        await gate.release()
        #expect(await waitForV3Condition {
            replacementHooksFinished.value == 1
        })
        #expect(uncancelledReplacements.value == 0)

        let failed = AutoChartSession<Int>(cache: cache)
        failed.load(
            request,
            preference: .chart(.specific(primary.id)),
            preparation: .preferredOrPrimary)
        let failedAnalysis = try await readyAnalysis(from: failed)
        let failedPresentation = try await readyPresentation(from: failed) { _ in true }
        failed.selection = failedPresentation.preparedChart.selections(
            for: [10], analysisID: failedAnalysis.id)
        failed.setPreference(.chart(.specific(alternative.id)))
        guard await gate.waitUntilPaused() else {
            failed.cancel()
            await gate.release()
            Issue.record("The failure case did not reach chart preparation.")
            return
        }
        #expect(failed.currentRecommendation?.id == alternative.id)
        failed.failCurrentAttemptForTesting(AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.pendingRecommendation",
            message: "Controlled pending-recommendation failure"))
        guard case .failed = failed.state else {
            await gate.release()
            Issue.record("The injected failure was not published.")
            return
        }
        #expect(failed.currentRecommendation?.id == alternative.id)
        #expect(failed.selection.isEmpty)
        #expect(!failed.isChartUpdatePending)
        #expect(!failed.isPresentationPending)
        await gate.release()
        #expect(await waitForV3Condition {
            replacementHooksFinished.value == 2
        })
        #expect(uncancelledReplacements.value == 0)
        guard case .failed = failed.state else {
            Issue.record("Cancelled replacement work replaced the terminal failure.")
            return
        }
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func reentrantAttemptHookReportsSupersededPreferenceApplication()
        async throws
    {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(
            analysis.outcome.catalog?.cataloged.first {
                $0.id != presented.preparedChart.recommendation.id
            })
        let calls = V3Counter()
        session.attemptDidStartForTesting = {
            calls.increment()
            #expect(session.preference == .chart(.specific(alternative.id)))
            #expect(session.isChartUpdatePending)
            session.setPreference(.table)
        }
        defer { session.attemptDidStartForTesting = nil }

        let application = session.applyPreference(
            .chart(.specific(alternative.id)))
        #expect(application == .superseded)
        _ = try await fallbackAnalysis(from: session)
        #expect(calls.value == 1)
        #expect(session.preference == .table)
        #expect(!session.isChartUpdatePending)
        #expect(!session.isPresentationPending)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func loadAttemptHookRunsAfterStateInstallation() throws {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let calls = V3Counter()
        session.attemptDidStartForTesting = {
            calls.increment()
            guard case .analyzing = session.state else {
                Issue.record("The load hook ran before analyzing state installation.")
                return
            }
        }
        defer {
            session.attemptDidStartForTesting = nil
            session.cancel()
        }

        session.load(try AutoChartRequest(table: domainDataset()))
        #expect(calls.value == 1)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func selectionObserverCannotShareAReplacementGeneration() async throws {
        #if ATC_TEST_HOOKS
        let request = try AutoChartRequest(table: domainDataset())
        let catalogSource = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let catalog = try #require(catalogSource.outcome.catalog)
        let primary = try #require(catalog.primary)
        let alternative = try #require(catalog.cataloged.first {
            $0.id != primary.id
        })
        let preparationGate = V3AsyncTestGate()
        let preparationStarts = V3Counter()
        let cache = AutoChartCache(
            testHooks: .chartPreparationByRecommendation { recommendationID in
                guard recommendationID == alternative.id else { return }
                preparationStarts.increment()
                await preparationGate.pause()
            })
        let session = AutoChartSession<Int>(cache: cache)
        defer {
            session.cancel()
            Task { await preparationGate.open() }
        }
        session.load(request)
        let initial = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.cancel()
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: initial.id)
        #expect(!session.selection.isEmpty)

        let observation = V3ObservationLoop()
        let innerApplication = V3LockedBox<AutoChartPreferenceApplication>()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            innerApplication.store(session.applyPreference(.table))
        }

        let outerApplication = session.applyPreference(
            .chart(.specific(alternative.id)))
        #expect(innerApplication.value == .startedReplacement)
        #expect(outerApplication == .superseded)
        #expect(session.preference == .table)
        _ = try await fallbackAnalysis(from: session)
        #expect(preparationStarts.value == 0)
        #expect(await preparationGate.activePauseCount == 0)
        #endif
    }

    @Test func preferenceObserverCancellationSupersedesStartAndReuse() async throws {
        for preparation in [
            AutoChartPreparationStrategy.preferredOrPrimary,
            .allCataloged,
        ] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset())
            #expect(session.load(request, preparation: preparation) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let alternative = try #require(
                analysis.outcome.catalog?.cataloged.first {
                    $0.id != presented.preparedChart.recommendation.id
                })
            let observation = V3ObservationLoop()
            observation.track {
                _ = session.preference
            } onChange: {
                observation.cancel()
                session.cancel()
            }

            let application = session.applyPreference(
                .chart(.specific(alternative.id)))

            #expect(application == .superseded)
            guard case .idle = session.state else {
                Issue.record("Preference-observer cancellation was overwritten.")
                continue
            }
            #expect(!session.isChartUpdatePending)
            #expect(!session.isPresentationPending)
            try? await Task.sleep(for: .milliseconds(25))
            guard case .idle = session.state else {
                Issue.record("Superseded preference work later republished state.")
                continue
            }
        }
    }

    @Test func preferenceObserverLatestPreferenceWins() async throws {
        for preparation in [
            AutoChartPreparationStrategy.preferredOrPrimary,
            .allCataloged,
        ] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset())
            #expect(session.load(request, preparation: preparation) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let alternative = try #require(
                analysis.outcome.catalog?.cataloged.first {
                    $0.id != presented.preparedChart.recommendation.id
                })
            let observation = V3ObservationLoop()
            let innerApplication = V3LockedBox<AutoChartPreferenceApplication>()
            observation.track {
                _ = session.preference
            } onChange: {
                observation.cancel()
                innerApplication.store(session.applyPreference(.table))
            }

            let outerApplication = session.applyPreference(
                .chart(.specific(alternative.id)))

            #expect(outerApplication == .superseded)
            #expect(innerApplication.value == .startedReplacement)
            #expect(session.preference == .table)
            _ = try await fallbackAnalysis(from: session)
        }
    }

    @Test func cancelAndUnloadYieldToSelectionObserverReplacement() async throws {
        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset())
            #expect(session.load(request) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let alternative = try #require(
                analysis.outcome.catalog?.cataloged.first {
                    $0.id != presented.preparedChart.recommendation.id
                })
            session.selection = presented.preparedChart.selections(
                for: [10], analysisID: analysis.id)
            let observation = V3ObservationLoop()
            let innerApplication = V3LockedBox<AutoChartPreferenceApplication>()
            observation.track {
                _ = session.selection
            } onChange: {
                observation.cancel()
                innerApplication.store(session.applyPreference(
                    .chart(.specific(alternative.id))))
            }

            if unloads {
                session.unload()
            } else {
                session.cancel()
            }

            #expect(innerApplication.value == .startedReplacement)
            let finalPresentation = try await readyPresentation(from: session) {
                $0.preparedChart.recommendation.id == alternative.id
            }
            let final = try await readyAnalysis(from: session)
            #expect(final.request == request.id)
            #expect(final.primaryChart?.id == finalPresentation.preparedChart.id)
        }
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func failurePublicationYieldsToSelectionObserverReplacement() async throws {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request) == .started)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(
            analysis.outcome.catalog?.cataloged.first {
                $0.id != presented.preparedChart.recommendation.id
            })
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: analysis.id)
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            session.setPreference(.chart(.specific(alternative.id)))
        }

        session.failCurrentAttemptForTesting(AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.reentrantFailurePublication",
            message: "Controlled reentrant failure"))

        let finalPresentation = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        let final = try await readyAnalysis(from: session)
        #expect(final.primaryChart?.id == finalPresentation.preparedChart.id)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func supersededFailurePublicationDoesNotMarkCancelledAttemptFailed() async throws {
        #if ATC_TEST_HOOKS
        let attempts = V3Counter()
        let controlledFailure = AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.supersededFailureEpisode",
            message: "Controlled superseded failure")
        let cache = AutoChartCache(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { _ in
                attempts.increment()
                if attempts.value > 1 { throw controlledFailure }
            })
        let session = AutoChartSession<Int>(cache: cache)
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request, preparation: .primary) == .started)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: analysis.id)
        let sharedFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: presented.preparedChart.recommendation.id,
            error: controlledFailure,
            stage: .chartPreparation)
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            session.cancel()
        }

        session.failCurrentAttemptForTesting(sharedFailure)

        guard case .idle = session.state else {
            Issue.record("Reentrant cancellation did not supersede failure publication.")
            return
        }
        #expect(session.retry() == .started)
        let retriedFailure = try await sessionFailure(from: session)
        #expect(retriedFailure.episodeID == sharedFailure.episodeID)
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func contextSupersessionKeepsFailureMetadataTransactional() async throws {
        #if ATC_TEST_HOOKS
        let attempts = V3Counter()
        let controlledFailure = AutoChartFailure(
            stage: .chartPreparation,
            kind: .internalFailure,
            isRetryable: true,
            diagnosticID: "ATC.test.contextSupersededFailure",
            message: "Controlled context-superseded failure")
        let cache = AutoChartCache(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { _ in
                attempts.increment()
                if attempts.value > 1 { throw controlledFailure }
            })
        let session = AutoChartSession<Int>(cache: cache)
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request, preparation: .primary) == .started)
        _ = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let sharedFailure = cache.coalescedFailure(
            for: request.id,
            recommendationID: presented.preparedChart.recommendation.id,
            error: controlledFailure,
            stage: .chartPreparation)
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.state
        } onChange: {
            observation.cancel()
            session.setPresentationContext(.init(identity: "failure-superseder"))
        }

        session.failCurrentAttemptForTesting(sharedFailure)

        _ = try await readyPresentation(from: session) {
            $0.context.identity == "failure-superseder"
        }
        session.cancel()
        #expect(session.retry() == .started)
        let retriedFailure = try await sessionFailure(from: session)
        #expect(retriedFailure.episodeID == sharedFailure.episodeID)
        #endif
    }

    @Test func loadReportsReentrancyAndKeepsWinningConfiguration() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let initialRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "load-result-initial", revision: "1")))
        #expect(session.load(
            initialRequest,
            presentationContext: .init(identity: "initial")) == .started)
        let initial = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: initial.id)
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            session.cancel()
        }
        let supersededRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "load-result-superseded", revision: "1")))

        let result = session.load(
            supersededRequest,
            presentationContext: .init(identity: "superseded"))

        #expect(result == .superseded)
        guard case .idle = session.state else {
            Issue.record("A superseded load overwrote cancellation.")
            return
        }
        session.retry()
        let restored = try await readyPresentation(from: session) {
            $0.context.identity == "initial"
        }
        #expect(restored.context.identity == "initial")
    }

    @Test func supersededPresentationContextPersistsForRetry() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(
            request,
            presentationContext: .init(identity: "initial")) == .started)
        _ = try await readyPresentation(from: session) {
            $0.context.identity == "initial"
        }
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.state
        } onChange: {
            observation.cancel()
            session.cancel()
        }

        session.setPresentationContext(.init(identity: "retained"))

        guard case .idle = session.state else {
            Issue.record("Context rebuilding did not yield to cancellation.")
            return
        }
        #expect(session.retry() == .started)
        let retried = try await readyPresentation(from: session) {
            $0.context.identity == "retained"
        }
        #expect(retried.context.identity == "retained")
    }

    @Test func nestedPresentationContextWins() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(
            request,
            presentationContext: .init(identity: "initial")) == .started)
        _ = try await readyPresentation(from: session) {
            $0.context.identity == "initial"
        }
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.state
        } onChange: {
            observation.cancel()
            session.setPresentationContext(.init(identity: "nested"))
        }

        session.setPresentationContext(.init(identity: "superseded"))

        let nested = try await readyPresentation(from: session) {
            $0.context.identity == "nested"
        }
        #expect(nested.context.identity == "nested")
    }

    @Test func loadReportsReentrantUnloadAsSuperseded() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let initialRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "load-unload-initial", revision: "1")))
        #expect(session.load(initialRequest) == .started)
        let initial = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: initial.id)
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            session.unload()
        }
        let supersededRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "load-unload-superseded", revision: "1")))

        let result = session.load(supersededRequest)

        #expect(result == .superseded)
        guard case .idle = session.state else {
            Issue.record("A superseded load overwrote unload.")
            return
        }
        #expect(session.applyPreference(.table) == .stored)
    }

    @Test func nestedLoadWinsSelectionClearAndKeepsItsConfiguration() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let initialRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "nested-load-initial", revision: "1")))
        #expect(session.load(initialRequest) == .started)
        let initial = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: initial.id)
        let outerRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "nested-load-outer", revision: "1")))
        let innerRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "nested-load-inner", revision: "1")))
        let observation = V3ObservationLoop()
        let innerResult = V3LockedBox<AutoChartLoadApplication>()
        observation.track {
            _ = session.selection
        } onChange: {
            observation.cancel()
            innerResult.store(session.load(
                innerRequest,
                presentationContext: .init(identity: "winner")))
        }

        let outerResult = session.load(
            outerRequest,
            presentationContext: .init(identity: "loser"))

        #expect(outerResult == .superseded)
        #expect(innerResult.value == .started)
        let final = try await readyAnalysis(from: session)
        let finalPresentation = try await readyPresentation(from: session) {
            $0.context.identity == "winner"
        }
        #expect(final.request == innerRequest.id)
        #expect(finalPresentation.context.identity == "winner")
    }

    @Test func synchronousPresentationSelectionClearYieldsToCancelAndUnload()
        async throws
    {
        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset())
            #expect(session.load(request, preparation: .allCataloged) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let foreignChart = try #require(analysis.preparedCharts.values.first {
                $0.id != presented.preparedChart.id
            })
            session.selection = foreignChart.selections(
                for: [10], analysisID: analysis.id)
            let observation = V3ObservationLoop()
            observation.track {
                _ = session.selection
            } onChange: {
                observation.cancel()
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            let application = session.applyPreference(.chart(.recommended))

            #expect(application == .superseded)
            guard case .idle = session.state else {
                Issue.record("Synchronous presentation publication undid cancellation or unload.")
                continue
            }
            #expect(!session.isPresentationPending)
            #expect(!session.isChartUpdatePending)
            if unloads {
                #expect(session.applyPreference(.table) == .stored)
            }
        }
    }

    @Test func matchingPresentationRebuildPublishesSelectionClear() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request, preparation: .allCataloged) == .started)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let foreignChart = try #require(analysis.preparedCharts.values.first {
            $0.id != presented.preparedChart.id
        })
        session.selection = foreignChart.selections(
            for: [10], analysisID: analysis.id)
        let changes = V3Counter()
        let observation = V3ObservationLoop()
        observation.track {
            _ = session.selection
        } onChange: {
            changes.increment()
            observation.cancel()
        }

        session.setPresentationContext(presented.context)

        #expect(session.selection.isEmpty)
        #expect(changes.value == 1)
    }

    @Test func presentationRebuildPublishesReentrantSelectionClear() async throws {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request, preparation: .allCataloged) == .started)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let foreignChart = try #require(analysis.preparedCharts.values.first {
            $0.id != presented.preparedChart.id
        })
        session.selection = presented.preparedChart.selections(
            for: [10], analysisID: analysis.id)
        let selectionChanges = V3Counter()
        let selectionObservation = V3ObservationLoop()
        selectionObservation.track {
            _ = session.selection
        } onChange: {
            selectionChanges.increment()
            if selectionChanges.value == 2 {
                selectionObservation.cancel()
            }
        }
        let stateObservation = V3ObservationLoop()
        stateObservation.track {
            _ = session.state
        } onChange: {
            stateObservation.cancel()
            session.selection = foreignChart.selections(
                for: [10], analysisID: analysis.id)
        }

        session.setPresentationContext(presented.context)

        selectionObservation.cancel()
        #expect(session.selection.isEmpty)
        #expect(selectionChanges.value == 2)
    }

    @Test func asynchronousPresentationSelectionClearYieldsToCancelAndUnload()
        async throws
    {
        for unloads in [false, true] {
            let callback = V3OneShotBlockingCallback(startsArmed: false)
            defer { callback.release() }
            let formatters = AutoChartFormatters(
                cacheIdentity: "reentrant-presentation-\(unloads)",
                request: { _, _, _ in callback.invoke(); return nil })
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset())
            #expect(session.load(
                request,
                preparation: .allCataloged,
                formatters: formatters) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let alternative = try #require(
                analysis.outcome.catalog?.cataloged.first {
                    $0.id != presented.preparedChart.recommendation.id
                })
            session.selection = presented.preparedChart.selections(
                for: [10], analysisID: analysis.id)
            callback.arm()
            #expect(session.applyPreference(
                .chart(.specific(alternative.id))) == .reusedPreparedChart)
            #expect(await waitForV3Condition {
                callback.isBlocked && session.isPresentationPending
            })
            let observation = V3ObservationLoop()
            observation.track {
                _ = session.selection
            } onChange: {
                observation.cancel()
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            callback.release()

            #expect(await waitForV3Condition {
                if case .idle = session.state { return true }
                return false
            })
            #expect(!session.isPresentationPending)
            #expect(!session.isChartUpdatePending)
            try? await Task.sleep(for: .milliseconds(25))
            guard case .idle = session.state else {
                Issue.record("Presentation completion republished after cancellation.")
                continue
            }
            if unloads {
                #expect(session.applyPreference(.table) == .stored)
            }
        }
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func synchronousCancellationAndUnloadReportSuperseded() async throws {
        #if ATC_TEST_HOOKS
        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer {
                session.attemptDidStartForTesting = nil
                session.cancel()
            }
            let request = try AutoChartRequest(table: domainDataset())
            session.load(request)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            let alternative = try #require(
                analysis.outcome.catalog?.cataloged.first {
                    $0.id != presented.preparedChart.recommendation.id
                })
            session.attemptDidStartForTesting = { [weak session] in
                guard let session else { return }
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            let application = session.applyPreference(
                .chart(.specific(alternative.id)))
            #expect(application == .superseded)
            guard case .idle = session.state else {
                Issue.record("Synchronous cancellation did not leave idle state.")
                continue
            }
            #expect(!session.isChartUpdatePending)
            #expect(!session.isPresentationPending)
            session.attemptDidStartForTesting = nil
            if unloads {
                #expect(session.applyPreference(.table) == .stored)
            }
        }
        #endif
    }

    @Test func retryReportsNoRequestStartedAndSynchronousSupersession()
        async throws
    {
        let empty = AutoChartSession<Int>(cache: AutoChartCache())
        #expect(empty.retry() == .noRequest)
        #expect(empty.retry(preference: .table) == .noRequest)

        let started = AutoChartSession<Int>(cache: AutoChartCache())
        defer { started.cancel() }
        let startedRequest = try AutoChartRequest(table: domainDataset(
            key: .trusted(identity: "retry-started", revision: "1")))
        #expect(started.load(startedRequest) == .started)
        _ = try await readyPresentation(from: started) { _ in true }
        #expect(started.retry(preference: .automatic) == .started)

        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer { session.cancel() }
            let request = try AutoChartRequest(table: domainDataset(
                key: .trusted(
                    identity: "retry-superseded-\(unloads)",
                    revision: "1")))
            #expect(session.load(request) == .started)
            let analysis = try await readyAnalysis(from: session)
            let presented = try await readyPresentation(from: session) { _ in true }
            session.selection = presented.preparedChart.selections(
                for: [10], analysisID: analysis.id)
            let observation = V3ObservationLoop()
            observation.track {
                _ = session.selection
            } onChange: {
                observation.cancel()
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            #expect(session.retry() == .superseded)
            guard case .idle = session.state else {
                Issue.record("Superseded retry did not leave the session idle.")
                continue
            }
            if unloads {
                #expect(session.retry() == .noRequest)
            }
        }
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func retryAttemptHookReportsSynchronousCancellationAndUnload() async throws {
        #if ATC_TEST_HOOKS
        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer {
                session.attemptDidStartForTesting = nil
                session.cancel()
            }
            let request = try AutoChartRequest(table: domainDataset(
                key: .trusted(
                    identity: "retry-hook-superseded-\(unloads)",
                    revision: "1")))
            #expect(session.load(request) == .started)
            _ = try await readyPresentation(from: session) { _ in true }
            session.attemptDidStartForTesting = { [weak session] in
                guard let session else { return }
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            #expect(session.retry() == .superseded)
            guard case .idle = session.state else {
                Issue.record("Attempt-hook supersession did not leave the session idle.")
                continue
            }
            if unloads {
                #expect(session.retry() == .noRequest)
            }
        }
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
        let cold = try await makeV3PreparationGateFixture(warm: false)
        let coldSession = AutoChartSession<Int>(cache: cold.cache)
        coldSession.load(cold.request, preparation: .primary)
        guard await cold.gate.waitUntilPaused() else {
            coldSession.cancel()
            await cold.gate.release()
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
            await cold.gate.release()
            Issue.record("Cold chart preparation must remain in analyzing mode.")
            return
        }
        #expect(coldProgress?.phase == .chartPreparation)
        await cold.gate.release()
        _ = try await readyAnalysis(from: coldSession)

        let warm = try await makeV3PreparationGateFixture(warm: true)
        let progressToken = warm.cache.registerProgress(for: warm.request.id) { _ in }
        warm.cache.reportProgress(
            AutoChartProgress(phase: .recommendation),
            for: warm.request.id,
            fallback: nil)

        let warmSession = AutoChartSession<Int>(cache: warm.cache)
        warmSession.load(warm.request, preparation: .primary)
        guard await warm.gate.waitUntilPaused() else {
            warmSession.cancel()
            await warm.gate.release()
            warm.cache.unregisterProgress(for: warm.request.id, token: progressToken)
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
            await warm.gate.release()
            warm.cache.unregisterProgress(for: warm.request.id, token: progressToken)
            Issue.record("Replayed analysis progress must not regress warm preparation.")
            return
        }
        #expect(warmProgress?.phase == .chartPreparation)
        let unexpectedStateChanges = V3Counter()
        let observation = V3ObservationLoop()
        observation.track {
            _ = warmSession.state
        } onChange: {
            unexpectedStateChanges.increment()
            observation.cancel()
            warmSession.cancel()
        }
        warm.cache.reportProgress(
            AutoChartProgress(phase: .recommendation),
            for: warm.request.id,
            fallback: nil)
        try? await Task.sleep(for: .milliseconds(25))
        observation.cancel()
        #expect(unexpectedStateChanges.value == 0)
        guard case .preparing = warmSession.state else {
            await warm.gate.release()
            warm.cache.unregisterProgress(for: warm.request.id, token: progressToken)
            Issue.record("Irrelevant warm progress changed session state.")
            return
        }
        await warm.gate.release()
        warm.cache.unregisterProgress(for: warm.request.id, token: progressToken)
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

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func reentrantEnvironmentApplicationKeepsTheNewestOverrides() async throws {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer {
            session.environmentApplicationForTesting = nil
            session.cancel()
        }
        let request = try AutoChartRequest(table: domainDataset())
        #expect(session.load(request) == .started)
        _ = try await readyPresentation(from: session) { _ in true }
        var installedNestedOverrides = false
        session.environmentApplicationForTesting = { [weak session] in
            guard !installedNestedOverrides, let session else { return }
            installedNestedOverrides = true
            session.applyPresentationEnvironment(
                context: .init(identity: "environment-winner"),
                formatters: nil,
                textResolver: nil)
        }

        session.applyPresentationEnvironment(
            context: .init(identity: "environment-loser"),
            formatters: nil,
            textResolver: nil)

        let presented = try await readyPresentation(from: session) {
            $0.context.identity == "environment-winner"
        }
        #expect(installedNestedOverrides)
        #expect(presented.context.identity == "environment-winner")
        #endif
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func supersededEnvironmentApplicationRetainsOverrides() async throws {
        #if ATC_TEST_HOOKS
        for unloads in [false, true] {
            let session = AutoChartSession<Int>(cache: AutoChartCache())
            defer {
                session.environmentApplicationForTesting = nil
                session.cancel()
            }
            let request = try AutoChartRequest(table: domainDataset(
                key: .trusted(
                    identity: "environment-supersession-\(unloads)",
                    revision: "1")))
            #expect(session.load(request) == .started)
            _ = try await readyPresentation(from: session) { _ in true }
            var didSupersede = false
            session.environmentApplicationForTesting = { [weak session] in
                guard !didSupersede, let session else { return }
                didSupersede = true
                if unloads {
                    session.unload()
                } else {
                    session.cancel()
                }
            }

            session.applyPresentationEnvironment(
                context: .init(identity: "retained-environment"),
                formatters: nil,
                textResolver: nil)

            session.environmentApplicationForTesting = nil
            guard case .idle = session.state else {
                Issue.record("Environment supersession did not leave the session idle.")
                continue
            }
            if unloads {
                let replacement = try AutoChartRequest(table: domainDataset(
                    key: .trusted(
                        identity: "environment-replacement",
                        revision: "1")))
                #expect(session.load(replacement) == .started)
            } else {
                #expect(session.retry() == .started)
            }
            let presented = try await readyPresentation(from: session) {
                $0.context.identity == "retained-environment"
            }
            #expect(didSupersede)
            #expect(presented.context.identity == "retained-environment")
        }
        #endif
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

        let application = session.applyPreference(.chart(.specific(alternative.id)))
        #expect(application == .reusedPreparedChart)
        _ = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        let updated = try await readyAnalysis(from: session)
        #expect(updated.id == initial.id)
        #expect(updated.primaryChart?.recommendation.id == alternative.id)
        #expect(updated.preparedCharts.count == catalog.cataloged.count)
    }

    @Test func preferenceSetterRetainsVoidFunctionCompatibility() {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let setter: (AutoChartPreference) -> Void = session.setPreference
        setter(.table)
        #expect(session.preference == .table)
        setter(.table)
        #expect(session.preference == .table)
    }

    @Test func lifecycleEntryPointsRetainResultFunctionShapes() {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let storedPreferenceLoad: @MainActor (
            AutoChartRequest<Int>,
            AutoChartPreparationStrategy,
            AutoChartPresentationContext,
            AutoChartFormatters?,
            AutoChartTextResolver
        ) -> AutoChartLoadApplication = session.load
        let explicitPreferenceLoad: @MainActor (
            AutoChartRequest<Int>,
            AutoChartPreference,
            AutoChartPreparationStrategy,
            AutoChartPresentationContext,
            AutoChartFormatters?,
            AutoChartTextResolver
        ) -> AutoChartLoadApplication = session.load
        let storedPreferenceRetry: @MainActor () -> AutoChartRetryApplication =
            session.retry
        let explicitPreferenceRetry: @MainActor (
            AutoChartPreference
        ) -> AutoChartRetryApplication = session.retry

        _ = storedPreferenceLoad
        _ = explicitPreferenceLoad
        #expect(storedPreferenceRetry() == .noRequest)
        #expect(explicitPreferenceRetry(.table) == .noRequest)
    }

    @Test func preferenceApplicationReportsLifecycleOutcomes() async throws {
        let unloaded = AutoChartSession<Int>(cache: AutoChartCache())
        #expect(unloaded.applyPreference(.table) == .stored)
        #expect(unloaded.applyPreference(.table) == .unchanged)
        #expect(unloaded.preference == .table)

        let request = try AutoChartRequest(table: domainDataset())
        let cached = AutoChartSession<Int>(cache: AutoChartCache())
        cached.load(request)
        let cachedAnalysis = try await readyAnalysis(from: cached)
        let cachedPresentation = try await readyPresentation(from: cached) {
            _ in true
        }
        let alternative = try #require(
            cachedAnalysis.outcome.catalog?.cataloged.first {
                $0.id != cachedPresentation.preparedChart.recommendation.id
            })
        #expect(
            cached.applyPreference(.chart(.specific(alternative.id)))
                == .startedReplacement)
        _ = try await readyPresentation(from: cached) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        #expect(
            cached.applyPreference(.chart(.specific(alternative.id)))
                == .unchanged)
        #expect(cached.applyPreference(.table) == .startedReplacement)
        _ = try await fallbackAnalysis(from: cached)
    }

    @Test func initialPresentationReusesItsPreparedChart() async throws {
        let cache = AutoChartCache()
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let recommendation = try #require(base.outcome.catalog?.primary)
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "initial-presentation-reuse",
            request: { _, _, _ in callback.invoke(); return nil })
        let session = AutoChartSession<Int>(cache: cache)

        session.load(request, formatters: formatters)
        #expect(await waitForV3Condition { callback.isBlocked })
        guard case .preparing(let pending, let progress) = session.state else {
            Issue.record("Initial presentation did not remain in preparing state.")
            return
        }
        #expect(progress?.phase == .presentationPreparation)
        #expect(pending.primaryChart?.recommendation.id == recommendation.id)

        let application = session.applyPreference(
            .chart(.specific(recommendation.id)))
        #expect(application == .reusedPreparedChart)
        #expect(session.isPresentationPending)
        guard case .preparing(let updated, _) = session.state else {
            Issue.record("Prepared-chart reuse restarted initial presentation work.")
            return
        }
        #expect(updated.preferenceResolution?.recommendation?.id == recommendation.id)

        callback.release()
        _ = try await readyPresentation(from: session) {
            $0.requestID.formatterCallback == formatters.callbackIdentity
        }
        let final = try await readyAnalysis(from: session)
        #expect(final.preferenceResolution?.recommendation?.id == recommendation.id)
    }

    @Test func reusedDifferentChartKeepsVisibleAnalysisPaired() async throws {
        let callback = V3OneShotBlockingCallback(startsArmed: false)
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "paired-reused-chart",
            request: { _, _, _ in callback.invoke(); return nil })
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(
            request,
            preparation: .allCataloged,
            formatters: formatters)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        let alternative = try #require(initial.outcome.catalog?.cataloged.first {
            $0.id != original.preparedChart.recommendation.id
        })

        callback.arm()
        #expect(
            session.applyPreference(.chart(.specific(alternative.id)))
                == .reusedPreparedChart)
        #expect(await waitForV3Condition {
            callback.isBlocked && session.isPresentationPending
        })
        guard case .ready(let visibleAnalysis, let stillVisible?) = session.state else {
            Issue.record("Prepared-chart reuse did not keep the visible pair ready.")
            return
        }
        #expect(visibleAnalysis.primaryChart?.id == original.preparedChart.id)
        #expect(stillVisible.preparedChart.id == original.preparedChart.id)
        #expect(session.currentRecommendation?.id == alternative.id)
        #expect(session.isChartUpdatePending)

        callback.release()
        let replacement = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == alternative.id
        }
        let final = try await readyAnalysis(from: session)
        #expect(final.primaryChart?.id == replacement.preparedChart.id)
        #expect(final.preferenceResolution?.recommendation?.id == alternative.id)
    }

    @Test func sameOffCatalogPolicyRebindReusesPreparedChart() async throws {
        let dataset = try wideDomainDataset()
        let request = try AutoChartRequest(table: dataset)
        let source = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let catalog = try #require(source.outcome.catalog)
        let selected = try offCatalogRecommendation(
            in: dataset, request: request, catalog: catalog)
        let stale = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
            specificationID: selected.specification.id)
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        defer { session.cancel() }

        session.load(
            request,
            preference: .chart(.specific(stale)),
            preparation: .preferredOrPrimary)
        let initial = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        session.selection = presented.preparedChart.selections(
            for: [0], analysisID: initial.id)
        let savedSelection = session.selection

        let application = session.applyPreference(
            .chart(.specific(selected.id)))

        #expect(application == .reusedPreparedChart)
        guard case .ready(let updated, let unchanged?) = session.state else {
            Issue.record("The off-catalog rebind must remain ready synchronously.")
            return
        }
        #expect(updated.id == initial.id)
        #expect(updated.primaryChart?.id == presented.preparedChart.id)
        #expect(unchanged.requestID == presented.requestID)
        #expect(session.selection == savedSelection)
        #expect(session.preference == .chart(.specific(selected.id)))
        #expect(updated.preferenceResolution?.recommendation?.id == selected.id)
        #expect(updated.preferenceResolution?.replacementPreference == nil)
        #expect(!session.isChartUpdatePending)
        #expect(!session.isPresentationPending)
    }

    @Test func visiblePreparedChartWinsOverEquivalentPendingInstance()
        async throws
    {
        let dataset = try wideDomainDataset()
        let request = try AutoChartRequest(table: dataset)
        let source = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let catalog = try #require(source.outcome.catalog)
        let offCatalog = try offCatalogRecommendation(
            in: dataset, request: request, catalog: catalog)
        let callback = V3OneShotBlockingCallback(startsArmed: false)
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "visible-chart-priority",
            request: { _, _, _ in callback.invoke(); return nil })
        let cache = AutoChartCache(configuration: AutoChartAnalyzerConfiguration(
            preparedCharts: .init(maximumEntries: 1)))
        let session = AutoChartSession<Int>(cache: cache)
        defer { session.cancel() }
        #expect(session.load(
            request,
            preparation: .allCataloged,
            formatters: formatters) == .started)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }
        session.selection = original.preparedChart.selections(
            for: [0], analysisID: initial.id)
        let savedSelection = session.selection

        callback.arm()
        #expect(session.applyPreference(
            .chart(.specific(offCatalog.id))) == .startedReplacement)
        #expect(await waitForV3Condition {
            callback.isBlocked && session.isPresentationPending
        })

        #expect(session.applyPreference(
            .chart(.recommended)) == .reusedPreparedChart)
        guard case .ready(let restored, let unchanged?) = session.state else {
            Issue.record("Visible prepared chart was not restored synchronously.")
            return
        }
        #expect(restored.primaryChart?.id == original.preparedChart.id)
        #expect(unchanged.requestID == original.requestID)
        #expect(session.selection == savedSelection)
        #expect(!session.isPresentationPending)
        #expect(!session.isChartUpdatePending)

        callback.release()
        try? await Task.sleep(for: .milliseconds(25))
        guard case .ready(_, let final?) = session.state else {
            Issue.record("Cancelled pending presentation replaced the visible chart.")
            return
        }
        #expect(final.requestID == original.requestID)
        #expect(session.selection == savedSelection)
    }

    @Test func pendingPresentationTargetIsReusedForEquivalentPreference()
        async throws
    {
        let request = try AutoChartRequest(table: domainDataset())
        let source = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let catalog = try #require(source.outcome.catalog)
        let primary = try #require(catalog.primary)
        let initialChoice = try #require(catalog.cataloged.first {
            $0.id != primary.id
        })
        let callback = V3OneShotBlockingCallback(startsArmed: false)
        defer { callback.release() }
        let formatters = AutoChartFormatters(
            cacheIdentity: "pending-target-reuse",
            request: { _, _, _ in callback.invoke(); return nil })
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(
            request,
            preference: .chart(.specific(initialChoice.id)),
            formatters: formatters)
        let initial = try await readyAnalysis(from: session)
        let original = try await readyPresentation(from: session) { _ in true }

        callback.arm()
        #expect(session.applyPreference(.automatic) == .startedReplacement)
        #expect(await waitForV3Condition {
            callback.isBlocked && session.isPresentationPending
        })
        #expect(
            session.applyPreference(.chart(.recommended))
                == .reusedPreparedChart)
        guard case .ready(let visibleAnalysis, let stillVisible?) = session.state else {
            Issue.record("Pending-target reuse did not retain the visible chart.")
            return
        }
        #expect(visibleAnalysis.id == initial.id)
        #expect(visibleAnalysis.primaryChart?.id == original.preparedChart.id)
        #expect(stillVisible.preparedChart.id == original.preparedChart.id)
        #expect(session.currentRecommendation?.id == primary.id)
        #expect(session.isPresentationPending)

        callback.release()
        let finalPresentation = try await readyPresentation(from: session) {
            $0.preparedChart.recommendation.id == primary.id
        }
        let final = try await readyAnalysis(from: session)
        #expect(final.primaryChart?.id == finalPresentation.preparedChart.id)
        #expect(final.preferenceResolution?.defaultReason == .recommended)
        #expect(session.preference == .chart(.recommended))
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func changedPreferenceStartsReplacementFromAnalyzingAndPreparing()
        async throws
    {
        #if ATC_TEST_HOOKS
        for warm in [false, true] {
            let fixture = try await makeV3PreparationGateFixture(warm: warm)
            let session = AutoChartSession<Int>(cache: fixture.cache)
            session.load(fixture.request, preparation: .primary)
            guard await fixture.gate.waitUntilPaused() else {
                session.cancel()
                await fixture.gate.release()
                Issue.record("The source attempt did not reach its preparation gate.")
                continue
            }
            #expect(hasExpectedV3PreparationState(session, warm: warm))
            #expect(session.applyPreference(.table) == .startedReplacement)
            await fixture.gate.release()
            _ = try await fallbackAnalysis(from: session)
            #expect(session.preference == .table)
        }
        #endif
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
    func samePreferenceDoesNotRestartAnalyzingOrPreparingWork() async throws {
        #if ATC_TEST_HOOKS
        try await verifySamePreferenceDoesNotRestartPreparation(warm: false)
        try await verifySamePreferenceDoesNotRestartPreparation(warm: true)
        #endif
    }

    @Test func samePreferenceDoesNotRestartTerminalOrCancelledStates()
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
            Issue.record("Same ready preference changed session state.")
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
            Issue.record("Same fallback preference restarted analysis.")
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
            Issue.record("Same failed preference started another attempt.")
            return
        }
        #expect(unchangedFailure.episodeID == failure.episodeID)

        readySession.cancel()
        readySession.setPreference(readySession.preference)
        guard case .idle = readySession.state else {
            Issue.record("Same preference restarted a cancelled session.")
            return
        }
        #expect(readySession.applyPreference(.table) == .startedReplacement)
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
            Issue.record("The same preference must keep the ready chart visible.")
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

        let application = session.applyPreference(.chart(.specific(selected.id)))
        #expect(application == .reusedPreparedChart)
        guard case .ready(let updated, let unchanged?) = session.state else {
            Issue.record("A policy-only rebind must remain ready synchronously.")
            return
        }
        #expect(unchanged.requestID == presented.requestID)
        #expect(updated.preferenceResolution?.recommendation?.id == selected.id)
        #expect(updated.preferenceResolution?.replacementPreference == nil)
        #expect(session.selection == presented.preparedChart.selections(for: [10], analysisID: ready.id))
    }

    @Test func cacheTrimForcesSameChartPreferenceRestart() async throws {
        let cache = AutoChartCache()
        let session = AutoChartSession<Int>(cache: cache)
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        let analysis = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        await cache.trim(to: .minimum)

        let application = session.applyPreference(.chart(.specific(
            presented.preparedChart.recommendation.id)))
        #expect(application == .startedReplacement)
        #expect(session.isChartUpdatePending)
        _ = try await readyPresentation(from: session) {
            $0.preparedChart.id != presented.preparedChart.id
        }
        #expect((try await readyAnalysis(from: session)).id != analysis.id)
    }

    @Test func offCatalogPreferenceReportsRestartEvenWhenItFallsBackToVisibleChart()
        async throws
    {
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        _ = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let unavailable = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "off-catalog-restart"))

        let application = session.applyPreference(.chart(.specific(unavailable)))
        #expect(application == .startedReplacement)
        #expect(session.isChartUpdatePending)
        #expect(await waitForV3Condition { !session.isChartUpdatePending })
        guard case .ready(_, let final?) = session.state else {
            Issue.record("The off-catalog restart did not return to a ready chart.")
            return
        }
        #expect(final.preparedChart.recommendation.id
            == presented.preparedChart.recommendation.id)
    }

    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func revertingPreferenceCancelsPendingRecommendationResolution() async throws {
        #if ATC_TEST_HOOKS
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        let request = try AutoChartRequest(table: domainDataset())
        session.load(request)
        _ = try await readyAnalysis(from: session)
        let presented = try await readyPresentation(from: session) { _ in true }
        let unavailable = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "pending-recommendation-reversion"))

        #expect(
            session.applyPreference(.chart(.specific(unavailable)))
                == .startedReplacement)
        #expect(session.hasRecommendationTaskForTesting)
        #expect(
            session.applyPreference(.chart(.specific(
                presented.preparedChart.recommendation.id)))
                == .reusedPreparedChart)
        #expect(!session.hasRecommendationTaskForTesting)
        #expect(!session.isChartUpdatePending)
        guard case .ready(_, let final?) = session.state else {
            Issue.record("Reverting the preference did not preserve the ready chart.")
            return
        }
        #expect(final.requestID == presented.requestID)
        #endif
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
        #expect(session.isChartUpdatePending)

        let application = session.applyPreference(
            .chart(.specific(recommendation.id)))
        #expect(application == .reusedPreparedChart)
        guard case .ready(let updated, let stillVisible?) = session.state else {
            Issue.record("The ready chart must remain visible during presentation.")
            return
        }
        #expect(stillVisible.requestID == original.requestID)
        #expect(updated.preferenceResolution?.recommendation?.id == recommendation.id)
        #expect(session.isPresentationPending)
        #expect(session.isChartUpdatePending)
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
        #expect(session.currentRecommendation == nil)
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

    @MainActor
    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func ordinaryPostFailureTransitionsJoinUnobservedEpisodes() async throws {
        #if ATC_TEST_HOOKS
        for usesLoad in [false, true] {
            let transition = usesLoad ? "load" : "setPreference"
            let request = try AutoChartRequest(table: domainDataset())
            let cache = AutoChartCache(
                configuration: .init(
                    preparedCharts: .init(maximumEntries: 0)),
                testHooks: .chartPreparationByRecommendation { _ in
                    throw AutoChartFailure(
                        stage: .chartPreparation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.test.unobservedEpisode.\(transition)",
                        message: "Controlled \(transition) preparation failure")
                })
            let base = try await AutoChartAnalyzer(cache: cache).analyze(
                request, preparation: .none)
            let first = try #require(base.outcome.catalog?.primary)
            let second = try #require(
                base.outcome.catalog?.cataloged.first { $0.id != first.id })
            let firstSession = AutoChartSession<Int>(cache: cache)
            let secondSession = AutoChartSession<Int>(cache: cache)

            secondSession.load(
                request,
                preference: .chart(.specific(second.id)),
                preparation: .preferredOrPrimary)
            let secondEpisode = try await sessionFailure(from: secondSession)
            firstSession.load(
                request,
                preference: .chart(.specific(first.id)),
                preparation: .preferredOrPrimary)
            let firstEpisode = try await sessionFailure(from: firstSession)
            #expect(
                firstEpisode.episodeID != secondEpisode.episodeID,
                Comment(rawValue: transition))

            if usesLoad {
                firstSession.load(
                    request,
                    preference: .chart(.specific(second.id)),
                    preparation: .preferredOrPrimary)
            } else {
                firstSession.setPreference(.chart(.specific(second.id)))
            }
            let joined = try await sessionFailure(from: firstSession)
            #expect(
                joined.episodeID == secondEpisode.episodeID,
                Comment(rawValue: transition))

            let freshSession = AutoChartSession<Int>(cache: cache)
            freshSession.load(
                request,
                preference: .chart(.specific(second.id)),
                preparation: .preferredOrPrimary)
            let fresh = try await sessionFailure(from: freshSession)
            #expect(
                fresh.episodeID == secondEpisode.episodeID,
                Comment(rawValue: transition))
            guard case .failed(let stillVisible) = secondSession.state else {
                Issue.record("The original \(transition) observer lost its failure.")
                continue
            }
            #expect(
                stillVisible.episodeID == secondEpisode.episodeID,
                Comment(rawValue: transition))
        }
        #endif
    }

    @MainActor
    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func retryAfterCancelledFailureRestartsUnobservedScopes() async throws {
        #if ATC_TEST_HOOKS
        let request = try AutoChartRequest(table: domainDataset())
        let catalogSource = try await AutoChartAnalyzer().analyze(
            request, preparation: .none)
        let first = try #require(catalogSource.outcome.catalog?.primary)
        let second = try #require(
            catalogSource.outcome.catalog?.cataloged.first { $0.id != first.id })
        let firstAttempts = V3Counter()
        let cache = AutoChartCache(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { recommendationID in
                if recommendationID == first.id {
                    firstAttempts.increment()
                    if firstAttempts.value == 1 {
                        throw AutoChartFailure(
                            stage: .chartPreparation,
                            kind: .internalFailure,
                            isRetryable: true,
                            diagnosticID: "ATC.test.cancelledFailure.first",
                            message: "Controlled first-scope failure")
                    }
                } else if recommendationID == second.id {
                    throw AutoChartFailure(
                        stage: .chartPreparation,
                        kind: .internalFailure,
                        isRetryable: true,
                        diagnosticID: "ATC.test.cancelledFailure.second",
                        message: "Controlled second-scope failure")
                }
            })
        let retainedSecond = cache.coalescedFailure(
            for: request.id,
            recommendationID: second.id,
            error: AutoChartFailure(
                stage: .chartPreparation,
                kind: .internalFailure,
                isRetryable: true,
                diagnosticID: "ATC.test.cancelledFailure.second",
                message: "Controlled second-scope failure"),
            stage: .chartPreparation)
        let session = AutoChartSession<Int>(cache: cache)

        session.load(request, preparation: .allCataloged)
        _ = try await sessionFailure(from: session)
        session.cancel()
        session.retry()
        let retried = try await sessionFailure(from: session)

        #expect(firstAttempts.value == 2)
        #expect(retried.diagnosticID == "ATC.test.cancelledFailure.second")
        #expect(retried.episodeID != retainedSecond.episodeID)
        #endif
    }

    @MainActor
    @Test(
        .disabled(if: !testHooksAvailable, testHooksUnavailable),
        .timeLimit(.minutes(1)))
    func concurrentSessionRetriesShareOneNewFailureEpisode() async throws {
        #if ATC_TEST_HOOKS
        let gate = V3AsyncTestGate()
        let cache = AutoChartCache(
            configuration: .init(
                preparedCharts: .init(maximumEntries: 0)),
            testHooks: .chartPreparationByRecommendation { _ in
                await gate.pause()
                throw AutoChartFailure(
                    stage: .chartPreparation,
                    kind: .internalFailure,
                    isRetryable: true,
                    diagnosticID: "ATC.test.concurrentSessionRetry",
                    message: "Controlled concurrent-retry failure")
            })
        let request = try AutoChartRequest(table: domainDataset())
        let base = try await AutoChartAnalyzer(cache: cache).analyze(
            request, preparation: .none)
        let selected = try #require(base.outcome.catalog?.primary)
        let firstSession = AutoChartSession<Int>(cache: cache)
        let secondSession = AutoChartSession<Int>(cache: cache)

        firstSession.load(
            request,
            preference: .chart(.specific(selected.id)),
            preparation: .preferredOrPrimary)
        secondSession.load(
            request,
            preference: .chart(.specific(selected.id)),
            preparation: .preferredOrPrimary)
        guard await gate.waitUntilPaused() else {
            firstSession.cancel()
            secondSession.cancel()
            await gate.release()
            Issue.record("The initial shared failure did not reach its gate.")
            return
        }
        await gate.release()
        let initialFirst = try await sessionFailure(from: firstSession)
        let initialSecond = try await sessionFailure(from: secondSession)
        #expect(initialFirst.episodeID == initialSecond.episodeID)

        firstSession.retry()
        secondSession.retry()
        guard await gate.waitUntilPaused() else {
            firstSession.cancel()
            secondSession.cancel()
            await gate.release()
            Issue.record("The concurrent retries did not reach their gate.")
            return
        }
        await gate.release()
        let retriedFirst = try await sessionFailure(from: firstSession)
        let retriedSecond = try await sessionFailure(from: secondSession)
        #expect(retriedFirst.episodeID != initialFirst.episodeID)
        #expect(retriedFirst.episodeID == retriedSecond.episodeID)

        firstSession.retry()
        guard await gate.waitUntilPaused() else {
            firstSession.cancel()
            secondSession.cancel()
            await gate.release()
            Issue.record("The sequential retry did not reach its gate.")
            return
        }
        await gate.release()
        let sequential = try await sessionFailure(from: firstSession)
        #expect(sequential.episodeID != retriedFirst.episodeID)
        #endif
    }

    @Test func everyNewAttemptAfterFailureStartsANewFailureEpisode()
        async throws
    {
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

        session.cancel()
        session.retry()
        let resumedFailure = try await sessionFailure(from: session)
        #expect(resumedFailure.episodeID != fourth.episodeID)
        #expect(session.preference == .chart(.recommended))

        session.setPreference(.table)
        let preferenceFailure = try await sessionFailure(from: session)
        #expect(preferenceFailure.episodeID != resumedFailure.episodeID)
        #expect(session.preference == .table)

        session.load(request, preference: .automatic)
        let reloadedFailure = try await sessionFailure(from: session)
        #expect(reloadedFailure.episodeID != preferenceFailure.episodeID)
        #expect(session.preference == .automatic)

        session.load(try AutoChartRequest(table: domainDataset()))
        let ready = try await readyAnalysis(from: session)
        let retainedRecommendation = try #require(session.currentRecommendation)
        session.cancel()
        guard case .idle = session.state else {
            Issue.record("Cancellation must return the session to idle.")
            return
        }
        #expect(session.currentRecommendation?.id == retainedRecommendation.id)
        await Task.yield()
        guard case .idle = session.state else {
            Issue.record("Cancelled work must not publish a failure.")
            return
        }

        session.retry()
        #expect(session.currentRecommendation?.id == retainedRecommendation.id)
        let resumed = try await readyAnalysis(from: session)
        #expect(resumed.id == ready.id)
        #expect(session.preference == .automatic)
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
