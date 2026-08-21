# Generating Recommendations

Inspect typed outcomes, rationales, diagnostics, profiles, and optional decisions.

## Overview

``AutoChartAnalyzer/analyze(_:context:options:)`` returns an immutable
``AutoChartAnalysis``. The context goal affects ranking but never bypasses hard
validation. Options bound candidate count and visual density without sampling
the supplied rows.

```swift
let analysis = try await analyzer.analyze(
    dataset,
    context: AutoChartContext(goal: .trend, title: "Monthly Revenue"),
    options: AutoChartOptions(
        maximumRecommendations: 3,
        includesDecisionTrace: true))
```

Switch on the outcome:

```swift
switch analysis.outcome {
case .charts(let recommendations):
    let primary = recommendations[0]
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

Use ``AutoChartAnalysis/resolve(_:)`` for a persisted
``AutoChartRecommendationID``. Resolution distinguishes an exact match, a
default caused by no preference, a changed policy, or an unavailable
specification, and a table-only outcome.

The primary recommendation is always prepared during analysis. Calling
`AutoChartAnalysis.prepare(_:)` for another ID is explicit asynchronous work.
