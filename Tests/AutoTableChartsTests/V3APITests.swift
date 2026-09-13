import Dispatch
import Foundation
import SwiftUI
import Testing

@testable import AutoTableCharts
@testable import AutoTableChartsUI

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
    private var blocked = false
    private var timedOut = false

    init(blockedInvocation: Int = 1) {
        self.blockedInvocation = blockedInvocation
    }

    var isBlocked: Bool { lock.withLock { blocked } }
    var completedInvocations: Int { lock.withLock { completedInvocationCount } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func invoke() {
        let shouldBlock = lock.withLock {
            invocationCount += 1
            return invocationCount == blockedInvocation
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

    func recordCurrentThread() {
        lock.withLock {
            callbackCount += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var result: (count: Int, observedMainThread: Bool) {
        lock.withLock { (callbackCount, observedMainThread) }
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
        #expect(options.count == 50)
        #expect(options.allSatisfy { $0.label.hasPrefix("localized:") })
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

        let prepared = try await analyzer.analyze(
            request,
            preference: .chart(.specific(offList.id)),
            preparation: .allCataloged)
        #expect(prepared.primaryChart?.recommendation.id == offList.id)
        #expect(prepared.outcome.catalog?.preferred?.id == offList.id)
        #expect(prepared.preparedCharts.count == catalog.cataloged.count + 1)

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
            policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
            specificationID: primary.specification.id)
        let staleResolution = analysis.resolve(.chart(.specific(stale)))
        #expect(staleResolution.defaultReason == .policyVersionChanged(
            previous: stale.policyVersion,
            current: AutoTableCharts.recommendationPolicyVersion))
        #expect(staleResolution.replacementPreference == .chart(.recommended))

        let missing = AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: .init(rawValue: "missing"))
        let missingResolution = analysis.resolve(.chart(.specific(missing)))
        #expect(missingResolution.defaultReason == .specificationUnavailable)
        #expect(missingResolution.replacementPreference == .chart(.recommended))
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

    @Test func presentationContextPreservesAutoupdatingFoundationValues() throws {
        let context = AutoChartPresentationContext(
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent)
        #expect(context.locale == Locale.autoupdatingCurrent)
        #expect(context.timeZone == TimeZone.autoupdatingCurrent)
        #expect(context.locale != Locale(identifier: context.localeIdentifier))
        #expect(context.timeZone != TimeZone(identifier: context.timeZoneIdentifier))

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
        let firstID = AutoChartPresentationRequestID(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v1"),
            formatters: formatters,
            textResolver: .default)
        let identicalID = AutoChartPresentationRequestID(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v1"),
            formatters: formatters,
            textResolver: .default)
        let invalidatedID = AutoChartPresentationRequestID(
            preparedChart: chart.id,
            context: .init(identity: "convenience-v2"),
            formatters: formatters,
            textResolver: .default)
        #expect(firstID == identicalID)
        #expect(firstID != invalidatedID)
        #expect(firstID.context.foundation.localeIdentifier == firstID.context.localeIdentifier)
        #expect(firstID.context.foundation.usesAutoupdatingLocale)
        #expect(firstID.context.foundation.fixedLocale == nil)
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
}

@MainActor
@Suite struct V3SessionTests {
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

    @Test func cancelledProgressRestartsDoNotInvokeQueuedResolver() async {
        let callback = V3OneShotBlockingCallback()
        defer { callback.release() }
        let resolver = AutoChartTextResolver { message in
            callback.invoke()
            return message.defaultText
        }
        let first = Task {
            await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.preparing,
                using: resolver)
        }

        guard await waitForV3Condition({ callback.isBlocked }) else {
            first.cancel()
            Issue.record("The first progress resolver did not begin.")
            return
        }
        first.cancel()
        #expect(await first.value == nil)

        let secondStarted = V3Counter()
        let second = Task {
            secondStarted.increment()
            return await AutoChartProgressTextResolution.resolve(
                AutoChartProgressAccessibility.updating,
                using: resolver)
        }
        guard await waitForV3Condition({ secondStarted.value == 1 }) else {
            second.cancel()
            Issue.record("The replacement progress resolution did not begin.")
            return
        }
        second.cancel()
        #expect(await second.value == nil)

        callback.release()
        #expect(await waitForV3Condition({ callback.completedInvocations == 1 }))
        #expect(callback.completedInvocations == 1)
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
        let updated = try await readyAnalysis(from: session)
        #expect(updated.primaryChart?.recommendation.id == alternative.id)
        #expect(updated.preparedCharts.count == catalog.cataloged.count)
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

        session.setPreference(.table)
        let fallback = try await fallbackAnalysis(from: session)
        #expect(fallback.id == ready.id)
        #expect(fallback.primaryChart == nil)

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
