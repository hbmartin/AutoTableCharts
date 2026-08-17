# Safety, Semantics, and Completeness

Prevent a plausible-looking chart from silently changing what a table means.

## Overview

### Express meaning explicitly

Values alone rarely establish whether a number is an amount, an identifier, a
rate, or an already-computed total. ``AutoChartColumnHints`` supplies that
missing contract:

- `semanticType` controls channel compatibility.
- `role` separates identifiers, dimensions, measures, series, labels, and
  interval boundaries.
- `unit` controls value formatting; it does not authorize arithmetic.
- `aggregation` describes the existing or intended summary operation.
- `aggregationSafety` states whether a rollup is semantically allowed.
- `grain` records what one value represents for readers and callers.

Explicit hints override inference. Prefer them for production data, especially
for identifiers encoded as numbers, fiscal years, rates, ratios, balances, and
preaggregated query results.

### Distinguish grain from aggregation

For bars, grouped bars, and connected series, the renderer needs one mark per
encoded category or x/series key. If the returned rows are already unique at that
mark grain, ``AutoChartAggregation/none`` preserves them. Duplicate keys require
an aggregation for categorical marks and are rejected for generated connected
series. For ``AutoChartAggregationSafety/safe`` values, the engine honors a
declared aggregation or defaults to sum.

``AutoChartAggregationSafety/rowLevel`` doesn't mean “safe to sum”; it says the
measure is at a more detailed row grain and requires domain knowledge before a
rollup. ``AutoChartAggregationSafety/alreadyAggregated`` permits another sum only
when the declared existing aggregation is `sum` or `count`; the downstream
rollup operation is `sum` in both cases. Distinct counts aren't additive without
an explicit guarantee that their underlying populations are disjoint.
``AutoChartAggregationSafety/unsafe`` and
``AutoChartAggregationSafety/unknown`` block inferred rollups.

This is intentionally conservative. A price, percentage, median, inventory
balance, or distinct count can be numeric and still be non-additive across a new
dimension.

Finite endpoints do not guarantee a renderable axis: subtracting two extreme
finite numbers can still overflow. Validation rejects quantitative and temporal
fields whose observed span is not finite, and domain padding falls back to the
unmodified finite-span range when padding alone would overflow.

### Mark incomplete results

Set ``AutoChartTableMetadata/isTruncated`` whenever the table is a page, preview,
limit, or otherwise incomplete slice of a larger result. The engine then permits
families that can honestly describe returned observations—line, point-line,
area, scatter, bubble, histogram, box plot, facets, and table fallback—and adds a
warning where appropriate.

It rejects families whose meaning depends on a complete whole or complete
frequency set: KPI, bars and ranked dots, grouped/stacked/normalized bars,
heatmaps, donuts, and ranges. A histogram or box plot over truncated data is not
a population estimate; it describes only the returned rows.

### Protect composition

Donut, stacked-bar, and normalized-bar charts require all of the following:

1. A complete result.
2. Strictly positive observed values.
3. An explicitly additive measure.
4. No missing category, series, or measure values.
5. A bounded number of categories or series during generation.

These checks prevent partial wholes, negative sectors, and sums of non-additive
metrics. They don't prove that categories are mutually exclusive or collectively
exhaustive; the table adapter remains responsible for that domain contract.

### Preserve source-row lineage

Raw marks retain one ``AutoChartRowID``. Aggregated marks, bins, cells, sectors,
and statistical groups retain the set union of every contributing returned row.
``AutoChartSelection`` therefore supports linked highlighting and detail lookup
without reverse-engineering chart coordinates.

Row IDs should be stable and unique within the table. Lineage is exact relative
to the supplied snapshot, but it doesn't reach through a summarized row to the
database records that produced it. Use ``AutoChartTableMetadata/provenance`` and
your own identifiers when that deeper audit trail matters.

### Handle conservative fallbacks

If no candidate survives, ``AutoChartRecommendationSet/fallbackReason`` explains
why and the recommendations array contains a table specification. Present the
table rather than stripping metadata or coercing an unsafe chart. To make a
visual possible, improve the upstream query grain or supply accurate semantic
and aggregation hints—not merely a more permissive score threshold.
