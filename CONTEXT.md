# AutoTableCharts

AutoTableCharts turns a typed result table into deterministic chart recommendations without changing the result's meaning.

## Language

**Result Grain**:
The source-entity keys required to identify one returned row.
_Avoid_: row level, table grain

**Source Grain**:
The source-entity keys at which a result column's values are defined before presentation-time aggregation.
_Avoid_: column grain, granularity string

**Observed Uniqueness**:
A value-level property of the returned snapshot showing that a column or column combination happens to identify its rows.
_Avoid_: inferred grain, declared grain

**Fan-out Risk**:
A proposed rollup of a measure across a dimension at a finer Source Grain, where a one-to-many join may repeat the measure.
_Avoid_: proven double count, automatic repair

**Semantic Model**:
The host-declared source entities and one-to-many relationships used to compare grains.
_Avoid_: inferred schema, join parser

**Recommendation Signal**:
A bounded descriptive statistic that refines the order of already-valid chart candidates.
_Avoid_: confidence, significance

**Featured Set**:
The small, jointly selected group of chart alternatives shown before the full recommendation catalog.
_Avoid_: top five families
