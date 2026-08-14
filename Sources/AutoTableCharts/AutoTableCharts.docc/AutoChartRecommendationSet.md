# ``AutoChartRecommendationSet``

Consume a bounded, deterministic recommendation result and its fallback state.

## Overview

The result preserves rank order in ``recommendations`` and records why only a
table was safe in ``fallbackReason``. Use ``chartRecommendations`` when a UI
should omit the table fallback, but keep the fallback reason and original table
available so an empty chart gallery remains explainable.

Scores are relative within one input, context, option set, and recommendation
policy version. Read each recommendation's rationale and warnings alongside its
score rather than treating the score as confidence.

## Topics

### Consume Results

- ``recommendations``
- ``chartRecommendations``
- ``fallbackReason``
- ``AutoChartRecommendation``

### Interpret Behavior

- <doc:GeneratingRecommendations>
- <doc:RecommendationPipeline>
- <doc:SafetySemanticsAndCompleteness>

