import Foundation
import Testing
@testable import AutoTableCharts
@testable import AutoTableChartsUI

private struct SessionRetryRow: AutoChartRow {
    let chartRowID: Int
    let category: String
    let value: Double

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        columnID == "category" ? .text(category) : .double(value)
    }
}

private struct SessionRetryTable: AutoChartTable {
    let chartRows: [SessionRetryRow]
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

@MainActor
@Suite struct SessionRetryTests {
    @Test func retryCanChangePreferenceInTheSameAttempt() async throws {
        let invalid = SessionRetryTable(
            chartRows: [
                SessionRetryRow(chartRowID: 1, category: "A", value: 1),
                SessionRetryRow(chartRowID: 1, category: "B", value: 2),
            ],
            chartDataKey: .trusted(
                identity: "session-invalid-preference",
                revision: "1"))
        let session = AutoChartSession<Int>(cache: AutoChartCache())
        session.load(try AutoChartRequest(table: invalid))
        let first = try await failure(from: session)

        session.retry(preference: .chart(.recommended))

        let second = try await failure(from: session)
        #expect(second.episodeID != first.episodeID)
        #expect(session.preference == .chart(.recommended))
    }

    private func failure(
        from session: AutoChartSession<Int>
    ) async throws -> AutoChartFailure {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if case .failed(let failure) = session.state { return failure }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SessionRetryTestError.timedOut
    }
}

private enum SessionRetryTestError: Error {
    case timedOut
}
