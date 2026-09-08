# ``AutoTableChartsUI``

Present prepared recommendations with SwiftUI and Swift Charts.

## Overview

`AutoTableChartsUI` re-exports the Foundation-only `AutoTableCharts` core and
adds observable sessions, memoized presentation, native chart rendering,
multi-selection, and environment-driven formatting and themes.

```swift
let cache = AutoChartCache()
let session = AutoChartSession<Int>(cache: cache)

AutoChartSessionView(session: session)
    .task { session.load(request, preference: .automatic) }
```

## Topics

### Lifecycle

- ``AutoChartSession``
- ``AutoChartSessionView``
- ``AutoChartPreparationPlaceholder``

### Presentation

- ``AutoChartPresenter``
- ``AutoChartPresentedChart``
- ``AutoChartPresentationContext``
- ``AutoChartView``
- ``AutoChartPlot``
- ``AutoChartPresentation``
- <doc:RenderingAndInteraction>

### Environment

- ``AutoChartPalette``
- ``AutoChartTheme``
