# Rendering and Interaction

Render memoized presentation data and link chart marks to source rows.

## Overview

``AutoChartSession`` publishes analyzing, preparing, ready, fallback, and failed
states while preventing superseded work from replacing newer state. Two
sessions can share one core cache while retaining independent preferences and
selections. ``AutoChartSession/isPresentationPending`` reports presentation-only
work. ``AutoChartSession/isChartUpdatePending`` also includes preference work
while a ready chart remains visible. `AutoChartSessionView` displays a compact
updating indicator until the new choice is ready.

Both `load` overloads return ``AutoChartLoadApplication``. A `.started` result
means the request remains current at synchronous return; `.superseded` means an
Observation callback replaced, cancelled, or unloaded it during installation.
The result does not promise that later asynchronous work will remain current.

Use ``AutoChartSession/applyPreference(_:)`` when the host needs to distinguish an
unchanged or stored preference from prepared-chart reuse, a newly started pass, or
a pass made noncurrent by synchronous reentrancy. Prepared-chart reuse may leave
presentation work pending. During that interval, a ready state's analysis and
presented payload continue to describe the same visible chart, while
``AutoChartSession/currentRecommendation`` describes the requested replacement.

Use ``AutoChartSession/applyPreferenceResult(_:)`` when the host also needs to know
whether to discard state associated with the chart visible at call entry. Its
``AutoChartPreferenceApplicationResult/changesVisibleChart`` value compares prepared
chart identity when a target is known. An unresolved replacement counts as a change
when a chart was visible at call entry, while a superseded application describes the
effective synchronous target left by the winning operation.

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
system setting change triggers a new request in mounted session and convenience
views without allowing the old request to cache output under the new locale or
time zone. Mounted views using the immediate presented-chart initializer refresh
synchronously when the effective Foundation request changes. The
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
Mounted deferred charts allow two presentation callbacks by default, so a newer
request can pass one blocked cancelled callback. Progress labels use a separate
view-owned lane. Use `autoChartDeferredCallbackScheduling(.serial)` when host
callbacks must run one at a time, including progress labels. Cancelled queued
calls are removed before starting; a synchronous callback already running may
finish, but its cancelled result is not published or cached. Two blocked
presentation callbacks can still occupy both bounded slots. Progress labels
outside deferred charts also use view-owned scheduling.

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
selections. External binding updates are reflected by chart highlighting. When
charts share a selection binding, each chart ignores selections with foreign
analysis or prepared-chart provenance for highlighting. With selection chrome
enabled, a foreign selection is identified and can be cleared by the user.
Sessions clear their own selections when accepting a different chart or leaving
the visible-chart state after failure or cancellation.

Use the environment modifiers `autoChartPresentationContext(_:)`,
`autoChartFormatters(_:)`, `autoChartTextResolver(_:)`,
`autoChartPalette(_:)`, `autoChartTheme(_:)`, and
`autoChartDeferredCallbackScheduling(_:)` to configure a subtree.
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
the replacement's immediate valid presentation. A different logical chart
structure or snapshot content resets zoom; equivalent reanalysis can retain it
even when prepared-chart identity changes. Selection bindings still resynchronize
to chart provenance, reordered categories, and donut angles. Presentation-only
changes preserve zoom. Synchronous renderers and exporters
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
