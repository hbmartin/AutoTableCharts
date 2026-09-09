# Getting Started

Build a typed dataset, create an identity-bearing request, and analyze it through a shared cache.

## Overview

### Build immutable input

``AutoChartDataset`` is the shortest path from query-style rows to the package.
This initializer uses source offsets as `Int` row IDs:

```swift
let dataset = try AutoChartDataset<Int>(
    columns: [
        AutoChartColumn(
            id: "propertyType", name: "Property Type",
            semantics: .dimension(semanticType: .nominal)),
        AutoChartColumn(
            id: "marketValue", name: "Market Value",
            semantics: .measure(
                semanticType: .quantitative,
                unit: .currency(code: "USD"),
                semantics: .init(
                    source: .aggregated(.sum),
                    rollup: .additive,
                    preferredTransform: .sum))),
    ],
    rows: [
        [.text("Office"), .double(18_000_000)],
        [.text("Industrial"), .double(14_500_000)],
    ],
    metadata: .init(grain: "property type"),
    key: .trusted(identity: "portfolio-summary", revision: "2026-08-20"))
```

Use the explicit-row-ID initializer for UUIDs, database keys, or other domain
identities. Dataset initialization throws ``AutoChartDatasetError`` rather than
silently fixing malformed matrices or duplicate IDs.

### Analyze through shared package state

Keep one ``AutoChartCache`` at the application or feature scope where analyzers
and UI sessions should share reuse. Create a request whose identity includes the
data contract, context, options, constraints, and recommendation policy version:

```swift
let cache = AutoChartCache()
let analyzer = AutoChartAnalyzer(cache: cache)
let request = try AutoChartRequest(
    table: dataset,
    context: .init(goal: .comparison),
    options: .init(includesDecisionTrace: true))
let analysis = try await analyzer.analyze(
    request,
    preference: .automatic,
    preparation: .preferredOrPrimary)
```

Analysis includes a process-scoped identity and request identity, exact retained
cost, summarized public column profiles, typed diagnostics, an optional full
decision trace, a bounded recommendation catalog, preference resolution, and
the charts selected by the preparation strategy.

### Adopt the UI product

```swift
import AutoTableChartsUI

let session = AutoChartSession<Int>(cache: cache)
session.load(request, preference: .automatic)
```

`AutoChartSession` owns supersession, cancellation, preference-aware
preparation, warm-cache adoption, retries, and alternative selection. Use
`AutoChartSessionView` for package defaults or switch on session state to retain
an existing table and failure UI.

### Prepare an alternative

```swift
.task(id: selectedRecommendationID) {
    guard let id = selectedRecommendationID else { return }
    selection = nil
    preparedChart = try? await analysis.prepare(id)
}
```

The UI session performs this cancellable work with `session.select(id)`.

See <doc:SafetySemanticsAndCompleteness> for measure contracts. The
`AutoTableChartsUI` documentation covers presentation and interaction.

### Migrate to v3

Version 3 replaces optional cache keys with explicit trusted or
content-addressed modes, recommendation arrays with catalogs, mutable family
encodings with associated-value specifications, contradictory hints with
``AutoChartColumnSemantics``, and scattered lifecycle errors with
``AutoChartFailure``. It is intentionally source breaking and has no v2 facade.
