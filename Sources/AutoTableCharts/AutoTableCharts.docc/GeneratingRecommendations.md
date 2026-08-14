# Generating Recommendations

Choose an analytical goal, bound visual complexity, and interpret the ranked result.

## Overview

### Express the task

Call ``AutoChartEngine/recommendations(for:context:options:)`` with an
``AutoChartContext``. The goal adds a ranking bonus to chart families suited to
that task; it never bypasses validation.

```swift
let result = AutoChartEngine.recommendations(
    for: table,
    context: AutoChartContext(goal: .trend, title: "Monthly Revenue"),
    options: AutoChartOptions(maximumRecommendations: 3)
)
```

Use `.overview` when the caller has no more specific task. Other goals favor
comparison, ranking, trend, distribution, relationship, composition, temporal
ranges, or outliers.

### Bound the result

``AutoChartOptions`` defaults to five recommendations, 20 categories, six donut
sectors, six series, and six facets. These are candidate-generation limits, not
sampling controls: all supplied rows remain available to profiling, preparation,
and lineage.

Limits are clamped to at least one recommendation and at least two categories,
sectors, series, or facets. Lower them for compact previews; raise them only when
the surrounding UI can handle the resulting density.

### Interpret the result

``AutoChartRecommendationSet/recommendations`` is ordered by descending policy
score. Exact ties use the declared family order and then the deterministic
specification ID. ``AutoChartRecommendationSet/chartRecommendations`` excludes
the table fallback for callers that only want renderable charts.

Each recommendation contains:

- A validated ``AutoChartRecommendation/specification``.
- A relative ``AutoChartRecommendation/score`` that isn't a probability.
- ``AutoChartRecommendation/rationale`` explaining the structural fit.
- ``AutoChartRecommendation/warnings`` describing limitations such as truncation.

The engine first chooses the best candidate from each distinct chart family,
then fills any unused result slots from the remaining ranked candidates. This
prevents a small numerical difference from returning a gallery of near-duplicates.

### Handle conservative fallback

If the table is empty or no candidate passes the hard constraints, the set
contains a ``AutoChartFamily/table`` recommendation with score zero. Present
``AutoChartRecommendationSet/fallbackReason`` and keep the user's exact records
available rather than forcing an unsafe chart.

Common fallback causes include missing chartable values, identifiers without
measures, duplicate categories with unknown aggregation safety, composition
without positive additive values, and incomplete results.

### Cache with policy awareness

``AutoChartSpecification/id`` includes
``AutoTableCharts/recommendationPolicyVersion`` and all visual choices except
the title. Persisted callers can use that version to invalidate identifiers when
the recommendation policy changes. Don't interpret raw scores as a stable API
across policy versions.
