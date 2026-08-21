# Chart Family Reference

Understand the 17 renderable families and the typed table fallback.

## Overview

The fallback outcome is not an ``AutoChartFamily``. Every listed family produces
a prepared native chart and preserves typed source-row lineage.

| Family | Principal channels | Key generation or validation constraint |
| --- | --- | --- |
| `kpi` | quantitative measure | One complete row |
| `bar` | category, measure | Unique marks or an authorized rollup |
| `rankedDot` | category, measure | Bar safety with ranking-oriented presentation |
| `groupedBar` | category, series, measure | Bounded series and safe mark grain |
| `stackedBar` | category, series, measure | Complete, positive, additive composition |
| `normalizedBar` | category, series, measure | Stacked safety with proportional normalization |
| `line` | ordered/temporal x, measure | Ordered rows; optional bounded series |
| `pointLine` | ordered/temporal x, measure | Line safety with visible points |
| `area` | ordered/temporal x, measure | Nonnegative meaningful baseline |
| `scatter` | quantitative/temporal x, quantitative y | Two compatible position fields |
| `bubble` | scatter fields plus size | Distinct nonnegative size field |
| `histogram` | quantitative value | Frequency bins over returned rows |
| `boxPlot` | measure, optional category | Five-number summaries over returned rows |
| `heatmap` | two categorical dimensions | Complete bounded categorical frequency |
| `donut` | category, measure | Complete, positive, additive whole |
| `range` | label, temporal start/end | Complete intervals with start no later than end |
| `faceted` | facet plus base-family channels | Two through the configured maximum facets |

Generation is intentionally narrower than validation. A caller specification is
accepted only when it passes hard semantic checks, but acceptance does not imply
that automatic policy would rank or generate that design.

Facets use the requested total plot height and divide it among panels; they do
not impose a hidden per-panel height. Use family-specific
``AutoChartSpecification`` factories to construct each design.
