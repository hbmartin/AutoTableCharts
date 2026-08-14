# ``AutoChartEngine``

Generate and validate deterministic chart specifications.

## Overview

The engine is a synchronous, offline namespace. It snapshots an
``AutoChartTable``, profiles columns, enumerates compatible families, applies
hard safety validation, ranks valid candidates with the current policy, and
diversifies the bounded result. Equal inputs produce equal ordering.

Use recommendation output directly when possible. Use validation for a
caller-authored ``AutoChartSpecification``; a valid result means the implemented
hard checks passed, not that the specification is statistically optimal or
domain-correct beyond the supplied metadata.

## Topics

### Generate Recommendations

- ``recommendations(for:context:options:)``
- ``AutoChartContext``
- ``AutoChartOptions``
- ``AutoChartRecommendationSet``

### Validate Specifications

- ``validate(specification:for:)``
- ``AutoChartSpecification``
- ``AutoChartValidationResult``

### Understand the Policy

- <doc:RecommendationPipeline>
- <doc:SafetySemanticsAndCompleteness>
- <doc:ResearchFoundations>

