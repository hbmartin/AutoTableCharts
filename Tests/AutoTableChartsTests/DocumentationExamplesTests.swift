import AutoTableCharts
import Testing

#if canImport(SwiftUI)
import SwiftUI
#endif

private struct DocumentationHoldingRow: AutoChartRow {
    let id: String
    let propertyType: String
    let marketValue: Double

    var chartRowID: AutoChartRowID { AutoChartRowID(rawValue: id) }

    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
        switch columnID {
        case "propertyType": .text(propertyType)
        case "marketValue": .double(marketValue)
        default: .null
        }
    }
}

private struct DocumentationHoldingsTable: AutoChartTable {
    let chartRows: [DocumentationHoldingRow]

    let chartColumns: [AutoChartColumn] = [
        AutoChartColumn(
            id: "propertyType",
            name: "Property Type",
            hints: AutoChartColumnHints(
                semanticType: .nominal,
                role: .dimension
            )
        ),
        AutoChartColumn(
            id: "marketValue",
            name: "Current Market Value",
            hints: AutoChartColumnHints(
                semanticType: .quantitative,
                role: .measure,
                unit: .currency(code: "USD"),
                aggregation: .sum,
                aggregationSafety: .alreadyAggregated
            )
        ),
    ]

    let chartMetadata = AutoChartTableMetadata(
        grain: "property type",
        provenance: "documentation fixture"
    )
}

@Suite struct DocumentationExamplesTests {
    @Test func gettingStartedExampleCompilesEndToEnd() async throws {
        let table = DocumentationHoldingsTable(chartRows: [
            DocumentationHoldingRow(id: "office", propertyType: "Office", marketValue: 20),
            DocumentationHoldingRow(id: "retail", propertyType: "Retail", marketValue: 10),
            DocumentationHoldingRow(
                id: "industrial", propertyType: "Industrial", marketValue: 15),
        ])

        let result = AutoChartEngine.recommendations(
            for: table,
            context: AutoChartContext(
                goal: .comparison,
                title: "Current Market Value by Property Type"
            )
        )
        let recommendation = try #require(result.chartRecommendations.first)
        #expect(recommendation.specification.family == .bar)

        let specification = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "propertyType", y: "marketValue"),
            aggregation: .none,
            orientation: .horizontal,
            sort: .descending,
            title: "Property Types by Market Value"
        )
        let validation = AutoChartEngine.validate(specification: specification, for: table)
        #expect(validation.isValid)

        let selection = AutoChartSelection(
            sourceRowIDs: ["office"],
            label: "Office",
            valueDescription: "$20"
        )
        #expect(selection.sourceRowIDs == ["office"])

        #if canImport(SwiftUI) && canImport(Charts)
        await MainActor.run {
            let view = AutoChartView(
                table: table,
                recommendation: recommendation,
                selection: Binding<AutoChartSelection?>.constant(selection),
                interaction: .explore
            )
            _ = view
        }
        #endif
    }
}
