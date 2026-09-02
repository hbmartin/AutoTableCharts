# AutoTableCharts

[![DocC](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml/badge.svg)](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml)

AutoTableCharts turns typed tabular data into deterministic, semantically safe
native Swift Charts. Version 2 uses an instance-owned asynchronous analyzer: one
analysis contains inspectable recommendations and an eagerly prepared primary
chart, while alternatives are prepared explicitly.

The package is offline, does not sample rows, and never mutates caller storage.

## Requirements

- Swift 6.2 or later
- Xcode 26 or later
- iOS 17, macOS 14, tvOS 17, or watchOS 10 for Swift Charts rendering
- Linux for the Foundation-only models, analysis, validation, and preparation core

## Installation

Until the package has a versioned release, depend on `main` or pin a revision:

```swift
dependencies: [
    .package(
        url: "https://github.com/hbmartin/AutoTableCharts.git",
        branch: "main"
    )
]
```

## Quickstart

Create an immutable dataset, retain an analyzer at application scope, and load
the analysis into async view state:

```swift
import AutoTableCharts
import SwiftUI

@MainActor
final class ChartModel: ObservableObject {
    let analyzer = AutoChartAnalyzer()
    @Published var analysis: AutoChartAnalysis<Int>?

    func load() async throws {
        let dataset = try AutoChartDataset<Int>(
            columns: [
                AutoChartColumn(
                    id: "region", name: "Region",
                    hints: .init(semanticType: .nominal, role: .dimension)),
                AutoChartColumn(
                    id: "revenue", name: "Revenue",
                    hints: .init(
                        semanticType: .quantitative,
                        role: .measure,
                        unit: .currency(code: "USD"),
                        measureSemantics: .init(
                            source: .aggregated(.sum),
                            rollup: .additive,
                            preferredTransform: .sum))),
            ],
            rows: [
                [.text("North"), .double(12_000)],
                [.text("South"), .double(9_500)],
            ],
            key: AutoChartDataKey(identity: "quarterly-revenue", revision: "2026-Q3"))

        analysis = try await analyzer.analyze(
            dataset,
            context: AutoChartContext(goal: .comparison))
    }
}

struct ResultChart: View {
    @ObservedObject var model: ChartModel
    @State private var selection: AutoChartSelection<Int>?

    var body: some View {
        if let analysis = model.analysis {
            AutoChartView(
                analysis: analysis,
                selection: $selection,
                presentation: .explorer(plotHeight: 320))
        } else {
            ProgressView()
        }
    }
}
```

`analysis.primaryChart` is already prepared. To render another recommendation,
call `try await analysis.prepare(recommendation.id)` and pass the returned value
to `AutoChartView(preparedChart:)`.

## v2 behavior

- `RowID` is a caller-defined `Hashable & Sendable` type and is preserved by
  prepared marks and `AutoChartSelection<RowID>`.
- `AutoChartDataset` validates widths and unique row/column IDs; arbitrary table
  conformances are validated before analysis as well.
- Measure hints describe source provenance and rollup policy. Unknown and
  non-additive values cannot be implicitly aggregated. Composition additionally
  requires complete, positive, additive values.
- `AutoChartRecommendationOutcome` distinguishes chart recommendations from a
  typed table fallback. Persist `AutoChartRecommendationID`, which combines the
  recommendation policy with a structural specification ID.
- Rendering accepts only `AutoChartPreparedChart`. `AutoChartPlot` contains the
  plot and gestures; `AutoChartView` adds configurable chrome.
- Formatting, localization, accessibility, and semantic selection presentation
  happen at presentation time and do not affect preparation cache keys.
- Cache ownership belongs to each `AutoChartAnalyzer`. Use `trim(to:)`,
  `removeAll()`, and `cacheStatistics` to manage and inspect retained state.

## Breaking migration from v1

Version 2 intentionally has no source-compatibility layer. Replace
`AutoChartEngine` with an owned `AutoChartAnalyzer`; replace table-based view
initializers with `AutoChartPreparedChart`; replace `AutoChartRowID` with your
own `RowID`; replace `aggregation`/`aggregationSafety` hints with
`AutoChartMeasureSemantics`; and switch on `AutoChartRecommendationOutcome`
instead of treating a table as a chart family. The global render cache and
`AutoChartInteraction` are removed. Persist `AutoChartRecommendationID` and use
`AutoChartPresentation` for independent chrome, interaction, and plot sizing.
`AutoChartPresentation.plotHeight` now defaults to `280`, while
`AutoChartPlot.plotHeight` defaults to `180`. Existing hosts that already supply
a bounded plot height can pass `nil` to preserve SwiftUI-managed sizing.

## Documentation and development

[Read the DocC documentation](https://hbmartin.github.io/AutoTableCharts/documentation/autotablecharts/).

```sh
swift test

# Release runs need the test-only hooks re-enabled; without the flag the
# hook-dependent tests are reported as skipped rather than silently omitted.
swift test -c release -Xswiftc -DATC_TEST_HOOKS

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
