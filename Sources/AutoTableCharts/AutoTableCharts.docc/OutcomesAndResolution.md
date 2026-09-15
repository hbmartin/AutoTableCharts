# Outcomes, Identity, and Resolution

Persist a typed choice and resolve it against a fresh analysis.

## Overview

``AutoChartRecommendationOutcome`` is either `.charts`, containing an
``AutoChartRecommendationCatalog``, or `.tableFallback`, containing a typed
fallback message and diagnostics. A table is host UI, not a chart family.

``AutoChartSpecification/id`` is structural and excludes policy and title.
``AutoChartRecommendationID`` adds the policy version. Persist it through the
`Codable` ``AutoChartPreference`` shape when the user selects a specific chart.

```swift
let resolution = analysis.resolve(savedPreference)
if resolution.usesTable {
    // Keep the host's table visible.
} else if let recommendation = resolution.recommendation {
    // Prepare or present this exact recommendation.
}
if let repair = resolution.replacementPreference {
    // Optionally persist the package's typed replacement suggestion.
}
```

An old-policy chart choice is rebound by structural specification ID when that
chart remains valid. In that case `defaultReason` is `.policyVersionRebound` and
`replacementPreference` supplies its current ID. If the specification is no
longer available, `.policyVersionChanged` indicates fallback to the primary
chart. Default catalog picker options include a valid preferred chart outside
the compact catalog so the shown chart remains selectable.

The decoder also accepts the legacy length-prefixed string representation. New
encodings use the typed keyed representation.

Recommendation rationale, diagnostics, and fallback text are
``AutoChartMessage`` values with stable category, code, and typed arguments.
Resolve package text through ``AutoChartTextResolver``; returning `nil` uses the
English fallback.

## Topics

- ``AutoChartRecommendationCatalog``
- ``AutoChartPreference``
- ``AutoChartPreferenceResolution``
- ``AutoChartRecommendationID``
- ``AutoChartSpecificationID``
- ``AutoChartFallback``
- ``AutoChartDiagnostic``
- ``AutoChartMessage``
