# Prepared Analysis and Scoped Caching

Own analysis and prepared-chart reuse at an explicit application scope.

## Overview

``AutoChartAnalyzer`` is an actor. A call to `analyze(_:context:options:)`
validates and snapshots the input, profiles it, recommends candidates, validates
the primary specification, and prepares the primary chart exactly once.
Alternatives are prepared only through `AutoChartAnalysis.prepare(_:)`.

The standard configuration retains up to eight table/profile nodes, sixteen
analyses, sixteen prepared charts, and 64 MiB of shared storage. Use
``AutoChartAnalyzerConfiguration/uncached`` for an isolated one-shot analyzer or
configure limits for the owning application.

```swift
let analyzer = AutoChartAnalyzer(
    configuration: AutoChartAnalyzerConfiguration(
        tables: .init(maximumEntries: 8),
        analyses: .init(maximumEntries: 64),
        preparedCharts: .init(maximumEntries: 16),
        maximumRetainedCost: 32 * 1_024 * 1_024))
```

``AutoChartDataKey`` enables reuse without a content scan. Keep `identity`
stable for one logical table and change `revision` for any value, row ID, schema,
hint, or metadata change. Without a key, the analyzer fingerprints and compares
the snapshot.

Identical in-flight analyses are coalesced. Cancellation is checked between
pipeline stages and bounded row chunks; shared work is cancelled only when its
last waiter leaves. `trim(to: .minimum)` evicts completed reusable entries while
preserving work in flight. ``AutoChartAnalyzer/removeAll()`` cancels shared work
in flight and resets retained state; `analyze` callers whose own tasks were not
cancelled retry transparently against the reset analyzer up to three times. If
`removeAll()` invalidates the initial attempt and all three retries, the call
throws ``AutoChartAnalyzerError/resetRetryLimitExceeded(maximumRetries:)``
instead of retrying indefinitely.

Inspect ``AutoChartAnalyzer/cacheStatistics`` for per-layer entries, cost, hits,
misses, evictions, and the number of in-flight requests.

## Topics

- ``AutoChartAnalyzerConfiguration``
- ``AutoChartAnalyzerError``
- ``AutoChartCacheTrimTarget``
- ``AutoChartCacheStatistics``
- ``AutoChartDataKey``
- <doc:RecommendationPipeline>
