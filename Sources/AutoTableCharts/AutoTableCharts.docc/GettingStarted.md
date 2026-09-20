# Getting Started

Build a typed dataset, create an identity-bearing request, and analyze it through a shared cache.

## Overview

### Build immutable input

``AutoChartDataset`` is the shortest path from query-style rows to the package.
This initializer uses source offsets as `Int` row IDs:

```swift
let dataset = try AutoChartDataset<Int>(
    columns: [
        AutoChartColumn(
            id: "propertyType", name: "Property Type",
            semantics: .dimension(semanticType: .nominal)),
        AutoChartColumn(
            id: "marketValue", name: "Market Value",
            semantics: .measure(
                semanticType: .quantitative,
                unit: .currency(code: "USD"),
                semantics: .init(
                    source: .aggregated(.sum),
                    rollup: .additive,
                    preferredTransform: .sum))),
    ],
    rows: [
        [.text("Office"), .double(18_000_000)],
        [.text("Industrial"), .double(14_500_000)],
    ],
    metadata: .init(grain: "property type"),
    key: .trusted(identity: "portfolio-summary", revision: "2026-08-20"))
```

Use the explicit-row-ID initializer for UUIDs, database keys, or other domain
identities. Dataset initialization throws ``AutoChartDatasetError`` rather than
silently fixing malformed matrices or duplicate IDs.

### Analyze through shared package state

Keep one ``AutoChartCache`` at the application or feature scope where analyzers
and UI sessions should share reuse. Create a request whose identity includes the
data contract, context, options, constraints, and recommendation policy version:

```swift
let cache = AutoChartCache()
let analyzer = AutoChartAnalyzer(cache: cache)
let request = try AutoChartRequest(
    table: dataset,
    context: .init(goal: .comparison),
    options: .init(includesDecisionTrace: true))
let analysis = try await analyzer.analyze(
    request,
    preference: .automatic,
    preparation: .preferredOrPrimary)
```

Analysis includes a process-scoped identity and request identity, exact retained
cost, summarized public column profiles, typed diagnostics, an optional full
decision trace, a bounded recommendation catalog, preference resolution, and
the charts selected by the preparation strategy.

### Adopt the UI product

```swift
import AutoTableChartsUI

let session = AutoChartSession<Int>(cache: cache)
session.load(request)
```

`AutoChartSession` owns supersession, cancellation, preference-aware
preparation, warm-cache adoption, retries, and alternative selection. Use
`AutoChartSessionView` for package defaults or switch on session state to retain
an existing table and failure UI.

`load` returns the synchronous lifecycle result when a host needs it:

```swift
switch session.load(request) {
case .started:
    // The request was installed and is current on return.
    break
case .superseded:
    // Synchronous observation replaced, cancelled, or unloaded the request.
    break
}
```

The result describes installation, not eventual asynchronous completion. Calls
that intentionally ignore it remain valid. A function reference that previously
expected a `Void`-returning `load` method must adopt `AutoChartLoadApplication`.

Set a preference before loading when it should become the session default:

```swift
session.setPreference(.chart(.recommended))
session.load(request) // Uses the stored preference.

session.load(request, preference: .automatic) // Explicit values win.
```

Use `applyPreference(_:)` when the host needs the synchronous lifecycle result:

```swift
switch session.applyPreference(.chart(.recommended)) {
case .unchanged, .stored:
    break
case .reusedPreparedChart:
    // Analysis is reusable; presentation-only work may remain pending.
    break
case .startedReplacement:
    // A new asynchronous pass is current.
    break
case .superseded:
    // Synchronous reentrancy replaced, retried, cancelled, or unloaded the application.
    break
}
```

`retry` likewise reports its synchronous lifecycle result:

```swift
switch session.retry() {
case .noRequest:
    // The session had no retained request to restart.
    break
case .started:
    // The retry was installed and is current on return.
    break
case .superseded:
    // Synchronous observation replaced, cancelled, or unloaded the retry.
    break
}
```

The result describes synchronous installation, not eventual asynchronous
completion. Calls that intentionally ignore it remain valid. A function reference
that previously expected a `Void`-returning `retry` method must adopt
`AutoChartRetryApplication`.

Reapplying the stored preference does not restart analyzing, preparation, or a
terminal state. A retry after failure starts a new failure episode even if
`cancel()` was called after the failure. Retrying a nonfailed cancelled attempt
with the same preference resumes it without resetting shared failure history.
The analyzer publishes preference resolution before chart preparation begins.
Once resolved, every retry with an unchanged preference preserves
`currentRecommendation` synchronously, including uncached retries and retries
after cancelling a failed attempt. A failure before preference resolution leaves
the recommendation `nil`; changing the request or preference clears it.
`unload()` forgets request-specific state and loaded presentation callbacks while
preserving the session preference, active environment overrides, and knowledge of
failure episodes already shown. Loading that request again therefore starts a new
episode if the same failure recurs; a newly created session sharing the cache can
still join the current episode. Loading or selecting a scope the session has not
previously observed joins the cache's current episode instead of replacing it.

Observe `state`, `currentRecommendation`, `isChartUpdatePending`, and
`isPresentationPending` for lifecycle UI. `currentRecommendation` is the requested
or pending choice. During a preference change, `state` can continue to carry the
previously presented chart while `currentRecommendation` immediately describes
its replacement. In a ready state, the analysis and presented payload always
describe the same visible prepared chart; a different prepared presentation target
does not replace that pair until presentation completes. The session preserves
selection only while its prepared chart remains authoritative and clears selection
on replacement, fallback, failure, cancellation, or unload.

Presentation-context setters store their loaded configuration before observable
rebuilding begins. If a synchronous observer cancels or supersedes that rebuilding,
the retained request still uses the newest configuration on a later retry. `unload()`
resets loaded presentation configuration while preserving environment overrides.

### Prepare an alternative

```swift
.task(id: selectedRecommendationID) {
    guard let id = selectedRecommendationID else { return }
    selection = nil
    preparedChart = try? await analysis.prepare(id)
}
```

The UI session performs this cancellable work with `session.select(id)`.

See <doc:SafetySemanticsAndCompleteness> for measure contracts. The
`AutoTableChartsUI` documentation covers presentation and interaction.

### Migrate to v3

Version 3 replaces optional cache keys with explicit trusted or
content-addressed modes, recommendation arrays with catalogs, mutable family
encodings with associated-value specifications, contradictory hints with
``AutoChartColumnSemantics``, and scattered lifecycle errors with
``AutoChartFailure``. It is intentionally source breaking and has no v2 facade.
