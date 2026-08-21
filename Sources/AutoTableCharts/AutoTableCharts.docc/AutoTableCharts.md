# ``AutoTableCharts``

Turn typed tabular results into immutable prepared native Swift Charts.

## Overview

AutoTableCharts snapshots and validates caller data, profiles every column,
generates semantically safe candidates, and eagerly prepares the primary chart.
The package is deterministic and offline: it does not sample rows, invoke a
model, mutate a table, or own application-global state.

```swift
let analyzer = AutoChartAnalyzer()
let analysis = try await analyzer.analyze(
    dataset,
    context: AutoChartContext(goal: .comparison))

if let primary = analysis.primaryChart {
    AutoChartView(preparedChart: primary)
}
```

Retain the analyzer at the scope where reuse should occur and retain each
``AutoChartAnalysis`` in async view state. An analysis remains usable after the
analyzer is trimmed or cleared.

## Topics

### Start Here

- <doc:GettingStarted>
- <doc:ModelingTypedTables>
- <doc:GeneratingRecommendations>
- <doc:RenderingAndInteraction>
- <doc:CustomSpecifications>

### Input and Meaning

- ``AutoChartDataset``
- ``AutoChartTable``
- ``AutoChartRow``
- ``AutoChartColumn``
- ``AutoChartColumnHints``
- ``AutoChartMeasureSemantics``
- ``AutoChartTableMetadata``

### Analysis and Preparation

- <doc:PreparedAnalysisAndCaching>
- <doc:OutcomesAndResolution>
- ``AutoChartAnalyzer``
- ``AutoChartAnalysis``
- ``AutoChartRecommendationOutcome``
- ``AutoChartRecommendation``
- ``AutoChartPreparedChart``
- ``AutoChartColumnProfile``
- ``AutoChartDecisionTrace``

### Rendering and Presentation

- ``AutoChartView``
- ``AutoChartPlot``
- ``AutoChartPresentation``
- ``AutoChartFormatters``
- ``AutoChartSelection``
- ``AutoChartTextResolver``

### Design

- <doc:ChartFamilyReference>
- <doc:RecommendationPipeline>
- <doc:SafetySemanticsAndCompleteness>
- <doc:ResearchFoundations>
