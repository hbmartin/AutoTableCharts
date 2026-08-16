# Recommendation Pipeline

Follow the implemented path from caller-owned rows to deterministic Swift Charts.

## Overview

### 1. Snapshot the typed table

``AutoChartEngine/recommendations(for:context:options:)`` synchronously copies
each declared column value and stable row ID into a private snapshot. This makes
the remainder of a recommendation run internally consistent without mutating the
table or retaining its concrete row type. The engine examines all returned rows;
it doesn't sample them.

### 2. Profile and infer semantics

Each column profile records non-null and distinct counts, null fraction, numeric
extent, positivity, average text length, and parsed dates. Explicit
``AutoChartColumnHints/semanticType`` wins. An identifier role or final `id` name
token—including snake case, spaced names, and camel case—wins next. Otherwise the profiler recognizes
booleans, dates, numeric columns, year-like ordinals, binary data, and finally
nominal text.

Date inference requires every non-null value to parse, preventing mixed text from
being silently omitted during rendering. A numeric column is year-like only when
`year` is a complete name token, all values are integer years from 1000 through
3000, and it has no more than 100 distinct values. These are fixed rules, not
learned predictions.

### 3. Enumerate candidates

The engine traverses compatible profile combinations and constructs candidate
specifications for the families in <doc:ChartFamilyReference>. Enumeration
incorporates task-independent constraints early: category, series, donut, and
facet limits; positive baselines; unique grains; interval roles; and explicit
aggregation safety. Truncated results suppress totals, categorical rollups,
frequency heatmaps, composition, and ranges before ranking.

Profiling still covers every column, while candidate enumeration considers at
most `maximumCandidateColumns` columns per semantic type. This makes combination
and uniqueness work bounded for very wide tables; increase the option when a
later source column must participate in automatic recommendations.

### 4. Apply hard validation

Every generated candidate passes through the same validator exposed by
``AutoChartEngine/validate(specification:for:)``. Hard errors cover missing or
unknown columns, incompatible channel types, incomplete results, unsafe
composition or aggregation, duplicate marks without a safe rollup, and reversed
intervals. Hard validation is a semantic boundary: a high score can never rescue
an invalid chart.

### 5. Rank with the fixed-score policy

The implemented ranking policy is a transparent additive heuristic, versioned by
``AutoTableCharts/recommendationPolicyVersion``. Each family starts with a fixed
base score chosen for its common analytical utility. A candidate receives an
18-point bonus when the requested ``AutoChartContext/goal`` matches the task it
serves. Some candidates can receive more than one applicable bonus—for example,
a bar chart can serve comparison and ranking—but one requested goal matches at
most one of those terms.

This base-score plus task-bonus formula is the policy-v1 scoring model. The
package's public policy version is now 7 because later identity, missing-value,
aggregation-safety, candidate-bound, facet-semantics, non-finite-number,
signed-zero, renderability-aware completeness, and channel-compatibility
hardening can also change recommendation output; version 7 retains the same
transparent scoring formula.

Scores are meaningful only within the candidate set produced for the same
snapshot, options, context, and policy version. They aren't probabilities,
accuracy measures, or claims of statistical significance.

### 6. Resolve ties and diversify

Candidates with the same specification ID are deduplicated by keeping the
highest score. Sorting uses descending score, then the declaration order of
``AutoChartFamily``, then the stable specification ID. The result therefore
doesn't depend on dictionary iteration order.

The first diversification pass takes at most one result from each family. If
``AutoChartOptions/maximumRecommendations`` still has room, a second pass fills
it with remaining ranked candidates. If nothing survives, the result contains a
table fallback with a human-readable reason.

### 7. Prepare render data and preserve lineage

``AutoChartView`` snapshots the same typed table and validates the selected
specification again. Preparation converts rows to renderable datums, groups or
bins only where requested, sorts marks, and computes family-specific summaries.
Every prepared datum carries the union of its contributing source-row IDs.

That final step is how a selected bar, histogram bin, heatmap cell, donut sector,
or box-plot group becomes an exact ``AutoChartSelection/sourceRowIDs`` set. The
lineage identifies rows from the caller's returned table; it doesn't imply a
database query or provenance beyond ``AutoChartTableMetadata/provenance``.

### Reproducibility boundary

For stable output, keep row values, column order and hints, metadata, context,
options, and the recommendation policy version fixed. Generated titles also use
deterministic name humanization. Updating the package may intentionally revise a
later policy version, so persist specifications—not unexplained score cutoffs—if
an application needs a durable visual contract.
