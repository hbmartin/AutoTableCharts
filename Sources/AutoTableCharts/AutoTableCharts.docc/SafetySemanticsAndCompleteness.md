# Safety, Semantics, and Completeness

Prevent a plausible chart from silently changing the meaning of a result.

## Overview

### State what produced a measure

``AutoChartMeasureSemantics/source`` distinguishes raw row-level values,
upstream aggregation, and derived values. Source provenance alone does not grant
permission to combine values.

### State whether values may roll up

``AutoChartMeasureSemantics/rollup`` is the arithmetic contract:

- `.additive` permits sum.
- `.safe(operation)` permits only that operation.
- `.nonAdditive` explicitly prohibits automatic combination.
- `.unknown` blocks implicit aggregation until the host supplies domain truth.

`preferredTransform` influences ranking only when the transform is safe. Upstream
sums and ordinary counts may be additive; means and distinct counts are normally
non-additive unless the host can provide a stronger, truthful contract.

### Declare source grain and relationships

``AutoChartColumn/provenance`` attaches source columns and a typed
``AutoChartGrain`` to a result field. ``AutoChartTableMetadata/semanticModel``
declares one-to-many entity relationships. When a measure is grouped or rolled
up by a strictly finer entity, validation returns the typed `fanOutRisk`
finding—even if repeated result values happen to look harmless.
Scatter and bubble charts likewise reject incomparable child-grain measure
pairs that can form a chasm trap across two one-to-many joins.

Grain validation is a presentation boundary, not a query engine. The package
never deduplicates or rewrites already-aggregated values: the host must correct
the upstream result and submit a new request.

### Require honest composition

Donut, stacked-bar, and normalized-bar specifications require a complete result,
strictly positive and nonmissing measure values, and additive rollup semantics.
This prevents partial wholes and negative sectors. The host remains responsible
for knowing whether categories form a meaningful whole.

### Mark incomplete populations

Set ``AutoChartTableMetadata/isTruncated`` for incomplete rows. The policy keeps
descriptive families that can honestly describe the returned subset and blocks
totals, composition, categorical frequency, and ranges that imply a complete
population. Diagnostics remain typed and localizable.

### Preserve exact lineage

Every prepared mark stores a set of the caller's `RowID`. Raw marks normally
contain one ID; aggregate marks, histogram bins, heatmap cells, donut sectors,
and statistical groups contain every contributing ID. Lineage is exact relative
to the supplied snapshot. Source-domain lineage is only as complete as the
host-declared column provenance and semantic model.

### Fall back without coercion

When no candidate survives, ``AutoChartRecommendationOutcome/tableFallback(_:)``
contains a stable message and diagnostics. Keep the table visible rather than
relaxing semantics or converting missing values to zero.
