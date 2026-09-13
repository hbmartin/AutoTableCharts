# Research Foundations and Boundaries

Relate the package's implemented rules to visualization research without implying features it doesn't contain.

## Overview

### Implemented lineage

AutoTableCharts follows the classic separation between data semantics,
expressive graphical encodings, and perceptual effectiveness introduced by
[APT](https://doi.org/10.1145/22949.22950). Its preference for position and
length for common comparisons is consistent with
[Cleveland and McGill's graphical perception experiments](https://doi.org/10.1080/01621459.1984.10478080).
These works motivate the policy; the package implements explicit Swift rules,
not their original algorithms or experimental models.

The table-to-candidate workflow is closest in spirit to constraint-oriented
visualization recommendation systems. [Show Me](https://doi.org/10.1109/TVCG.2007.70594)
demonstrates automatic presentation from selected fields;
[CompassQL](https://doi.org/10.1145/2939502.2939506) formalizes query and ranking
over a visualization design space; and
[Voyager 2](https://doi.org/10.1145/3025453.3025768) couples recommendations with
faceted browsing. AutoTableCharts implements a deliberately smaller native chart
space, hard semantic checks, deterministic enumeration, descriptive signal
scoring, and a bounded set-selection objective.

The separation of inviolable validation from weighted preference resembles the
constraint model explored by [Draco](https://doi.org/10.1109/TVCG.2018.2865240).
AutoTableCharts does not embed Draco or learn constraint weights. Its current
policy keeps reviewed family and task priors, then adds bounded descriptive
signals and readability costs. The goal vocabulary and its
effectiveness motivation are informed by
[task-based visualization effectiveness research](https://doi.org/10.1109/TVCG.2018.2829750),
while task descriptions can also be understood through the why/what/how framing
of [Brehmer and Munzner](https://doi.org/10.1109/TVCG.2013.124).

The implemented safety rules are package-specific engineering commitments. In
particular, explicit additive aggregation, complete-result restrictions,
deterministic tie-breaking, and source-row lineage are derived from the current
code's need to avoid misleading charts over typed application results; they
should not be attributed wholesale to any one cited system.

### Approaches not implemented

AutoTableCharts does **not** implement the following research directions:

- Learned visualization ranking or classification such as
  [DeepEye](https://doi.org/10.1109/ICDE.2018.00019) and
  [VizML](https://doi.org/10.1145/3290605.3300358). There is no training corpus,
  model file, remote inference, or probability score.
- Statistical significance and reference-population view search such as
  [SeeDB](https://doi.org/10.14778/2831360.2831371) and
  [Foresight](https://arxiv.org/abs/1709.10513). The engine computes local
  descriptive statistics such as Pearson/Spearman association, group effect,
  skewness, and outlier fraction, but doesn't test significance, compare against
  a reference population, or claim that a recommendation is “interesting.”
- Natural-language or LLM interpretation. Column names influence only narrow,
  documented identifier/year inference and generated titles; prompts and free
  text aren't sent to a model.
- User-personalized ranking. Goals adjust a reviewed score, but the package doesn't
  learn from clicks, history, expertise, device, or organization preferences.
- Coordinated dashboard or multi-view composition such as
  [MultiVision](https://doi.org/10.1109/TVCG.2021.3114826) and
  [GEViTRec](https://doi.org/10.1109/TVCG.2021.3107749). A faceted chart is one
  specification with small multiples, not an automatically composed dashboard.

These boundaries matter when interpreting ``AutoChartRecommendation/score``.
It is a deterministic policy value among currently valid candidates, not a
confidence, utility estimate, causal judgment, or universal chart-quality score.

### Reading implementation claims

Articles in this catalog describe the behavior of the documented package
version. The repository's research notes were used as authoring inputs, but the
published documentation cites original sources directly and doesn't expose raw
reports or opaque intermediate citation markers. For the operational details,
see <doc:RecommendationPipeline> and <doc:SafetySemanticsAndCompleteness>.
