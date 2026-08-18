# Rendering and Interaction

Render validated native charts while preserving selection lineage and accessible context.

## Overview

### Render a recommendation

Prefer ``AutoChartView/init(table:recommendation:selection:interaction:height:)``
for engine output. It retains warnings and rationale alongside the specification.

```swift
AutoChartView(
    table: table,
    recommendation: recommendation,
    selection: $selection,
    interaction: .explore,
    height: 320
)
```

Use ``AutoChartInteraction/preview`` in a recommendation gallery. Preview mode
uses compact typography and omits exploratory selection and zoom controls. Use
``AutoChartInteraction/explore`` for a chosen chart.

`AutoChartView` caches one shared snapshot and profile set per table revision, then
caches validation and mark preparation for each recommendation without copying the
snapshot into every cache entry. Byte-aware limits exclude tables with oversized
text or binary payloads from the process-wide cache. By default the renderer
fingerprints table content before looking up the cache. Implement both
``AutoChartTable/chartDataIdentity`` and ``AutoChartTable/chartDataVersion`` to
skip that repeated table scan during SwiftUI view reconstruction. Keep the identity
stable and distinct for each logical table, and change the version whenever columns,
rows, values, or metadata change. A version without an identity deliberately falls
back to content fingerprinting so two tables of the same Swift type cannot collide.

Memory-constrained hosts can lower both cache layers during startup. A zero entry
or byte limit disables that layer, and the two layers can be enabled independently.
When render caching is enabled without table caching, renders for the same stable
table revision reuse a render-owned snapshot and profile set when possible. Its
estimated size is conservatively charged to each retaining render entry's byte
budget:

```swift
AutoChartRenderCache.configure(
    AutoChartRenderCacheConfiguration(
        maximumTableEntries: 2,
        maximumTableCost: 4 * 1_024 * 1_024,
        maximumRenderEntries: 4,
        maximumRenderCost: 4 * 1_024 * 1_024
    )
)
```

Call ``AutoChartRenderCache/removeAll()`` to release retained preparation data on
demand. On UIKit platforms that publish memory-warning notifications, the cache
also clears itself automatically.

#### Migrating version-only cache conformances

Earlier revisions used ``AutoChartTable/chartDataVersion`` alone as a fast cache
key. Those conformances continue to compile, but now use content fingerprinting to
prevent two same-typed tables with the same version from sharing prepared data.
Add a stable, table-specific ``AutoChartTable/chartDataIdentity`` to restore the
scan-free path.

### Link selections to source rows

Bind an optional ``AutoChartSelection`` to coordinate the chart with a table or
detail view. A raw mark contributes one row ID. Grouped marks, heatmap cells,
histogram bins, box plots, and donut sectors contribute the union of all source
rows they represent.

```swift
if let selection {
    let selectedRows = table.chartRows.filter {
        selection.sourceRowIDs.contains($0.chartRowID)
    }
}
```

Selection is exact for prepared marks; it isn't a predicate or approximate range.
Category selection matches collision-safe rendered category labels. Temporal and
quantitative selection chooses the nearest rendered x position and includes every
series at that position. Donut selection resolves cumulative angle to the
corresponding sector. Empty or lineage-free matches clear selection rather than
publishing an empty selection. A multi-mark selection combines values only when its
aggregation supports a meaningful combined summary.

### Navigate dense charts

Explore mode enables scrolling when the prepared data exceeds family-specific
density thresholds:

- More than 10 categories scroll on the categorical axis.
- More than 12 temporal marks scroll horizontally.
- More than 30 quantitative x values scroll horizontally.

A magnification gesture increases the visible-domain zoom up to 12 times. Reset
Zoom restores the full domain. The implementation deliberately doesn't provide
range brushing; bound selection always represents concrete rendered marks.

### Present warnings and invalid input

Incomplete results display the recommendation warning below the chart. A
caller-provided specification is validated in the view; validation errors replace
the chart with a readable diagnostic. Call
``AutoChartEngine/validate(specification:for:)`` before rendering when the parent
flow needs to disable controls or present errors elsewhere.

### Accessibility behavior

The chart container exposes its title or family name as an accessibility label
and a stable family-based accessibility identifier. Marks describe their label
and formatted value. Clear Selection and Reset Zoom have explicit identifiers,
and the selected value summary combines its label, formatted value, and number of
contributing source rows.

Keep an accessible table or detail representation available for exact lookup.
Color is used with position, shape, labels, or panel separation rather than as
the sole carrier of quantitative meaning. These practices align with WCAG's
[Use of Color](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)
and [Non-text Content](https://www.w3.org/WAI/WCAG22/Understanding/non-text-content.html)
guidance.
