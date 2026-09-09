# Rendering and Interaction

Render memoized presentation data and link chart marks to source rows.

## Overview

``AutoChartSession`` publishes analyzing, preparing, ready, fallback, and failed
states while preventing superseded work from replacing newer state. Two
sessions can share one core cache while retaining independent preferences and
selections.

``AutoChartPresenter`` performs localization, formatting, ordering, and
histogram label resolution before SwiftUI evaluates a chart body. Its memoized
result is an ``AutoChartPresentedChart`` keyed by prepared-chart identity and
``AutoChartPresentationContext``.

`AutoChartSelectionSet` is ordered and provenance-safe. A click replaces its
selection; Command-click toggles marks. Every selected mark carries its analysis
and prepared-chart identities, and `unionedSourceRows` supports linked table
filtering. External binding updates are reflected by chart highlighting.

Use the environment modifiers `autoChartPresentationContext(_:)`,
`autoChartFormatters(_:)`, `autoChartTextResolver(_:)`,
`autoChartPalette(_:)`, and `autoChartTheme(_:)` to configure a subtree.
