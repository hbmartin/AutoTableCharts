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

Text is parsed as temporal only when every non-null value parses as ISO 8601 or
`YYYY-MM-DD`. Mixed date and non-date text remains nominal so rendering never
silently discards the non-date rows. Numeric columns are inferred as ordinal years
only when `year` is a complete name token, every value is an integer from 1000
through 3000, and there are at most 100 distinct values. Identifier detection
recognizes a final `id` token in snake case, spaced names, and camel case.

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
- ``AutoChartAggregationSafety/alreadyAggregated`` permits a sum rollup only
  when the source aggregation is sum or ordinary count. Distinct counts remain
  non-additive.
- ``AutoChartAggregationSafety/unsafe`` explicitly prohibits rollup.

An average, ratio, balance, or repeated value from a one-to-many join can be
numeric and still be unsafe to sum. Describe column and table grain whenever
upstream query semantics are available.

### Mark incomplete results

Set ``AutoChartTableMetadata/isTruncated`` when the rows are only a prefix,
sample, or otherwise incomplete. The engine keeps descriptive row-level views
that remain meaningful, attaches a visible warning, and suppresses totals,
composition, categorical frequency, and other families that imply completeness.
