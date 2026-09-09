# ``AutoTableCharts``

Turn typed tabular results into safe, immutable chart recommendations.

## Overview

AutoTableCharts snapshots and validates caller data, profiles every column,
generates semantically safe candidates, and prepares only the charts requested
by an explicit strategy. The package is deterministic and offline: it does not
sample rows, invoke a model, or mutate a table. The separate
`AutoTableChartsUI` product provides SwiftUI and Swift Charts integration.

```swift
let cache = AutoChartCache()
let analyzer = AutoChartAnalyzer(cache: cache)
let request = try AutoChartRequest(
    table: dataset,
    context: AutoChartContext(goal: .comparison))
let analysis = try await analyzer.analyze(
    request,
    preference: .automatic,
    preparation: .preferredOrPrimary)
```

Retain ``AutoChartCache`` at the scope where analyzers and sessions should share
reuse. An ``AutoChartAnalysis`` remains usable after the cache is trimmed.

## Topics

### Start Here

- <doc:GettingStarted>
- <doc:ModelingTypedTables>
- <doc:GeneratingRecommendations>
- <doc:CustomSpecifications>

### Input and Meaning

- ``AutoChartDataset``
- ``AutoChartTable``
- ``AutoChartRow``
- ``AutoChartColumn``
- ``AutoChartColumnSemantics``
- ``AutoChartMeasureSemantics``
- ``AutoChartTableMetadata``

### Analysis and Preparation

- <doc:PreparedAnalysisAndCaching>
- <doc:OutcomesAndResolution>
- ``AutoChartAnalyzer``
- ``AutoChartCache``
- ``AutoChartRequest``
- ``AutoChartAnalysis``
- ``AutoChartRecommendationOutcome``
- ``AutoChartRecommendationCatalog``
- ``AutoChartRecommendation``
- ``AutoChartPreparedChart``
- ``AutoChartColumnProfile``
- ``AutoChartDecisionTrace``

### Formatting and Selection Models

- ``AutoChartFormatters``
- ``AutoChartFormattingRequest``
- ``AutoChartFormattingPurpose``
- ``AutoChartAppliedAggregation``
- ``AutoChartSelection``
- ``AutoChartSelectionSet``
- ``AutoChartTextResolver``

### Design

- <doc:ChartFamilyReference>
- <doc:RecommendationPipeline>
- <doc:SafetySemanticsAndCompleteness>
- <doc:ResearchFoundations>
