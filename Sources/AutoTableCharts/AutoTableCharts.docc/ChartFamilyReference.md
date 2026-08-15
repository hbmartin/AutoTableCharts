# Chart Family Reference

Choose among the 18 implemented families without weakening the engine's safety checks.

## Overview

### Read the matrix

“Complete” means ``AutoChartTable/chartMetadata`` must report
``AutoChartTableMetadata/isTruncated`` as `false`. A safe rollup means the measure
is explicitly marked ``AutoChartAggregationSafety/safe``, or is
``AutoChartAggregationSafety/alreadyAggregated`` with a sum or count aggregation.
Generated recommendations also obey the limits in ``AutoChartOptions``.

| Family | Required encodings | Generated when | Aggregation and completeness | Explore interaction |
| --- | --- | --- | --- | --- |
| ``AutoChartFamily/table`` | None | No safe visual candidate survives, or the input is empty | Never aggregates; allowed for complete and truncated results | Scrollable rows; no mark selection or zoom |
| ``AutoChartFamily/kpi`` | Quantitative `y` | Exactly one complete row has a nonmissing measure | Complete result; preserves the row's value | Read-only value |
| ``AutoChartFamily/bar`` | Categorical `x`, quantitative `y` | A complete, bounded-cardinality dimension can be compared with a measure | Uses no aggregation at a unique category grain; otherwise requires a declared safe rollup | Category selection; scroll and zoom beyond 10 categories |
| ``AutoChartFamily/rankedDot`` | Categorical `x`, quantitative `y` | The same inputs as a bar chart | Same safety as bar; generated in descending order | Category selection; scroll and zoom beyond 10 categories |
| ``AutoChartFamily/groupedBar`` | Categorical `x` and `series`, quantitative `y` | A second dimension has 2…`maximumSeries` values | Complete result; no aggregation at a unique category/series grain, otherwise a declared safe rollup | Grouped mark selection; categorical scroll and zoom |
| ``AutoChartFamily/stackedBar`` | Categorical `x` and `series`, quantitative `y` | Grouped-bar conditions hold and the measure is positive and explicitly additive | Complete result and safe composition only | Segment selection; categorical scroll and zoom |
| ``AutoChartFamily/normalizedBar`` | Categorical `x` and `series`, quantitative `y` | Stacked-bar conditions hold | Complete result and safe composition; normalizes each category to proportions | Segment selection; categorical scroll and zoom |
| ``AutoChartFamily/line`` | Ordered or temporal `x`, quantitative `y`; optional `series` | Time or ordinal order can show change; a series is added only at low cardinality | Preserves result rows; truncated results are allowed with a warning | Nearest temporal selection; temporal scroll and zoom beyond 12 marks |
| ``AutoChartFamily/pointLine`` | Ordered or temporal `x`, quantitative `y` | The same ordered inputs as a line chart | Preserves result rows; truncated results are allowed with a warning | Nearest temporal selection; temporal scroll and zoom |
| ``AutoChartFamily/area`` | Ordered or temporal `x`, nonnegative quantitative `y` | A nonnegative temporal measure has a meaningful zero baseline | Preserves result rows; truncated results are allowed with a warning | Nearest temporal selection; temporal scroll and zoom |
| ``AutoChartFamily/scatter`` | Quantitative or temporal `x`, quantitative `y` | Two measures can reveal a relationship | Preserves result rows; truncated results are allowed with a warning | Nearest quantitative or temporal mark selection; zoom beyond 30 quantitative x values |
| ``AutoChartFamily/bubble`` | Quantitative or temporal `x`, quantitative `y`, and quantitative `size` | Two measures exist and a distinct nonnegative third measure can encode area | Preserves result rows; truncated results are allowed with a warning | Nearest mark selection and quantitative/temporal zoom |
| ``AutoChartFamily/histogram`` | Quantitative `x` | A measure can be binned | Counts rows in 5…20 bins; truncated results are allowed but describe only returned rows | Bin selection returns all contributing row IDs; quantitative zoom beyond 30 bins/values |
| ``AutoChartFamily/boxPlot`` | Quantitative `y`; optional categorical `x` | A measure has a distribution; grouping is limited to at most 10 categories | Computes five-number summaries over returned rows; truncated results are allowed with a warning | Group selection returns the contributing source rows |
| ``AutoChartFamily/heatmap`` | Two categorical fields in `x` and `y` | Both dimensions fit `maximumCategories` | Complete result; counts rows per cell | Cell selection returns all contributing row IDs |
| ``AutoChartFamily/donut`` | Categorical `x`, quantitative `y` | Few categories form a complete, positive, additive whole | Complete result; safe sum or ordinary count; at most `maximumDonutSectors` sectors | Angle selection resolves a sector and all contributing row IDs |
| ``AutoChartFamily/range`` | Categorical label in `x`, temporal `start` and `end` | Complete interval data has two temporal fields; a single date can represent an event with equal start/end | Never aggregates; complete result; every start must be no later than its end | Category selection; categorical scroll and zoom |
| ``AutoChartFamily/faceted`` | Categorical `facet`, quantitative `y`, and categorical, quantitative, temporal, or ordinal `x` | A line, bar, or scatter candidate can be split into 2…`maximumFacets` panels | Inherits the base candidate's preparation and completeness rules | Mark selection preserves row lineage within panels |

### Separate generation from validation

The matrix describes both engine generation and hard validation. Generation is
intentionally narrower: for example, the engine only proposes grouped bars after
checking cardinality and grain. Validation accepts a caller specification only
when its required channel types and safety invariants hold; it doesn't promise
that the engine would rank or generate that exact combination.

The renderer prepares the accepted specification rather than querying the source
again. Aggregated marks union their ``AutoChartRow/chartRowID`` values, so a
selection can always be traced back to the returned input rows.

### See also

- <doc:GeneratingRecommendations>
- <doc:CustomSpecifications>
- <doc:SafetySemanticsAndCompleteness>
- ``AutoChartFamily``
