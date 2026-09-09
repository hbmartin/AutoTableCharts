# Generating Recommendations

Inspect typed outcomes, rationales, diagnostics, profiles, and optional decisions.

## Overview

``AutoChartAnalyzer/analyze(_:preference:preparation:progress:)`` accepts an
identity-bearing ``AutoChartRequest`` and returns an immutable
``AutoChartAnalysis``. The context goal affects ranking but never bypasses hard
validation. Options bound visual density without sampling supplied rows, while
``AutoChartRecommendationConstraints`` filter candidate families and columns
before expensive validation.

```swift
let request = try AutoChartRequest(
    table: dataset,
    context: AutoChartContext(goal: .trend, title: "Monthly Revenue"),
    options: AutoChartOptions(includesDecisionTrace: true))
let analysis = try await analyzer.analyze(
    request,
    preference: .automatic,
    preparation: .preferredOrPrimary)
```

Switch on the outcome:

```swift
switch analysis.outcome {
case .charts(let catalog):
    if let primary = catalog.primary {
        presentChart(primary)
    } else {
        presentTable(message: "No chart recommendation is available.")
    }
case .tableFallback(let fallback):
    presentTable(message: fallback.message.defaultText)
}
```

Each recommendation carries a relative score, typed rationale messages, and
typed diagnostics. Scores only order candidates from the same request; they are
not confidence or probability. ``AutoChartColumnProfile`` exposes summarized
counts and ranges without retaining raw public values. Enable the trace to
inspect inferred semantics, ranks, scores, exclusions, and stable rejection
codes.

Use ``AutoChartAnalysis/resolve(_:)->AutoChartPreferenceResolution`` for a
persisted ``AutoChartPreference``. Resolution distinguishes an exact match, an
automatic or recommended default, a changed policy, an unavailable
specification, and a table-only outcome. Its replacement preference can be
persisted by the host using its own ordering or compare-and-swap policy.
An otherwise safe preference outside the bounded catalog is validated on demand
and retained as the catalog's preferred recommendation.

Preparation follows ``AutoChartPreparationStrategy``. A table preference
prepares no chart, a valid saved preference prepares that exact chart, and an
automatic preference prepares the primary when requested. Calling
`AutoChartAnalysis.prepare(_:)` remains explicit asynchronous work.
