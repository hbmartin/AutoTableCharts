# Modeling Typed Tables

Supply stable identities and explicit semantics so preparation preserves meaning.

## Overview

### Choose row identity

``AutoChartRow`` and ``AutoChartTable`` carry a caller-defined `RowID`. Use the
identifier needed by linked filtering—an integer result offset, UUID, database
key, or composite value. IDs must be unique within one table. Conditional
`Codable` conformance is available for datasets and selections when `RowID` is
`Codable`.

### Preserve physical types

| Source | ``AutoChartValue`` | Behavior |
| --- | --- | --- |
| Missing | `.null` | Omitted, never coerced to zero |
| Boolean | `.boolean` | Categorical |
| Integer | `.integer` | Quantitative unless hinted otherwise |
| Floating point | `.double` | Non-finite values are diagnosed and omitted |
| Decimal | `.decimal` | Base-10 input retained until positioning |
| Text | `.text` | Nominal unless safely inferred or hinted temporal |
| Date | `.date` | Temporal |
| Binary | `.binary` | Unsupported for chart channels |

Explicit semantic type and role hints take precedence over inference. Unit
hints control formatting but never authorize arithmetic.

### Describe measure truth

``AutoChartMeasureSemantics`` has three independent parts:

- `source` records `.rowLevel`, `.aggregated(operation)`, or `.derived`.
- `rollup` declares `.additive`, `.nonAdditive`, `.safe(operation)`, or `.unknown`.
- `preferredTransform` ranks a compatible transform but cannot bypass safety.

Additive values roll up with sum. A safe rollup must use its declared operation.
Non-additive and unknown values block implicit aggregation. A mean, percentage,
ratio, inventory balance, or distinct count is not additive merely because it is
numeric.

### Describe result completeness

Set ``AutoChartTableMetadata/isTruncated`` for pages, previews, limits, samples,
or any incomplete population. This suppresses totals, composition, and other
families that would overstate partial data while retaining truthful row-level
views with diagnostics.

### Supply a reuse key

``AutoChartDataKey`` avoids repeated fingerprint scans. Its revision must change
for row order, row IDs, values, columns, hints, or metadata. If that contract is
inconvenient, omit the key and let the analyzer fingerprint and compare input.
