# Recommendation Pipeline

Follow one asynchronous request from validated input to an eager primary chart.

## Overview

### 1. Validate and snapshot

The analyzer rejects row-width mismatches, row-ID count mismatches, duplicate
column IDs, and duplicate row IDs. It stores compact row-major values rather than
per-row dictionaries. ``AutoChartDataset`` can share immutable storage directly.

### 2. Profile

Every column is scanned once. Public ``AutoChartColumnProfile`` values summarize
nulls, distinct values, type evidence, numeric extent, quantiles, skewness,
category entropy, sign/zero fractions, and temporal regularity without exposing
retained raw data. Cancellation is checked in bounded row chunks.

### 3. Generate and validate

The policy enumerates every bounded compatible series, facet, group, and size
choice; applies cardinality, completeness, channel, typed-grain, and
measure-semantic constraints; then validates each candidate.
Hard rejection cannot be overcome by score. Candidate enumeration may be bounded
for very wide schemas, but profiling and caller-specification validation cover
every column.

### 4. Rank and diversify

Valid candidates use a deterministic decomposition exposed as
``AutoChartScoreBreakdown``: family prior + task fit + preferred transform + a
bounded descriptive data signal - readability cost. A signal ranks but never
validates and is not a significance or confidence claim. Ties use family order
and structural specification identity.

Featured choices are then selected by a greedy set objective that rewards new
fields and analytical tasks while penalizing repeated data queries and closely
related visual families. The larger catalog remains score ordered.

### 5. Prepare exactly once

The first recommendation is validated and converted into family-specific marks
during analysis. Every mark retains the union of contributing typed source row
IDs. Alternative recommendations and caller specifications prepare only through
explicit async analysis methods.

### 6. Retain at analyzer scope

LRU layers retain table/profile nodes, analyses, and prepared charts with shared
object byte accounting. Reuse keys include data identity/revision or content
fingerprint, context, options, policy version, and specification. Identical
in-flight analysis calls are coalesced.

Formatting and text resolution occur later and therefore do not participate in
analysis or preparation cache keys.
