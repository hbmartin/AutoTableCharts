# Getting Started

Adapt a typed table, request recommendations, and render the best safe chart.

## Overview

### Add the package

AutoTableCharts requires Swift 6.2. Native Swift Charts rendering supports iOS
17, macOS 14, tvOS 17, and watchOS 10 or later. The Foundation-only typed models,
recommendation, and validation APIs also build on Linux. Until
the package has a versioned release, add the repository's `main` branch in Xcode
or Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/hbmartin/AutoTableCharts.git",
        branch: "main"
    )
]
```

Add `AutoTableCharts` to the target that presents charts, then import the module
alongside SwiftUI.

### Describe rows

Your existing row type can conform without copying or changing its storage.
Expose a stable ID and translate values into ``AutoChartValue``.

```swift
import AutoTableCharts
import Foundation

struct HoldingRow: AutoChartRow {
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
```

### Describe the table

Column hints carry meaning that can't always be recovered from values alone.
The market value below is explicitly quantitative, denominated in USD, and
already summed at the result grain, so summing it across unique categories is
safe.

```swift
struct HoldingsTable: AutoChartTable {
    let chartRows: [HoldingRow]

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
        provenance: "portfolio summary"
    )
}
```

### Recommend and render

Generate recommendations once for the table and analytical goal. The result is
deterministic for equal inputs.

```swift
import SwiftUI

struct HoldingsChart: View {
    let table: HoldingsTable
    @State private var selection: AutoChartSelection?

    private var recommendation: AutoChartRecommendation? {
        AutoChartEngine.recommendations(
            for: table,
            context: AutoChartContext(
                goal: .comparison,
                title: "Current Market Value by Property Type"
            )
        ).chartRecommendations.first
    }

    var body: some View {
        if let recommendation {
            AutoChartView(
                table: table,
                recommendation: recommendation,
                selection: $selection,
                interaction: .explore
            )
        } else {
            Text("No safe chart is available.")
        }
    }
}
```

The selection contains every source-row ID represented by the selected mark,
including grouped values and histogram bins. See <doc:RenderingAndInteraction>
for linked-selection behavior and <doc:SafetySemanticsAndCompleteness> for the
metadata that controls conservative fallbacks.
