# ``AutoTableCharts``

Turn typed tabular results into deterministic, semantically safe native Swift Charts.

## Overview

AutoTableCharts profiles the rows you already have, generates chart candidates,
rejects candidates that could change the result's meaning, ranks the remaining
choices for an analytical goal, and renders them with Swift Charts. The package
runs offline, has no model or service dependency, doesn't sample rows, and never
mutates consumer-owned table storage.

Start by adapting your table and row types to ``AutoChartTable`` and
``AutoChartRow``. Then call ``AutoChartEngine/recommendations(for:context:options:)``
and present a result with ``AutoChartView``.

```swift
let result = AutoChartEngine.recommendations(
    for: table,
    context: AutoChartContext(goal: .comparison)
)

if let recommendation = result.chartRecommendations.first {
    AutoChartView(table: table, recommendation: recommendation)
}
```

Recommendation is conservative by design. Identifiers aren't measures,
ambiguous aggregation isn't invented, and incomplete results don't produce
totals or composition charts. When no chart is safe, the engine returns an
explicit table fallback.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ModelingTypedTables>
- <doc:GeneratingRecommendations>
- <doc:RenderingAndInteraction>
- <doc:CustomSpecifications>

### Behavior and Design

- <doc:ChartFamilyReference>
- <doc:RecommendationPipeline>
- <doc:SafetySemanticsAndCompleteness>
- <doc:ResearchFoundations>

### Table Input

- ``AutoChartTable``
- ``AutoChartRow``
- ``AutoChartColumn``
- ``AutoChartColumnHints``
- ``AutoChartTableMetadata``
- ``AutoChartValue``

### Recommendation

- ``AutoChartEngine``
- ``AutoChartContext``
- ``AutoChartOptions``
- ``AutoChartRecommendationSet``
- ``AutoChartRecommendation``

### Specifications and Validation

- ``AutoChartSpecification``
- ``AutoChartEncoding``
- ``AutoChartFamily``
- ``AutoChartAggregation``
- ``AutoChartValidationResult``

### Rendering and Selection

- ``AutoChartView``
- ``AutoChartInteraction``
- ``AutoChartSelection``

