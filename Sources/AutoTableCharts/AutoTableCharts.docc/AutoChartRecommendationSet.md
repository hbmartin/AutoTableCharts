# Outcomes, Identity, and Resolution

Persist a typed choice and resolve it against a fresh analysis.

## Overview

``AutoChartRecommendationOutcome`` is either `.charts`, containing a ranked
list of renderable recommendations, or `.tableFallback`, containing a typed
fallback message and diagnostics. A table is host UI, not a chart family.

``AutoChartSpecification/id`` is structural and excludes policy and title.
``AutoChartRecommendationID`` adds the policy version and is `Codable`, making
it the value to persist for a user's selected recommendation.

```swift
switch analysis.resolve(savedRecommendationID) {
case .exact(let recommendation):
    // The same policy and specification are available.
case .defaulted(let primary, let reason):
    // No preference, policy change, or unavailable specification.
case .unavailable(let fallback):
    // Keep the host's table visible.
}
```

The decoder also accepts the legacy length-prefixed string representation. New
encodings use the typed keyed representation.

Recommendation rationale, diagnostics, and fallback text are
``AutoChartMessage`` values with stable category, code, and typed arguments.
Resolve package text through ``AutoChartTextResolver``; returning `nil` uses the
English fallback.

## Topics

- ``AutoChartRecommendationResolution``
- ``AutoChartRecommendationID``
- ``AutoChartSpecificationID``
- ``AutoChartFallback``
- ``AutoChartDiagnostic``
- ``AutoChartMessage``
