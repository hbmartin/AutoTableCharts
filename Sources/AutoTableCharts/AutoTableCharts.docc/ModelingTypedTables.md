# Modeling Typed Tables

Supply stable identities and explicit semantics so recommendations preserve the
meaning of your result.

## Overview

### Keep identity separate from presentation

``AutoChartColumnID`` connects metadata, values, and chart encodings. Keep it
stable even if a visible name changes. ``AutoChartRowID`` connects chart marks
back to source records and must uniquely identify each supplied row.

The engine snapshots `chartColumns` and `chartRows` at the start of a request.
It reads each declared column from each row, but doesn't retain or mutate the
consumer's collection.

### Preserve physical types

Use the narrowest appropriate ``AutoChartValue`` case:

| Source value | Recommended case | Behavior |
| --- | --- | --- |
| Missing | ``AutoChartValue/null`` | Omitted from marks; never converted to zero |
| Boolean | ``AutoChartValue/boolean(_:)`` | Treated as a categorical dimension |
| Integer | ``AutoChartValue/integer(_:)`` | Quantitative unless hints say otherwise |
| Floating point | ``AutoChartValue/double(_:)`` | Non-finite values aren't chartable |
| Decimal | ``AutoChartValue/decimal(_:)`` | Converted for native chart positioning |
| Text | ``AutoChartValue/text(_:)`` | Nominal by default; ISO dates can be temporal |
| Date | ``AutoChartValue/date(_:)`` | Temporal |
| Binary | ``AutoChartValue/binary(_:)`` | Unsupported |

Text is parsed as temporal only when all values are dates, or at least two values
and 80 percent of the non-null values parse as ISO 8601 or `YYYY-MM-DD` dates.
Numeric columns whose name contains `year` and have at most 100 distinct values
are inferred as ordinal. Names equal to `id`, ending in `_id`, or ending in
` id` are inferred as identifiers.

### Override inference with hints

``AutoChartColumnHints/semanticType`` and ``AutoChartColumnHints/role`` take
priority over inference. Use them when a number is an identifier, an integer is
an ordered category, text represents a date, or a domain-specific field should
serve as a series or interval endpoint.

Unit hints affect number formatting. A fractional percent multiplies stored
values by 100 for presentation, while a non-fractional percent is already stored
on the zero-to-100 scale.

### Describe aggregation truth

Aggregation safety is distinct from physical type:

- ``AutoChartAggregationSafety/unknown`` blocks implicit rollups.
- ``AutoChartAggregationSafety/rowLevel`` records row-grain data but doesn't
  declare it additive.
- ``AutoChartAggregationSafety/safe`` permits the declared aggregation, or a
  sum when no aggregation is declared.
- ``AutoChartAggregationSafety/alreadyAggregated`` permits rollup only when the
  source aggregation is sum, count, or distinct count.
- ``AutoChartAggregationSafety/unsafe`` explicitly prohibits rollup.

An average, ratio, balance, or repeated value from a one-to-many join can be
numeric and still be unsafe to sum. Describe column and table grain whenever
upstream query semantics are available.

### Mark incomplete results

Set ``AutoChartTableMetadata/isTruncated`` when the rows are only a prefix,
sample, or otherwise incomplete. The engine keeps descriptive row-level views
that remain meaningful, attaches a visible warning, and suppresses totals,
composition, categorical frequency, and other families that imply completeness.
