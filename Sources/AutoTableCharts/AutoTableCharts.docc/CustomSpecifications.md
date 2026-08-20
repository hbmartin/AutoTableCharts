# Custom Specifications

Prepare caller designs explicitly while retaining the analyzer's safety boundary.

## Overview

Prefer a family factory:

```swift
let specification = AutoChartSpecification.faceted(
    baseFamily: .line,
    x: "month",
    y: "revenue",
    facet: "region",
    title: "Monthly Revenue by Region")
```

The low-level initializer remains available when every channel and option must be
set directly. Channel names describe semantic roles before orientation is
applied.

Validate against the retained analysis, then prepare asynchronously:

```swift
let validation = analysis.validate(specification)
guard validation.isValid else {
    present(validation.issues)
    return
}

let prepared = try await analysis.prepare(specification)
AutoChartView(preparedChart: prepared)
```

Validation checks referenced columns, channel compatibility, completeness,
missing values, duplicate mark grains, interval ordering, finite domains, and
the exact rollup operation authorized by measure semantics. Composition also
requires additive, positive, complete values.

Caller specifications do not become recommendations and do not alter the
analysis outcome. Their prepared values are immutable and may be retained after
the analyzer cache is trimmed.
