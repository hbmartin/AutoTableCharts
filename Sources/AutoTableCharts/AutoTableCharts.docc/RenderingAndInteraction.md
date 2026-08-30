# Rendering and Interaction

Render prepared marks, format every presentation surface, and link exact lineage.

## Overview

### Separate plot from chrome

``AutoChartPlot`` owns marks, axes, legends, gestures, and the bound semantic
selection. ``AutoChartView`` is a convenience composition that can add title,
diagnostics, selection summary, and zoom controls.

```swift
AutoChartView(
    preparedChart: prepared,
    selection: $selection,
    presentation: AutoChartPresentation(
        plotHeight: 156,
        chrome: [.diagnostics],
        interactions: [.selection],
        typography: .compact))
```

`plotHeight` is the exact total plot-region height for every family, including
facets. `nil` delegates sizing to normal SwiftUI layout. The `.preview` and
`.explorer` presets are conveniences; chrome and interactions remain independent.

### Format at presentation time

``AutoChartFormatters`` supplies an explicit locale and time zone plus an
optional host override. The formatter context distinguishes axis ticks, mark
accessibility, selection summaries, KPI values, and detail text. Defaults handle
currency, percent, area, duration, custom units, dates, and ordinary numbers.

The same formatters are used for axes, marks, accessibility, selection copy, and
KPI values. Custom renderers can use the `.detail` context for their own detail
text. Because formatters run at presentation time, changing locale does not
require reanalysis or re-preparation.

Custom renderers should use
``AutoChartFormatters/format(column:aggregation:value:context:)`` for aggregated
measure values and
``AutoChartFormatters/formatNormalizedFraction(_:column:aggregation:context:)``
for zero-through-one values on a normalized axis. Both preserve source-column
lineage for aggregation-aware request overrides while applying unitless count
and percentage defaults correctly.

When a host override depends on those semantics, use
``AutoChartFormatters/init(locale:timeZone:request:)``. Its
``AutoChartFormattingRequest`` distinguishes source values, aggregated measures,
and normalized fractions and includes the aggregation. The compatibility
`value` override remains available and receives the supplied source column for
raw and non-count measure values. It receives `nil` for count, distinct-count,
and normalized-fraction values because its callback cannot distinguish those
dimensionless results from ordinary source values. Request overrides retain the
source column for distinct counts and normalized fractions while receiving the
complete semantic purpose. Use the request override whenever formatting depends
on count, distinct-count, or normalized-fraction semantics.

> Important: Raw measure values are delivered to request overrides with purpose
> `.value`. Aggregated-measure requests carry an ``AutoChartAppliedAggregation``
> and are reserved for values transformed by an aggregation. Applied
> aggregations convert explicitly to and from ``AutoChartAggregation``. A
> normalized fraction may still carry `.none` when normalized stacking operates
> on unaggregated source marks.

``AutoChartTextResolver`` can override diagnostics, rationale, fallback,
accessibility, built-in controls, and generated chart labels using stable typed
messages. Generated category, value, count, distinct-count, median, series,
facet, date, and range titles each have a stable message code. Synthetic all-
values and missing-value labels and typed category disambiguation labels are
localizable as well. Source-column display names remain host-provided text.
Return `nil` to use the package English fallback.

The `.markAccessibility` message keeps its combined `facet` argument for
compatibility and additionally supplies `facetTitle` and `facetValue` so hosts
can reorder them. Numeric histogram intervals use
`.histogramBinAccessibility` with `start` and `end` arguments; temporal range
marks continue to use `.markAccessibilityRange` with the same argument names.

### Link semantic selection

``AutoChartSelection`` contains typed source row IDs, ordered dimension
column/value pairs, an optional measure with aggregation and scalar/range/
distribution value, separate start/end column lineage for temporal ranges,
family, specification ID, and mark identity. It contains no preformatted label
strings.

When one mark combines source categories that share a semantic identity but use
different exact `AutoChartValue` representations, selection retains all source
row IDs and omits that ambiguous dimension instead of choosing one source type.

```swift
let selectedRows = dataset.chartRows.filter {
    selection.sourceRowIDs.contains($0.chartRowID)
}

let copy = selection.presentation(
    columns: dataset.chartColumns,
    formatters: formatters,
    textResolver: resolver)
```

Clear selection when changing recommendation because mark identities and
semantics belong to the prepared specification.

Distinct-count aggregation compares numeric source values exactly. Equivalent
integral values stored as `Int64`, `Double`, or `Decimal` merge, while an
approximate fractional `Double` and an exact `Decimal` remain distinct unless
their exact values agree. This avoids collapsing separate decimal values merely
because both round to the same binary floating-point number.

Selection scalar dimensions use exact category formatting so adjacent category
identities do not collapse onto one rounded label. Numeric and temporal range
endpoints use ordinary value formatting because they describe continuous
bounds rather than category identities.

### Prepare alternatives asynchronously

The primary chart is ready when analysis returns. For an alternative, start a
cancellable task keyed by recommendation ID, show progress in the chart region,
then synchronously render the returned prepared chart. Failed or pending initial
analysis should keep the host's table available.
