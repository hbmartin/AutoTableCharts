import AutoTableCharts
import Testing

#if canImport(SwiftUI)
import SwiftUI
#endif

private struct DocumentationHoldingRow: AutoChartRow {
    let id: String
    let propertyType: String
    let marketValue: Double

    var chartRowID: String { id }

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
                measureSemantics: AutoChartMeasureSemantics(
                    source: .rowLevel,
                    rollup: .additive
                )
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

        let analyzer = AutoChartAnalyzer()
        let analysis = try await analyzer.analyze(
            table,
            context: AutoChartContext(
                goal: .comparison,
                title: "Current Market Value by Property Type"
            )
        )
        let primary = try #require(analysis.primaryChart)
        #expect(primary.recommendation.specification.family == .bar)

        let specification = AutoChartSpecification(
            family: .bar,
            encoding: AutoChartEncoding(x: "propertyType", y: "marketValue"),
            aggregation: .none,
            orientation: .horizontal,
            sort: .descending,
            title: "Property Types by Market Value"
        )
        #expect(analysis.validate(specification).isValid)
        let customChart = try await analysis.prepare(specification)

        let selection = AutoChartSelection(
            sourceRowIDs: ["office"],
            dimensions: [
                AutoChartSelectedDimension(columnID: "propertyType", value: .text("Office"))
            ],
            measure: AutoChartSelectedMeasure(
                columnID: "marketValue",
                aggregation: .none,
                value: .scalar(.double(20))),
            family: .bar,
            specificationID: specification.id,
            markID: "office"
        )
        #expect(selection.sourceRowIDs == ["office"])

        #if canImport(SwiftUI) && canImport(Charts)
        await MainActor.run {
            let view = AutoChartView(
                preparedChart: customChart,
                selection: Binding<AutoChartSelection<String>?>.constant(selection),
                presentation: .explorer(plotHeight: 280)
            )
            _ = view
        }
        #endif
    }
}
