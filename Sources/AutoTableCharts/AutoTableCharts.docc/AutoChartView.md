# ``AutoChartView``

Compose an immutable prepared chart with optional package chrome.

## Overview

Rendering accepts only ``AutoChartPreparedChart`` or an analysis whose primary
chart was already prepared. No profiling, recommendation, validation, or mark
preparation occurs during SwiftUI view construction.

```swift
AutoChartView(
    preparedChart: prepared,
    selection: $selection,
    presentation: .explorer(plotHeight: 320),
    formatters: formatters,
    textResolver: resolver)
```

Use ``AutoChartPlot`` when the host owns titles, diagnostics, controls, and
selection summaries. ``AutoChartPresentation`` controls exact plot-region
height, chrome, interactions, and typography independently.

## Topics

- ``AutoChartPlot``
- ``AutoChartPreparedChart``
- ``AutoChartPresentation``
- ``AutoChartChrome``
- ``AutoChartInteractions``
- ``AutoChartTypography``
- ``AutoChartSelection``
- <doc:RenderingAndInteraction>
