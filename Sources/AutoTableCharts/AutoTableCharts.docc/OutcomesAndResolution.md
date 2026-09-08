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
