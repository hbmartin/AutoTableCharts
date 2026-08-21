# ``AutoChartTable``

Expose typed rows, stable lineage, semantic hints, and completeness.

## Overview

The table has a primary associated `RowID: Hashable & Sendable`. Every row ID
must be unique within a snapshot and is preserved in prepared marks and
``AutoChartSelection``. The analyzer validates duplicate column IDs, duplicate
row IDs, and inconsistent row values before profiling.

Use ``AutoChartDataset`` when data is already row-major. It validates eagerly,
shares its immutable flat storage with analyzer snapshots, and supplies offset
IDs for `AutoChartDataset<Int>`.

Custom conformances supply columns, rows, metadata, and optionally
``AutoChartTable/chartDataKey``. The key is a performance contract, not a source
of truth: change its revision whenever any chart-affecting input changes.

## Topics

- ``AutoChartRow``
- ``AutoChartDataset``
- ``AutoChartDatasetError``
- ``AutoChartColumn``
- ``AutoChartColumnHints``
- ``AutoChartTableMetadata``
- ``AutoChartValue``
- ``AutoChartDataKey``
- <doc:ModelingTypedTables>
