# AutoTableCharts

[![DocC](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml/badge.svg)](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml)

AutoTableCharts turns typed tabular data into a bounded set of deterministic,
semantically safe native Swift Charts. It runs fully offline, has no external
runtime dependencies.

[Read the complete DocC documentation](https://hbmartin.github.io/AutoTableCharts/documentation/autotablecharts/),
including modeling guidance, all 18 chart families, safety semantics, and the
implemented research lineage.

The recommendation pipeline is: typed profiling → candidate generation → hard
safety constraints → deterministic ranking → Swift Charts rendering. It never
parses natural-language questions, calls a model, rewrites SQL, samples rows,
or mutates consumer-owned table storage.

## Requirements

- Swift 6.2 or later
- Xcode 26 or later
- iOS 17, macOS 14, tvOS 17, or watchOS 10 or later for Swift Charts rendering
- Linux for the Foundation-only typed models, recommendation, and validation APIs

## Installation

Until a versioned release exists, depend on the repository's `main` branch:

```swift
dependencies: [
    .package(
        url: "https://github.com/hbmartin/AutoTableCharts.git",
        branch: "main"
    )
]
```

## Quickstart

Conform the consumer's existing table and row types to `AutoChartTable` and
`AutoChartRow`, then request and render a recommendation:

```swift
import AutoTableCharts
import SwiftUI

struct ResultChart: View {
    let table: MyTable
    @State private var selection: AutoChartSelection?

    var body: some View {
        let result = AutoChartEngine.recommendations(
            for: table,
            context: AutoChartContext(goal: .comparison)
        )

        if let recommendation = result.chartRecommendations.first {
            AutoChartView(
                table: table,
                recommendation: recommendation,
                selection: $selection,
                interaction: .explore
            )
        }
    }
}
```

Caller-provided overrides can be checked with
`AutoChartEngine.validate(specification:for:)` before rendering.
The [Getting Started guide](https://hbmartin.github.io/AutoTableCharts/documentation/autotablecharts/gettingstarted)
contains a complete table adapter.

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

## Develop and preview documentation

Run the package tests:

```sh
swift test
```

Launch DocC's local preview server:

```sh
swift package --disable-sandbox preview-documentation \
  --target AutoTableCharts
```

Build the same static-hosting archive used by GitHub Pages, with analysis,
coverage, and warnings treated as errors:

```sh
swift package --allow-writing-to-directory .build/docc generate-documentation \
  --target AutoTableCharts \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path AutoTableCharts \
  --output-path .build/docc \
  --analyze \
  --warnings-as-errors \
  --experimental-documentation-coverage \
  --coverage-summary-level detailed
```

The generated site stays under `.build`; it is never committed.
