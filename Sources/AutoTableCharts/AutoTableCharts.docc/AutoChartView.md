# ``AutoChartView``

Render validated recommendations and specifications with native Swift Charts.

## Overview

The view snapshots the supplied table, validates the specification, prepares
family-specific marks, and retains source-row IDs through grouping and binning.
Recommendation initialization also presents its rationale and warnings.

Use ``AutoChartInteraction/preview`` for compact galleries and
``AutoChartInteraction/explore`` for selection, dense-domain scrolling, and
zoom. Bind ``AutoChartSelection`` when a chart should coordinate with a table or
detail view.

## Topics

### Create a View

- ``init(table:recommendation:selection:interaction:height:)``
- ``init(table:specification:selection:interaction:height:)``
- ``body``

### Interaction

- ``AutoChartInteraction``
- ``AutoChartSelection``
- <doc:RenderingAndInteraction>

### Safe Input

- ``AutoChartEngine/validate(specification:for:)``
- <doc:CustomSpecifications>

