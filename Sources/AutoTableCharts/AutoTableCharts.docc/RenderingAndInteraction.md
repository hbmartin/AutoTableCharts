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
details. Because they run at presentation time, changing locale does not require
reanalysis or re-preparation.

``AutoChartTextResolver`` can override diagnostics, rationale, fallback,
accessibility, and built-in controls using stable typed messages. Return `nil`
to use the package English fallback.

### Link semantic selection

``AutoChartSelection`` contains typed source row IDs, ordered dimension
column/value pairs, an optional measure with aggregation and scalar/range/
distribution value, family, specification ID, and mark identity. It contains no
preformatted label strings.

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

### Prepare alternatives asynchronously

The primary chart is ready when analysis returns. For an alternative, start a
cancellable task keyed by recommendation ID, show progress in the chart region,
then synchronously render the returned prepared chart. Failed or pending initial
analysis should keep the host's table available.
