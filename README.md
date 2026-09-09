# AutoTableCharts

[![DocC](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml/badge.svg)](https://github.com/hbmartin/AutoTableCharts/actions/workflows/docc.yml)

AutoTableCharts turns typed tabular data into deterministic, semantically safe
chart recommendations. Version 3 separates the Foundation-only analysis and
preparation core from the `AutoTableChartsUI` SwiftUI/Charts product, and adds a
shared cache plus observable sessions for application lifecycle orchestration.

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

Create an immutable dataset, retain one package cache at application scope, and
load an identity-bearing request through an observable session:

```swift
import AutoTableChartsUI
import SwiftUI

struct ResultChart: View {
    let request: AutoChartRequest<Int>
    @State private var session: AutoChartSession<Int>

    init(request: AutoChartRequest<Int>, cache: AutoChartCache) {
        self.request = request
        _session = State(initialValue: AutoChartSession(cache: cache))
    }

    var body: some View {
        AutoChartSessionView(session: session)
            .task { session.load(request, preference: .automatic) }
    }
}
```

Construct SQL-style data with `AutoChartDataset` and
`.trusted(identity:revision:)` or `.contentAddressed(identity:)`. Domain models
can use the `AutoChartDimension`, `Measure`, `Identifier`, and paired `Interval` result
builder declarations.

## v3 behavior

- `RowID` is a caller-defined `Hashable & Sendable` type and is preserved by
  prepared marks and `AutoChartSelection<RowID>`.
- `AutoChartDataset` validates widths and unique row/column IDs; arbitrary table
  conformances are validated before analysis as well.
- Coherent column semantics describe source provenance and rollup policy. Unknown and
  non-additive values cannot be implicitly aggregated. Composition additionally
  requires complete, positive, additive values.
- `AutoChartRecommendationCatalog` exposes at most five featured choices and
  fifty validated cataloged choices while preserving a valid off-list preference
  through targeted validation.
- `AutoChartPreference` separates automatic, table, recommended chart, and
  specific-chart choices from request identity.
- `AutoChartSession` owns supersession, cancellation, preparation, retries,
  selection provenance, and warm adoption from a shared `AutoChartCache`.
- Formatting, localization, accessibility, and semantic selection presentation
  happen at presentation time and do not affect preparation cache keys.
- Cache ownership belongs to `AutoChartCache`. Use `trim(to:)`, `removeAll()`,
  synchronous completed-analysis lookup, and `statistics()` to inspect it.

## Breaking migration to v3

Version 3 intentionally has no v2 compatibility facade. Adopt
`AutoChartRequest`, `AutoChartCache`, `AutoChartPreference`, catalog outcomes,
associated-value family specifications, `AutoChartColumnSemantics`, and the
separate `AutoTableChartsUI` product. Package failures now use
`AutoChartFailure`; cancellation remains cancellation. Dataset decoding accepts
the version 2 keyed `AutoChartDataKey` representation. Selections now carry
process-local provenance and are intentionally not `Codable`; persist source row
IDs and derive a fresh selection after preparation.

## Documentation and development

[Read the DocC documentation](https://hbmartin.github.io/AutoTableCharts/documentation/autotablecharts/).

```sh
swift test

# Build the consumer configuration in a clean scratch directory and verify that
# neither its object symbols nor serialized module metadata contains test hooks.
Scripts/verify-release-library.sh

# Verify both halves of the hook-dependent test contract from one manifest:
# explicit skips without hooks and actual execution with hooks.
Scripts/verify-release-tests.sh without-hooks
Scripts/verify-release-tests.sh with-hooks

# After an Xcode Release build, audit the consumer object and every architecture's
# serialized module metadata from that build as well.
Scripts/verify-release-library.sh --xcode-derived-data /path/to/DerivedData

swift package --allow-writing-to-directory .build/docc generate-documentation \
  --target AutoTableCharts \
  --target AutoTableChartsUI \
  --enable-experimental-combined-documentation \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path AutoTableCharts \
  --output-path .build/docc \
  --analyze \
  --warnings-as-errors \
  --experimental-documentation-coverage \
  --coverage-summary-level detailed
```
