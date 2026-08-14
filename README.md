# AutoTableCharts

AutoTableCharts turns typed tabular data into a bounded set of deterministic,
semantically safe native Swift Charts. It runs fully offline, has no external
dependencies, and targets iOS 17 and macOS 14.

The recommendation pipeline is: typed profiling → candidate generation → hard
safety constraints → deterministic ranking → Swift Charts rendering. It never
parses natural-language questions, calls a model, rewrites SQL, samples rows,
or mutates consumer-owned table storage.

## Use

Conform the consumer's existing table and row types to `AutoChartTable` and
`AutoChartRow`, then request recommendations:

```swift
import AutoTableCharts
import SwiftUI

let context = AutoChartContext(
    goal: .comparison,
    title: "Current market value by fund")
let result = AutoChartEngine.recommendations(
    for: table,
    context: context)
let recommendation = result.chartRecommendations.first
```

Render a recommendation while preserving linked source-row selection:

```swift
struct ResultChart: View {
    let table: MyTable
    let recommendation: AutoChartRecommendation
    @State private var selection: AutoChartSelection?

    var body: some View {
        AutoChartView(
            table: table,
            recommendation: recommendation,
            selection: $selection,
            interaction: .explore)
    }
}
```

Caller-provided overrides can be checked with
`AutoChartEngine.validate(specification:for:)` before rendering.

## Safety and behavior

- Explicit column hints override inferred quantitative, temporal, nominal,
  ordinal, identifier, Boolean, or unsupported types.
- Identifiers are never measures, and unknown aggregation safety blocks
  implicit aggregation.
- Composition requires complete, positive, additive data. Truncated results
  suppress totals, frequency claims, and composition; permitted charts carry
  a visible first-returned-rows warning.
- Defaults cap output at five diverse alternatives, twenty categories, six
  donut sectors, six series, and six facets. Supplied rows are never sampled.
- Exact selection emits every contributing `AutoChartRowID`. Exploratory
  charts support dense-axis scrolling, pinch zoom, and Reset Zoom; range
  brushing is intentionally not provided.

Run the package tests with `swift test`.
