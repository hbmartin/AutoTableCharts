# Declared grain detects risk but does not invent an upstream repair

AutoTableCharts accepts host-declared source grain and one-to-many relationships so it can reject presentation-time rollups with fan-out risk. It does not deduplicate or rewrite a result whose upstream query may already have destroyed information: the package cannot prove a repair from returned values alone, so authoritative correction remains a host responsibility.
