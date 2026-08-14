# ``AutoChartTable``

Expose typed rows, column meaning, and result completeness to the engine.

## Overview

Conformance is an adapter over caller-owned storage. The table supplies a stable
column schema, rows conforming to ``AutoChartRow``, and metadata that defines the
trust boundary for totals and composition. Recommendation snapshots these values
for one synchronous run and doesn't mutate the table.

Declare semantic and aggregation hints whenever inference could confuse an
identifier, date, year, rate, balance, or preaggregated measure.

## Topics

### Required Data

- ``chartColumns``
- ``chartRows``
- ``chartMetadata``
- ``AutoChartRow``

### Schema and Meaning

- ``AutoChartColumn``
- ``AutoChartColumnHints``
- ``AutoChartTableMetadata``
- ``AutoChartValue``

### Guides

- <doc:ModelingTypedTables>
- <doc:SafetySemanticsAndCompleteness>

