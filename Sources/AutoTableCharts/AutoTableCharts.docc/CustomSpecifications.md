# Custom Specifications

Override recommendation with a declarative chart while retaining the same safety checks.

## Overview

### Build an encoding

``AutoChartEncoding`` assigns table columns to channels. Required assignments
depend on ``AutoChartFamily``. For a horizontal ranked bar, assign a categorical
x field and quantitative y field:

```swift
let specification = AutoChartSpecification(
    family: .bar,
    encoding: AutoChartEncoding(x: "propertyType", y: "marketValue"),
    aggregation: .none,
    orientation: .horizontal,
    sort: .descending,
    title: "Property Types by Market Value"
)
```

The names `x` and `y` describe semantic channels before orientation is applied.
A horizontal bar renderer places the category labels vertically and the measure
horizontally.

### Validate before rendering

```swift
let validation = AutoChartEngine.validate(
    specification: specification,
    for: table
)

guard validation.isValid else {
    // Present validation.issues to the caller.
    return
}
```

Validation checks:

- Every referenced column exists.
- Required channels have compatible semantic types.
- Series and facet channels are categorical where required.
- Incomplete results use only families that remain truthful for partial rows.
- Composition is complete, positive, and explicitly additive.
- Non-frequency aggregation has declared rollup safety.
- Unaggregated categorical marks have a unique result-grain value.
- Temporal range starts don't occur after their ends.

### Render a valid specification

Use ``AutoChartView/init(table:specification:selection:interaction:height:)``.
The view creates a zero-score recommendation wrapper, adds the incomplete-result
warning when needed, and performs validation again at render time.

```swift
AutoChartView(
    table: table,
    specification: specification,
    interaction: .explore
)
```

### Keep transforms honest

Set ``AutoChartAggregation/none`` when the encoded fields already identify one
measure per mark. Use an aggregate only when the measure's hints establish that
rollup is safe. Histogram and heatmap counts are structural frequencies and are
validated separately; donut specifications must explicitly request `.sum` for
their positive additive measure.

Choose ``AutoChartStacking/standard`` only for additive contributions and
``AutoChartStacking/normalized`` only when the intended question is proportional
composition. A syntactically valid specification can still be misleading if its
table metadata omits truncation, grain, or upstream aggregation truth.
