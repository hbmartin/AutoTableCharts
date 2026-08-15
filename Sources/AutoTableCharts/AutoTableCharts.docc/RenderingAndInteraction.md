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
corresponding sector. A multi-mark selection combines values only when its
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
