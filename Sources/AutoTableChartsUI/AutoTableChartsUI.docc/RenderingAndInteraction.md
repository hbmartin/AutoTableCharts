# Rendering and Interaction

Render memoized presentation data and link chart marks to source rows.

## Overview

``AutoChartSession`` publishes analyzing, preparing, ready, fallback, and failed
states while preventing superseded work from replacing newer state. Two
sessions can share one core cache while retaining independent preferences and
selections. When a ready chart remains visible during presentation-only work,
``AutoChartSession/isPresentationPending`` reports that the visible payload is
being replaced and `AutoChartSessionView` displays a compact progress indicator.

``AutoChartPresenter`` performs localization, formatting, ordering, and
histogram label resolution before a resolved chart body is evaluated. Its bounded
memo is keyed by prepared-chart identity, ``AutoChartPresentationContext``, the
effective locale and time zone, and host callback identity. Change the context
identity when the behavior captured by an existing callback changes. A formatter
or resolver callback receives a generated identity by default; use its
`cacheIdentity` parameter to let equivalent wrappers constructed during repeated
view evaluation share entries, and change that identity whenever captured behavior
changes. Autoupdating locale and time-zone values are frozen from `Locale.current`
and `TimeZone.current` once per request, preserving user formatting preferences;
the same snapshots supply both the cache key and every formatted surface. A later
system setting change therefore creates a new request without allowing the old
request to cache output under the new locale or time zone. The
`AutoChartView` and `AutoChartPlot` convenience initializers accept
`presentationContext` for the same invalidation control and defer memo misses to
a cancellable presentation task. Call
``AutoChartConveniencePresentationCache/removeAll()`` to release the process-wide
convenience memo in response to memory pressure. This does not purge independently
owned presenters; use their `removeAll()` method to release those payloads. Presented
charts whose originating presenter has been released also use this shared bounded
fallback, so clearing the convenience cache purges those fallback entries.

`present` and the presented-chart view's default ``AutoChartOverridePresentationMode/immediate``
mode run formatter and text-resolver callbacks synchronously on the caller's
thread. `presentCancellable` and explicit
``AutoChartOverridePresentationMode/deferred`` presentation run callbacks off-main.
Progress-label resolution uses a separate concurrent execution lane. Superseded
presentation generations may finish their synchronous host callbacks after newer
work starts, but cancellation prevents their results from being cached or published.
Callbacks supplied to deferred rendering must therefore honor their `@Sendable`
contract and permit calls from overlapping generations.

Deferred convenience views require a mounted SwiftUI lifecycle to run their
presentation task. Synchronous renderers such as snapshot exporters should call
``AutoChartPresenter/present(_:context:formatters:textResolver:)`` first and pass
the result to the presented-chart `AutoChartView` initializer. Overrides supplied
to that initializer resolve synchronously by default, including uncached overrides
when the presenter memo is disabled or has evicted the prior payload. Lifecycle-hosted
views should pass `overridePresentationMode: .deferred`. Hoist formatter and resolver
values across body evaluations, or give equivalent reconstructed callbacks a stable
`cacheIdentity`, to avoid repeated synchronous cache misses.

`AutoChartSelectionSet` is ordered and provenance-safe. A click replaces its
selection; Command-click removes a matched group when all its marks are selected
and otherwise completes the group. Every selected mark carries its analysis and
prepared-chart identities, and `unionedSourceRows` supports linked table filtering.
External row-ID updates select every intersecting mark and retain each mark's full
source-row lineage, so aggregate selections stay consistent with chart-originated
selections. External binding updates are reflected by chart highlighting.

Use the environment modifiers `autoChartPresentationContext(_:)`,
`autoChartFormatters(_:)`, `autoChartTextResolver(_:)`,
`autoChartPalette(_:)`, and `autoChartTheme(_:)` to configure a subtree.
Only explicitly supplied environment values override presentation settings
passed to ``AutoChartSession/load(_:preference:preparation:presentationContext:formatters:textResolver:)``.
For direct `AutoChartView` and `AutoChartPlot` construction, an omitted context,
formatter, or resolver inherits the corresponding environment value, while an
initializer argument takes precedence. A view initialized from an already
presented chart keeps that chart's formatter and resolver unless the initializer
explicitly overrides one. Exact request matches and exact cached overrides render
synchronously without invoking host callbacks. By default, an override cache miss
is resolved immediately on the caller's thread. Pass
`overridePresentationMode: .deferred` to keep the incoming chart visible with an
updating indicator while a cancellable task re-presents it off the main actor; only
the newest request is published. Replacing that chart while work is pending shows
the replacement's immediate valid presentation and keeps the rendered child mounted
so chart-change interaction resets still run. Retained
selection is resynchronized to reordered and reformatted categories or donut angles,
while presentation-only changes preserve zoom. Synchronous renderers and exporters
do not need to pre-present overrides supplied to a presented-chart view.
The replacement includes visible order, domains, facets, controls, mark
accessibility, and Audio Graph, so every surface uses the same labels and formatting.

Audio Graph availability uses an early-exit usability check during presentation.
Range calculation, mark formatting, and AX descriptor construction remain lazy and
share chart-only view state. Deferred and fallback views allocate no Audio Graph
cache. Rebuilding an unchanged descriptor does not repeat mark formatting or recreate
the AX data points, and application tracking weakly references framework AX objects.

Every supported quantitative chart exposes an Apple Audio Graph descriptor built
from the same prepared marks, display labels, units, locale, and time zone used
on screen. KPI, range, empty, and otherwise unusable charts expose no Audio Graph.
Series lines also use dash patterns, scatter series use symbols,
grouped bars use position, and donut slices carry labels. When Differentiate
Without Color is enabled, stacked-series bars and heatmap cells add compact text
labels instead of relying on color alone.
