# Getting Started

Build a typed dataset, retain an async analysis, and render its eager primary chart.

## Overview

### Build immutable input

``AutoChartDataset`` is the shortest path from query-style rows to the package.
This initializer uses source offsets as `Int` row IDs:

```swift
let dataset = try AutoChartDataset<Int>(
    columns: [
        AutoChartColumn(
            id: "propertyType", name: "Property Type",
            hints: .init(semanticType: .nominal, role: .dimension)),
        AutoChartColumn(
            id: "marketValue", name: "Market Value",
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
        [.text("Office"), .double(18_000_000)],
        [.text("Industrial"), .double(14_500_000)],
    ],
    metadata: .init(grain: "property type"),
    key: .init(identity: "portfolio-summary", revision: "2026-08-20"))
```

Use the explicit-row-ID initializer for UUIDs, database keys, or other domain
identities. Dataset initialization throws ``AutoChartDatasetError`` rather than
silently fixing malformed matrices or duplicate IDs.

### Analyze once

Keep one analyzer at the application or feature scope that should share reuse.
Store the result in async state:

```swift
@MainActor
final class ChartState: ObservableObject {
    let analyzer: AutoChartAnalyzer
    @Published var analysis: AutoChartAnalysis<Int>?
    @Published var error: Error?
    private var analysisTask: Task<Void, Never>?

    init(analyzer: AutoChartAnalyzer) {
        self.analyzer = analyzer
    }

    func load(_ dataset: AutoChartDataset<Int>) {
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                let nextAnalysis = try await analyzer.analyze(
                    dataset,
                    context: .init(goal: .comparison),
                    options: .init(includesDecisionTrace: true))
                try Task.checkCancellation()
                analysis = nextAnalysis
            } catch is CancellationError {
                // A newer load owns the state now.
            } catch {
                self.error = error
            }
        }
    }
}
```

Analysis includes summarized public column profiles, typed diagnostics, an
optional full decision trace, a typed outcome, and the eagerly prepared primary.

### Render the primary or a fallback

```swift
if let analysis = state.analysis {
    AutoChartView(
        analysis: analysis,
        selection: $selection,
        presentation: .preview(plotHeight: 156))
} else {
    ExistingTableView()
}
```

`AutoChartView(analysis:)` presents the primary or the package fallback. Many
applications instead switch on `analysis.outcome` and keep their existing table
UI for `.tableFallback`.

### Prepare an alternative

```swift
.task(id: selectedRecommendationID) {
    guard let id = selectedRecommendationID else { return }
    selection = nil
    preparedChart = try? await analysis.prepare(id)
}
```

The task should be cancellable and keyed by recommendation ID. Render the
returned immutable chart synchronously with `AutoChartView(preparedChart:)`.

See <doc:SafetySemanticsAndCompleteness> for measure contracts and
<doc:RenderingAndInteraction> for formatting and semantic selection.

### Migrate from v1

Version 2 removes the synchronous engine, global render cache, string row ID,
table-based rendering initializers, table pseudo-family, aggregation-safety
enum, and combined interaction preset. Adopt ``AutoChartAnalyzer``, a typed
`RowID`, ``AutoChartMeasureSemantics``, prepared-only rendering, typed outcomes,
and ``AutoChartPresentation``. There are no compatibility wrappers.
