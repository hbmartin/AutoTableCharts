# ``AutoChartSpecification``

Describe one chart family and its semantic channels.

## Overview

A specification is renderer-independent and `Codable`. Use the family-specific
factories—such as `bar`, `line`, `scatter`, `histogram`, or `faceted`—for ordinary
construction. The low-level initializer remains available for advanced designs.

Specifications depend on a particular analysis. Validate and asynchronously
prepare caller-authored values through the retained analysis:

```swift
let specification = AutoChartSpecification.bar(
    category: "region",
    measure: "revenue",
    orientation: .horizontal)

let validation = analysis.validate(specification)
guard validation.isValid else { return }
let prepared = try await analysis.prepare(specification)
```

The structural ``AutoChartSpecification/id`` includes every visual and transform
choice except `title`; policy identity belongs to ``AutoChartRecommendationID``.

## Topics

- ``AutoChartEncoding``
- ``AutoChartFamily``
- ``AutoChartAggregation``
- ``AutoChartOrientation``
- ``AutoChartStacking``
- ``AutoChartSort``
- <doc:CustomSpecifications>
- <doc:ChartFamilyReference>
