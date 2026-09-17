# Prepared Analysis and Scoped Caching

Own analysis and prepared-chart reuse at an explicit application scope.

## Overview

``AutoChartCache`` is the thread-safe owner of reusable state. An
``AutoChartAnalyzer`` created with that cache accepts an ``AutoChartRequest``,
profiles and recommends safe candidates, and prepares charts according to
``AutoChartPreparationStrategy``. Alternatives remain available through
`AutoChartAnalysis.prepare(_:)`.

The standard configuration retains up to eight table/profile nodes, sixteen
analyses, sixteen prepared charts, and 64 MiB of shared storage. Use
``AutoChartAnalyzerConfiguration/uncached`` for an isolated one-shot analyzer or
configure limits for the owning application.

```swift
let cache = AutoChartCache(
    configuration: AutoChartAnalyzerConfiguration(
        tables: .init(maximumEntries: 8),
        analyses: .init(maximumEntries: 64),
        preparedCharts: .init(maximumEntries: 16),
        maximumRetainedCost: 32 * 1_024 * 1_024))
```

``AutoChartDataKey/trusted(identity:revision:)`` enables lookup without a cell
scan. Keep `identity` stable for one logical table and change `revision` for any
value, row ID, schema, semantic, or metadata change. Use content-addressed mode
when the package should snapshot and collision-check the input.

Identical in-flight analyses are coalesced. Cancellation is checked between
pipeline stages and bounded row chunks; shared work is cancelled only when its
last waiter leaves. `trim(to: .minimum)` evicts completed reusable entries while
preserving work in flight. ``AutoChartCache/removeAll()`` cancels shared work
in flight and resets retained state; `analyze` callers whose own tasks were not
cancelled retry transparently against the reset analyzer up to three times. If
`removeAll()` invalidates the initial attempt and all three retries, the call
throws ``AutoChartAnalyzerError/resetRetryLimitExceeded(maximumRetries:)``
instead of retrying indefinitely.

Inspect ``AutoChartCache/statistics()`` for exact per-layer entries, retained
cost, hits, misses, evictions, and in-flight request counts. Completed typed
analysis lookup is synchronous.

## Failure episodes

The cache coalesces equivalent failures independently for request work and for
each recommendation's chart preparation. Successful request work retires only the
request-scoped episode; successful chart preparation retires only that
recommendation's episode. Other specification failures for the request remain
available for callers that are still observing them.

Direct analyzer calls and fresh sessions join a matching retained episode. A
session remembers the episodes it has already published across cancellation,
unload, and request supersession. If that session later encounters the same
retained failure, it receives a new episode while another fresh session may still
join the cache's current episode. This session history is pruned against the
cache's bounded live failure records and ends with the session.

An explicit session retry starts new episodes for the request and recommendation
scopes that the new attempt actually reaches. The exception is retrying a
nonfailed, cancelled attempt with the same preference, which resumes ordinary
coalescing. Cancellation, unload, and supersession publish no failure themselves.
Presentation-only and uncached failures receive independent episode identifiers.
``AutoChartCache/beginRetry(for:)`` remains a request-wide operation for callers
that intentionally want to end every retained request and recommendation episode;
sessions use attempt-scoped handling instead.

## Topics

- ``AutoChartAnalyzerConfiguration``
- ``AutoChartCache``
- ``AutoChartAnalyzerError``
- ``AutoChartCacheTrimTarget``
- ``AutoChartCacheStatistics``
- ``AutoChartDataKey``
- <doc:RecommendationPipeline>
