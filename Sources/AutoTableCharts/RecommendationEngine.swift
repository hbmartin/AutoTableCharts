import Foundation

private protocol AutoChartRecommendationComparisonObserving {
    func recordComparison()
}

private struct AutoChartNoOpComparisonObserver: AutoChartRecommendationComparisonObserving {
    @inline(__always)
    func recordComparison() {}
}

#if ATC_TEST_HOOKS
private struct AutoChartComparisonObserverForTesting:
    AutoChartRecommendationComparisonObserving
{
    let body: () -> Void

    @inline(__always)
    func recordComparison() { body() }
}
#endif

/// Profiles typed tables and returns a deterministic, semantically safe set of charts.
///
/// The engine generates candidates from table structure, rejects candidates that
/// violate hard constraints, ranks the survivors for the requested task, and
/// returns a bounded set with diverse chart families. It runs synchronously and
/// entirely offline.
enum AutoChartRecommendationEngine {
    /// Summarizes every candidate category/measure pair in one snapshot pass.
    /// Per-pair identity retention stops at one beyond the recommendation limit,
    /// which is enough to distinguish an accepted cardinality from overflow.
    fileprivate struct BoxPlotCategoryIndex {
        private struct Request: Hashable {
            var categoryID: AutoChartColumnID
            var measureID: AutoChartColumnID
        }

        private struct Summary {
            var boundedCategoryCount: Int
            var includesMissing: Bool
        }

        private final class MeasureMembership {
            var words: [UInt64]

            init(wordCount: Int) {
                words = Array(repeating: 0, count: wordCount)
            }

            func formUnion(_ other: [UInt64]) {
                precondition(words.count == other.count)
                for wordIndex in words.indices {
                    words[wordIndex] |= other[wordIndex]
                }
            }

            func insert(_ index: Int) {
                words[index / UInt64.bitWidth]
                    |= UInt64(1) << UInt64(index % UInt64.bitWidth)
            }

            func remove(_ index: Int) {
                words[index / UInt64.bitWidth]
                    &= ~(UInt64(1) << UInt64(index % UInt64.bitWidth))
            }

            /// Reports whether this active membership intersects a row and
            /// whether that row can still add to the missing membership.
            func rowStatus(
                for rowWords: [UInt64],
                missingMembership: MeasureMembership
            ) -> (hasActiveMeasure: Bool, needsMissingInspection: Bool) {
                precondition(words.count == rowWords.count)
                precondition(words.count == missingMembership.words.count)
                var hasActiveMeasure = false
                var needsMissingInspection = false
                for wordIndex in words.indices {
                    hasActiveMeasure = hasActiveMeasure
                        || rowWords[wordIndex] & words[wordIndex] != 0
                    needsMissingInspection = needsMissingInspection
                        || rowWords[wordIndex] & ~missingMembership.words[wordIndex] != 0
                    if hasActiveMeasure && needsMissingInspection { break }
                }
                return (hasActiveMeasure, needsMissingInspection)
            }

            /// Adds row members that are still eligible and visits each new index.
            func formUnion(
                _ rowWords: [UInt64],
                constrainedTo eligible: MeasureMembership,
                onInsert: (Int) -> Void
            ) {
                precondition(words.count == rowWords.count)
                precondition(words.count == eligible.words.count)
                for wordIndex in words.indices {
                    var newBits = rowWords[wordIndex]
                        & eligible.words[wordIndex]
                        & ~words[wordIndex]
                    words[wordIndex] |= newBits
                    while newBits != 0 {
                        let bitIndex = newBits.trailingZeroBitCount
                        onInsert(wordIndex * UInt64.bitWidth + bitIndex)
                        newBits &= newBits - 1
                    }
                }
            }

            func contains(_ index: Int) -> Bool {
                words[index / UInt64.bitWidth]
                    & (UInt64(1) << UInt64(index % UInt64.bitWidth)) != 0
            }
        }

        private final class CategoryAccumulator {
            let id: AutoChartColumnID
            let semanticType: AutoChartSemanticType
            var boundedCounts: [Int]
            let activeMeasureMembership: MeasureMembership
            var identityMemberships: [AutoChartValueIdentity: MeasureMembership] = [:]
            // Identity memberships stop updating after count saturation; missing
            // membership remains exhaustive for validation warnings.
            let missingMembership: MeasureMembership

            init(
                profile: AutoChartColumnProfile,
                measureCount: Int,
                wordCount: Int
            ) {
                id = profile.column.id
                semanticType = profile.semanticType
                boundedCounts = Array(repeating: 0, count: measureCount)
                activeMeasureMembership = MeasureMembership(wordCount: wordCount)
                for index in 0..<measureCount {
                    activeMeasureMembership.insert(index)
                }
                missingMembership = MeasureMembership(wordCount: wordCount)
            }
        }

        private static func uniqueProfiles(
            _ profiles: [AutoChartColumnProfile]
        ) -> [AutoChartColumnProfile] {
            var seen: Set<AutoChartColumnID> = []
            return profiles.filter { seen.insert($0.column.id).inserted }
        }

        private static func makeSummaries(
            snapshot: AutoChartSnapshot,
            categories: [AutoChartColumnProfile],
            measures: [AutoChartColumnProfile],
            retainedCategoryLimit: Int
        ) -> [Request: Summary] {
            let wordCount =
                (measures.count + UInt64.bitWidth - 1) / UInt64.bitWidth
            let accumulators = categories.map {
                CategoryAccumulator(
                    profile: $0,
                    measureCount: measures.count,
                    wordCount: wordCount)
            }
            var rowMeasureWords = Array(repeating: UInt64(0), count: wordCount)
            for row in snapshot.rows {
                for wordIndex in rowMeasureWords.indices {
                    rowMeasureWords[wordIndex] = 0
                }
                var hasMeasure = false
                for (index, measure) in measures.enumerated()
                where AutoChartBoxPlotGrouping.measure(
                    in: row,
                    columnID: measure.column.id) != nil {
                    rowMeasureWords[index / UInt64.bitWidth]
                        |= UInt64(1) << UInt64(index % UInt64.bitWidth)
                    hasMeasure = true
                }
                guard hasMeasure else { continue }

                for accumulator in accumulators {
                    // Once a measure's count is saturated and its missing flag is
                    // known, later rows cannot change its summary.
                    let rowStatus = accumulator.activeMeasureMembership.rowStatus(
                        for: rowMeasureWords,
                        missingMembership: accumulator.missingMembership)
                    guard rowStatus.hasActiveMeasure
                        || rowStatus.needsMissingInspection
                    else { continue }

                    let identity = AutoChartBoxPlotGrouping.categoryIdentity(
                        in: row,
                        columnID: accumulator.id,
                        semanticType: accumulator.semanticType)
                    if identity == .missing {
                        accumulator.missingMembership.formUnion(rowMeasureWords)
                    }

                    guard rowStatus.hasActiveMeasure else { continue }
                    let membership: MeasureMembership
                    if let existing = accumulator.identityMemberships[identity] {
                        membership = existing
                    } else {
                        membership = MeasureMembership(wordCount: wordCount)
                        accumulator.identityMemberships[identity] = membership
                    }

                    membership.formUnion(
                        rowMeasureWords,
                        constrainedTo: accumulator.activeMeasureMembership
                    ) { measureIndex in
                        accumulator.boundedCounts[measureIndex] += 1
                        if accumulator.boundedCounts[measureIndex]
                            == retainedCategoryLimit
                        {
                            accumulator.activeMeasureMembership.remove(measureIndex)
                        }
                    }
                }
            }

            var result: [Request: Summary] = [:]
            result.reserveCapacity(accumulators.count * measures.count)
            for accumulator in accumulators {
                for (measureIndex, measure) in measures.enumerated() {
                    result[
                        Request(
                            categoryID: accumulator.id,
                            measureID: measure.column.id)
                    ] = Summary(
                        boundedCategoryCount: accumulator.boundedCounts[measureIndex],
                        includesMissing: accumulator.missingMembership.contains(measureIndex))
                }
            }
            return result
        }

        let snapshotIdentity: UUID
        private let summaries: [Request: Summary]

        init(
            snapshot: AutoChartSnapshot,
            categories: [AutoChartColumnProfile],
            measures: [AutoChartColumnProfile],
            maximumCategoryCount: Int
        ) {
            snapshotIdentity = snapshot.validationIdentity
            let categoryProfiles = Self.uniqueProfiles(categories)
            let measureProfiles = Self.uniqueProfiles(measures)
            let maximum = max(0, maximumCategoryCount)
            let retainedCategoryLimit = maximum == Int.max ? Int.max : maximum + 1
            summaries =
                categoryProfiles.isEmpty || measureProfiles.isEmpty
                ? [:]
                : Self.makeSummaries(
                    snapshot: snapshot,
                    categories: categoryProfiles,
                    measures: measureProfiles,
                    retainedCategoryLimit: retainedCategoryLimit)
        }

        func boundedCategoryCount(
            categoryID: AutoChartColumnID,
            measureID: AutoChartColumnID
        ) -> Int? {
            summaries[
                Request(categoryID: categoryID, measureID: measureID)
            ]?.boundedCategoryCount
        }

        func includesMissing(
            categoryID: AutoChartColumnID,
            measureID: AutoChartColumnID
        ) -> Bool? {
            summaries[
                Request(categoryID: categoryID, measureID: measureID)
            ]?.includesMissing
        }
    }

    private static func boxPlotIncludesMissingCategory(
        snapshot: AutoChartSnapshot,
        categoryID: AutoChartColumnID,
        categorySemanticType: AutoChartSemanticType,
        measureID: AutoChartColumnID,
        memo: AutoChartValidationMemo?,
        cancellationRequested: () -> Bool = { false }
    ) -> Bool {
        if let indexed = memo?.boxPlotIncludesMissing(
            snapshotIdentity: snapshot.validationIdentity,
            categoryID: categoryID,
            measureID: measureID)
        {
            return indexed
        }
        return snapshot.rows.contains { row in
            if cancellationRequested() { return true }
            return AutoChartBoxPlotGrouping.measure(in: row, columnID: measureID) != nil
                && AutoChartBoxPlotGrouping.categoryIdentity(
                    in: row,
                    columnID: categoryID,
                    semanticType: categorySemanticType) == .missing
        }
    }

    static func recommendations<Table: AutoChartTable>(
        for table: Table,
        context: AutoChartContext = .init(),
        options: AutoChartOptions = .init(),
        constraints: AutoChartRecommendationConstraints = .init(),
        featuredLimit: Int? = nil
    ) -> AutoChartCandidateResults {
        recommendations(
            snapshot: AutoChartSnapshot(table),
            context: context,
            options: options,
            constraints: constraints,
            featuredLimit: featuredLimit)
    }

    static func validate<Table: AutoChartTable>(
        specification: AutoChartSpecification,
        for table: Table
    ) -> AutoChartValidationResult {
        validate(specification: specification, snapshot: AutoChartSnapshot(table))
    }

    static func recommendations(
        snapshot: AutoChartSnapshot,
        context: AutoChartContext,
        options: AutoChartOptions,
        constraints: AutoChartRecommendationConstraints = .init(),
        featuredLimit: Int? = nil
    ) -> AutoChartCandidateResults {
        guard !snapshot.rows.isEmpty, !snapshot.columns.isEmpty else {
            return AutoChartCandidateResults(
                recommendations: [],
                fallbackReason: "The result has no chartable rows.")
        }

        let profiles = AutoChartProfiler.profiles(snapshot)
        let profileIndex = AutoChartProfiler.profileIndex(profiles)
        let quantitative = Array(
            profiles.filter {
                $0.isQuantitative && $0.column.hints.role != .identifier
                    && $0.numericValueCount > 0
            }.prefix(options.maximumCandidateColumns))
        let temporal = Array(
            profiles.filter(\.isTemporal).prefix(options.maximumCandidateColumns))
        let categorical = Array(
            profiles.filter {
                $0.isCategorical && $0.column.hints.role != .identifier
                    && $0.distinctCount > 0
            }.prefix(options.maximumCandidateColumns))
        let maximumGroupedBoxPlotCategories = min(10, options.maximumCategories)
        let validationMemo = AutoChartValidationMemo(
            snapshot: snapshot,
            categories: categorical,
            measures: quantitative,
            maximumCategoryCount: maximumGroupedBoxPlotCategories)
        var structuralValidationResults: [AutoChartSpecification: AutoChartValidationResult] = [:]
        func structuralValidation(
            _ specification: AutoChartSpecification,
            cacheResult: Bool
        ) -> AutoChartValidationResult {
            if let cached = structuralValidationResults[specification] { return cached }
            let result = validate(
                specification: specification,
                snapshot: snapshot,
                profiles: profileIndex,
                memo: validationMemo,
                validatesPreparedNumericDomain: false)
            if cacheResult { structuralValidationResults[specification] = result }
            return result
        }
        func cachedStructuralValidation(
            _ specification: AutoChartSpecification
        ) -> AutoChartValidationResult {
            structuralValidation(specification, cacheResult: true)
        }
        var preparedValidationResults: [AutoChartSpecification: AutoChartValidationResult] = [:]
        func cachedPreparedValidation(
            _ specification: AutoChartSpecification
        ) -> AutoChartValidationResult {
            guard requiresPreparedNumericDomainValidation(
                specification: specification,
                profiles: profileIndex)
            else {
                return cachedStructuralValidation(specification)
            }
            if let cached = preparedValidationResults[specification] { return cached }
            let result = validatePreparedNumericDomain(
                structuralValidation: cachedStructuralValidation(specification),
                specification: specification,
                snapshot: snapshot,
                profiles: profileIndex,
                preparedData: nil)
            preparedValidationResults[specification] = result
            return result
        }
        var candidates: [AutoChartRecommendation] = []
        var candidateIndexByID: [AutoChartRecommendationID: Int] = [:]
        var bestBaseScoreByID: [AutoChartRecommendationID: Double] = [:]
        var traceCandidatesByID: [AutoChartRecommendationID: AutoChartRecommendation] = [:]
        var facetBases: [AutoChartRecommendation] = []
        var facetBaseIndexByID: [AutoChartRecommendationID: Int] = [:]
        var descriptiveSignalCache: [DescriptiveSignalCacheKey: DescriptiveSignal] = [:]
        var temporalRegularityCache: [TemporalRegularityCacheKey: Double] = [:]
        let constraintsPermitFaceting = constraints.allowsFamily(.faceted)

        /// Scores and validates candidates as they are generated. Keeping only the
        /// best scored value for each structural ID avoids retaining an additional
        /// unscored candidate array during the high-cardinality size/facet loops.
        func processCandidate(_ recommendation: AutoChartRecommendation) {
            let specification = recommendation.specification
            let isFacetBase = constraintsPermitFaceting
                && [.line, .bar, .scatter].contains(specification.family)
            let isAllowed = constraints.allows(specification)
            guard isFacetBase || isAllowed else { return }
            if isFacetBase {
                if let index = facetBaseIndexByID[recommendation.id] {
                    if facetBases[index].score < recommendation.score {
                        facetBases[index] = recommendation
                    }
                } else {
                    facetBaseIndexByID[recommendation.id] = facetBases.count
                    facetBases.append(recommendation)
                }
            }
            guard isAllowed else { return }
            if let existingScore = bestBaseScoreByID[recommendation.id],
                existingScore >= recommendation.score
            {
                return
            }
            bestBaseScoreByID[recommendation.id] = recommendation.score
            let structural = structuralValidation(
                specification,
                cacheResult: specification.family != .faceted
                    || options.includesDecisionTrace)
            guard structural.isValid else {
                if options.includesDecisionTrace {
                    traceCandidatesByID[recommendation.id] = recommendation
                }
                return
            }
            // Valid faceted candidates are retained below, so retaining their
            // structural result costs no additional specification lifetime and
            // avoids validating them again during catalog construction.
            if specification.family == .faceted, !options.includesDecisionTrace {
                structuralValidationResults[specification] = structural
            }
            let scored = dataAwareRecommendation(
                recommendation,
                snapshot: snapshot,
                profiles: profileIndex,
                descriptiveSignalCache: &descriptiveSignalCache,
                temporalRegularityCache: &temporalRegularityCache)
            if let index = candidateIndexByID[recommendation.id] {
                candidates[index] = scored
            } else {
                candidateIndexByID[recommendation.id] = candidates.count
                candidates.append(scored)
            }
            if options.includesDecisionTrace {
                traceCandidatesByID[recommendation.id] = scored
            }
        }
        let warnings =
            snapshot.metadata.isTruncated
            ? ["Based on the first returned rows; totals and composition are suppressed."]
            : []
        if !snapshot.metadata.isTruncated,
            snapshot.rows.count == 1,
            let measure = quantitative.first(where: { $0.nonNullCount > 0 })
        {
            processCandidate(
                candidate(
                    family: .kpi,
                    y: measure,
                    context: context,
                    score: 98,
                    rationale: ["A single quantitative result is clearest as a key value."]))
        }

        for time in temporal {
            for measure in quantitative {
                processCandidate(
                    candidate(
                        family: .line, x: time, y: measure,
                        context: context,
                        score: 84 + goalBonus(.trend, context.goal),
                        rationale: ["Temporal position reveals change over time."],
                        warnings: warnings))
                processCandidate(
                    candidate(
                        family: .pointLine, x: time, y: measure,
                        context: context,
                        score: 80 + goalBonus(.trend, context.goal),
                        rationale: ["Points preserve exact observations along the trend."],
                        warnings: warnings))
                if (measure.numericMinimum ?? -1) >= 0 {
                    processCandidate(
                        candidate(
                            family: .area, x: time, y: measure,
                            context: context,
                            score: 70 + goalBonus(.trend, context.goal),
                            rationale: ["A nonnegative temporal measure can use an area baseline."],
                            warnings: warnings))
                }
                for series in categorical
                where series.distinctCount >= 2
                    && series.distinctCount <= options.maximumSeries
                {
                    processCandidate(
                        candidate(
                            family: .line, x: time, y: measure, series: series,
                            context: context,
                            score: 87 + goalBonus(.trend, context.goal),
                            rationale: ["A small number of series supports comparable trends."],
                            warnings: warnings))
                }
            }
        }

        for dimension in categorical
        where !snapshot.metadata.isTruncated
            && dimension.distinctCount <= options.maximumCategories
        {
            for measure in quantitative {
                let uniqueAtResultGrain = dimension.isUniqueAtRowGrain
                guard
                    let categoryAggregation = uniqueAtResultGrain
                        ? AutoChartAggregation.none
                        : safeRollupAggregation(measure.column.hints)
                else { continue }
                let orientation: AutoChartOrientation =
                    dimension.averageTextLength > 10 || dimension.distinctCount > 8
                    ? .horizontal : .vertical
                processCandidate(
                    candidate(
                        family: .bar, x: dimension, y: measure,
                        context: context,
                        aggregation: categoryAggregation,
                        orientation: orientation,
                        sort: context.goal == .ranking ? .descending : .source,
                        score: 82 + goalBonus(.comparison, context.goal)
                            + goalBonus(.ranking, context.goal),
                        rationale: ["Position and length compare categories accurately."],
                        warnings: warnings))
                processCandidate(
                    candidate(
                        family: .rankedDot, x: dimension, y: measure,
                        context: context,
                        aggregation: categoryAggregation,
                        orientation: .horizontal,
                        sort: .descending,
                        score: 74 + goalBonus(.ranking, context.goal),
                        rationale: ["A common quantitative scale supports compact ranking."],
                        warnings: warnings))

                if !snapshot.metadata.isTruncated,
                    dimension.distinctCount <= options.maximumDonutSectors,
                    compositionIsSafe(measure.column.hints),
                    let compositionAggregation = safeRollupAggregation(measure.column.hints),
                    compositionAggregation == .count || measure.allNumericValuesPositive
                {
                    processCandidate(
                        candidate(
                            family: .donut, x: dimension, y: measure,
                            context: context,
                            aggregation: compositionAggregation,
                            score: 58 + goalBonus(.composition, context.goal),
                            rationale: ["Few positive, additive categories form a complete whole."])
                    )
                }

                for series in categorical
                where series.column.id != dimension.column.id
                    && series.distinctCount >= 2
                    && series.distinctCount <= options.maximumSeries
                {
                    let uniqueAtSeriesGrain = hasUniqueCombination(
                        snapshot: snapshot,
                        fields: [dimension.column.id, series.column.id],
                        measure: measure.column.id,
                        profiles: profileIndex,
                        droppingRowsMissing: [dimension.column.id],
                        memo: validationMemo)
                    guard
                        let seriesAggregation = uniqueAtSeriesGrain
                            ? AutoChartAggregation.none
                            : safeRollupAggregation(measure.column.hints)
                    else { continue }
                    processCandidate(
                        candidate(
                            family: .groupedBar, x: dimension, y: measure,
                            series: series, context: context,
                            aggregation: seriesAggregation,
                            score: 76 + goalBonus(.comparison, context.goal),
                            rationale: ["Grouped bars compare a small series within each category."]
                        ))
                    if !snapshot.metadata.isTruncated,
                        seriesAggregation == .count || measure.allNumericValuesPositive,
                        compositionIsSafe(measure.column.hints)
                    {
                        processCandidate(
                            candidate(
                                family: .stackedBar, x: dimension, y: measure,
                                series: series, context: context,
                                aggregation: seriesAggregation,
                                stacking: .standard,
                                score: 69 + goalBonus(.composition, context.goal),
                                rationale: [
                                    "Stacking shows additive contribution within each category."
                                ]))
                        processCandidate(
                            candidate(
                                family: .normalizedBar, x: dimension, y: measure,
                                series: series, context: context,
                                aggregation: seriesAggregation,
                                stacking: .normalized,
                                score: 62 + goalBonus(.composition, context.goal),
                                rationale: ["Normalization compares proportional composition."]))
                    }
                }
            }
        }

        for (leftIndex, left) in quantitative.enumerated() {
            for right in quantitative.dropFirst(leftIndex + 1) {
                processCandidate(
                    candidate(
                        family: .scatter, x: left, y: right,
                        context: context,
                        score: 81 + goalBonus(.relationship, context.goal),
                        rationale: ["Two quantitative fields support relationship analysis."],
                        warnings: warnings))
                for size in quantitative
                where size.column.id != left.column.id && size.column.id != right.column.id
                    && (size.numericMinimum ?? -1) >= 0
                {
                    var bubble = candidate(
                        family: .bubble, x: left, y: right,
                        context: context,
                        score: 68 + goalBonus(.relationship, context.goal),
                        rationale: ["A third nonnegative measure can encode point size."],
                        warnings: warnings)
                    bubble.specification.encoding.size = size.column.id
                    processCandidate(bubble)
                }
            }
        }

        for measure in quantitative {
            let binCount = histogramBinCount(for: measure)
            processCandidate(
                candidate(
                    family: .histogram, x: measure, context: context,
                    aggregation: .count, binCount: binCount,
                    score: 71 + goalBonus(.distribution, context.goal),
                    rationale: ["Binning reveals the distribution of a quantitative field."],
                    warnings: warnings))
            processCandidate(
                candidate(
                    family: .boxPlot, y: measure, context: context,
                    score: 66 + goalBonus(.distribution, context.goal)
                        + goalBonus(.outlier, context.goal),
                    rationale: ["Quartiles summarize spread and potential outliers."],
                    warnings: warnings))
            for group in categorical {
                guard let categoryCount = validationMemo.boundedBoxPlotCategoryCount(
                    snapshotIdentity: snapshot.validationIdentity,
                    categoryID: group.column.id,
                    measureID: measure.column.id),
                    let includesMissing = validationMemo.boxPlotIncludesMissing(
                        snapshotIdentity: snapshot.validationIdentity,
                        categoryID: group.column.id,
                        measureID: measure.column.id)
                else {
                    assertionFailure(
                        "The box-plot validation index must contain every candidate pair.")
                    continue
                }
                let renderableCategoryCount = categoryCount - (includesMissing ? 1 : 0)
                guard renderableCategoryCount >= 2,
                    categoryCount <= maximumGroupedBoxPlotCategories
                else { continue }
                let groupedBox = candidate(
                    family: .boxPlot, x: group, y: measure, context: context,
                    score: 73 + goalBonus(.distribution, context.goal),
                    rationale: ["Grouped quartiles compare distributions across categories."],
                    warnings: warnings)
                processCandidate(groupedBox)
            }
        }

        if !snapshot.metadata.isTruncated {
            for (leftIndex, left) in categorical.enumerated()
            where left.distinctCount <= options.maximumCategories {
                for right in categorical.dropFirst(leftIndex + 1)
                where right.distinctCount <= options.maximumCategories {
                    processCandidate(
                        candidate(
                            family: .heatmap, x: left, y: right,
                            context: context,
                            aggregation: .count,
                            score: 67 + goalBonus(.relationship, context.goal),
                            rationale: ["Cell counts expose relationships between categories."]))
                }
            }
        }

        if !snapshot.metadata.isTruncated {
            if let time = temporal.first, let measure = quantitative.first {
                processCandidate(
                    candidate(
                        family: .scatter, x: time, y: measure,
                        context: context,
                        score: 72 + goalBonus(.relationship, context.goal),
                        rationale: ["Dated values can be inspected along a temporal axis."],
                        warnings: warnings))
                for series in categorical
                where series.distinctCount >= 2
                    && series.distinctCount <= options.maximumSeries
                {
                    processCandidate(
                        candidate(
                            family: .scatter, x: time, y: measure, series: series,
                            context: context,
                            score: 72 + goalBonus(.relationship, context.goal),
                            rationale: ["Dated values can be inspected along a temporal axis."],
                            warnings: warnings))
                }
            }

            if temporal.count >= 2, let label = categorical.first {
                let hintedStart = temporal.first {
                    $0.column.hints.role == .intervalStart
                }
                let hintedEnd = temporal.first {
                    $0.column.hints.role == .intervalEnd
                }
                let start =
                    hintedStart
                    ?? temporal.first { $0.column.id != hintedEnd?.column.id }
                    ?? temporal[0]
                let end =
                    hintedEnd.flatMap { $0.column.id == start.column.id ? nil : $0 }
                    ?? temporal.first { $0.column.id != start.column.id }
                if let end {
                    processCandidate(
                        candidate(
                            family: .range, x: label, context: context,
                            start: start, end: end,
                            orientation: .horizontal,
                            score: 78 + goalBonus(.range, context.goal),
                            rationale: ["Start and end dates define comparable intervals."],
                            warnings: warnings))
                }
            } else if let time = temporal.first, let label = categorical.first {
                processCandidate(
                    candidate(
                        family: .range, x: label, context: context,
                        start: time, end: time,
                        orientation: .horizontal,
                        score: 70 + goalBonus(.range, context.goal),
                        rationale: ["Discrete events can be inspected on a temporal axis."],
                        warnings: warnings))
            }
        }

        // Faceting every eligible series base creates a cubic cross product at
        // the default column cap. Only let structurally valid bases that can
        // satisfy the eventual faceted request consume the bounded shortlist.
        let eligibleFacets = categorical.filter {
            $0.distinctCount >= 2 && $0.distinctCount <= options.maximumFacets
        }
        func facetedSpecification(
            from base: AutoChartRecommendation,
            facet: AutoChartColumnProfile
        ) -> AutoChartSpecification? {
            guard base.specification.encoding.x != facet.column.id,
                base.specification.encoding.y != facet.column.id,
                base.specification.encoding.series != facet.column.id
            else { return nil }
            var specification = base.specification
            specification.family = .faceted
            specification.facetBaseFamily = base.specification.family
            specification.encoding.facet = facet.column.id
            return specification
        }
        func facetedCandidate(
            from base: AutoChartRecommendation,
            facet: AutoChartColumnProfile
        ) -> AutoChartRecommendation? {
            guard let specification = facetedSpecification(from: base, facet: facet) else {
                return nil
            }
            var faceted = base
            let baseFamily = base.specification.family
            faceted.specification = specification
            faceted.diagnostics = faceted.diagnostics.map { diagnostic in
                var diagnostic = diagnostic
                if diagnostic.family == baseFamily { diagnostic.family = .faceted }
                return diagnostic
            }
            faceted.score -= 4
            faceted.rationale = [
                AutoChartMessage(
                    category: .rationale,
                    code: .recommendationRationale,
                    defaultText: "Small multiples separate a low-cardinality dimension.")
            ]
            return faceted
        }
        let hasFacetColumnConstraints = !constraints.requiredColumns.isEmpty
            || !constraints.excludedColumns.isEmpty
        let viableFacetBases = facetBases.filter { base in
            eligibleFacets.contains { facet in
                guard let specification = facetedSpecification(from: base, facet: facet)
                else { return false }
                return !hasFacetColumnConstraints || constraints.allows(specification)
            }
        }
        let facetBaseLimitPerFamily = options.maximumCandidateColumns
        let boundedFacetBases = [AutoChartFamily.line, .bar, .scatter].flatMap { family in
            balancedFacetBases(
                viableFacetBases.filter { $0.specification.family == family },
                limit: facetBaseLimitPerFamily,
                isValid: { cachedStructuralValidation($0.specification).isValid })
        }
        for facet in eligibleFacets {
            for base in boundedFacetBases {
                guard let faceted = facetedCandidate(from: base, facet: facet) else { continue }
                processCandidate(faceted)
            }
        }

        candidates.sort(by: recommendationPrecedes)
        let ranked = candidates

        // The full catalog is score ordered. Prepared-domain validation remains
        // lazy and stops as soon as the requested catalog capacity is filled.
        var cataloged: [AutoChartRecommendation] = []
        cataloged.reserveCapacity(min(options.maximumRecommendations, ranked.count))
        for candidate in ranked {
            if cataloged.count == options.maximumRecommendations { break }
            guard cachedPreparedValidation(candidate.specification).isValid else { continue }
            cataloged.append(candidate)
        }
        let resolvedFeaturedLimit = min(
            options.maximumRecommendations,
            max(1, featuredLimit ?? options.maximumRecommendations))
        let diverse = selectFeaturedSet(
            ranked,
            limit: resolvedFeaturedLimit,
            isValid: { cachedPreparedValidation($0.specification).isValid })
        // Featured recommendations are allowed to reserve catalog slots. This
        // keeps the public subset invariant without erasing the diversity work
        // whenever a useful alternative falls just below the score-only cutoff.
        let diverseIDs = Set(diverse.map(\.id))
        for recommendation in diverse
        where !cataloged.contains(where: { $0.id == recommendation.id })
        {
            if cataloged.count == options.maximumRecommendations,
                let removable = cataloged.lastIndex(where: {
                    !diverseIDs.contains($0.id)
                })
            {
                cataloged.remove(at: removable)
            }
            if cataloged.count < options.maximumRecommendations {
                cataloged.append(recommendation)
            }
        }
        cataloged.sort(by: recommendationPrecedes)
        let decisions: [AutoChartCandidateDecision] = options.includesDecisionTrace
            ? {
                let rankedIDs = Dictionary(
                    uniqueKeysWithValues: cataloged.enumerated().map {
                        ($0.element.id, $0.offset)
                    })
                return traceCandidatesByID.values.sorted { $0.id < $1.id }.map { candidate in
                    let structural = cachedStructuralValidation(candidate.specification)
                    if let rank = rankedIDs[candidate.id] {
                        return AutoChartCandidateDecision(
                            specificationID: candidate.specification.id,
                            family: candidate.specification.family,
                            disposition: .recommended(rank: rank, score: candidate.score))
                    }
                    if !structural.isValid {
                        return AutoChartCandidateDecision(
                            specificationID: candidate.specification.id,
                            family: candidate.specification.family,
                            disposition: .rejected(
                                structural.issues.filter { $0.severity == .error }
                                    .map { $0.messageValue.code }))
                    }
                    // Catalog construction prepares only candidates it actually considers.
                    // Do not turn trace construction into a full data-preparation pass.
                    if let prepared = preparedValidationResults[candidate.specification],
                        !prepared.isValid
                    {
                        return AutoChartCandidateDecision(
                            specificationID: candidate.specification.id,
                            family: candidate.specification.family,
                            disposition: .rejected(
                                prepared.issues.filter { $0.severity == .error }
                                    .map { $0.messageValue.code }))
                    }
                    return AutoChartCandidateDecision(
                        specificationID: candidate.specification.id,
                        family: candidate.specification.family,
                        disposition: .pruned(.candidateLimit))
                }
            }()
            : []
        guard !diverse.isEmpty else {
            let reason = "No safe chart can represent this result without changing its meaning."
            return AutoChartCandidateResults(
                recommendations: [],
                catalogedRecommendations: [],
                candidates: ranked,
                fallbackReason: reason,
                decisions: decisions)
        }
        return AutoChartCandidateResults(
            recommendations: diverse,
            catalogedRecommendations: cataloged,
            candidates: ranked,
            decisions: decisions)
    }

    static func validate(
        specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot
    ) -> AutoChartValidationResult {
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        return validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles)
    }

    static func validate(
        specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        memo: AutoChartValidationMemo? = nil,
        preparedData: [AutoChartDatum]? = nil,
        validatesPreparedNumericDomain: Bool = true,
        cancellationRequested: () -> Bool = { false }
    ) -> AutoChartValidationResult {
        if cancellationRequested() { return AutoChartValidationResult(issues: []) }
        var issues: [AutoChartDiagnostic] = []
        let referenced = orderedUnique(specification.encoding.columnIDs)
        for id in referenced where profiles[id] == nil {
            issues.append(
                .init(
                    severity: .error,
                    code: .invalidInput,
                    message: "Unknown column \(id.rawValue)."))
        }
        func require(_ id: AutoChartColumnID?, _ type: AutoChartSemanticType, _ label: String) {
            guard let id, let profile = profiles[id] else {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "\(label) is required."))
                return
            }
            let matches: Bool =
                switch type {
                case .nominal: profile.isCategorical
                default: profile.semanticType == type
                }
            if !matches {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "\(label) must be \(type.rawValue)."))
            }
        }
        func rejectMissing(_ id: AutoChartColumnID?, _ label: String) {
            guard let id, let profile = profiles[id],
                profile.renderableValueCount != snapshot.rows.count
            else {
                return
            }
            // Present-but-non-finite numbers aren't missing; they get their own,
            // more specific error below, so don't report the same cell twice.
            if profile.isQuantitative,
                profile.nonNullCount == snapshot.rows.count,
                profile.numericTypeCount == profile.nonNullCount,
                profile.hasNonFiniteNumericValues
            {
                return
            }
            // A typed non-finite date is present but cannot position a mark. It
            // receives the specific temporal diagnostic below rather than also
            // being reported as a missing value.
            if profile.isTemporal,
                profile.nonNullCount == snapshot.rows.count,
                profile.temporalValueCount + profile.nonFiniteDateCount
                    == profile.nonNullCount,
                profile.hasNonFiniteDateValues
            {
                return
            }
            issues.append(
                .init(
                    severity: .error,
                    code: .missingValue,
                    message: "\(label) must not contain missing values."))
        }
        switch specification.family {
        case .kpi:
            require(specification.encoding.y, .quantitative, "Value")
            rejectMissing(specification.encoding.y, "Value")
            if snapshot.rows.count != 1 {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "Key values require exactly one source row."))
            }
        case .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar, .donut:
            require(specification.encoding.x, .nominal, "Category")
            require(specification.encoding.y, .quantitative, "Measure")
        case .line, .pointLine, .area:
            guard let x = specification.encoding.x, let profile = profiles[x],
                profile.isTemporal || profile.semanticType == .ordinal
            else {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "Line and area charts require an ordered or temporal x-axis."))
                break
            }
            require(specification.encoding.y, .quantitative, "Measure")
            if specification.family == .area,
                let y = specification.encoding.y,
                let minimum = profiles[y]?.numericMinimum,
                minimum < 0
            {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "Area charts require nonnegative values."))
            }
        case .scatter, .bubble:
            guard let x = specification.encoding.x, let profile = profiles[x],
                profile.isQuantitative || profile.isTemporal
            else {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message:
                            "Scatter and bubble charts require a quantitative or temporal x-axis."))
                break
            }
            require(specification.encoding.y, .quantitative, "Measure")
            if specification.family == .bubble {
                require(specification.encoding.size, .quantitative, "Size")
                rejectMissing(specification.encoding.size, "Bubble sizes")
                if let size = specification.encoding.size,
                    let minimum = profiles[size]?.numericMinimum,
                    minimum < 0
                {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .validationFailed,
                            message: "Bubble sizes must be nonnegative."))
                }
                if specification.encoding.size == specification.encoding.x
                    || specification.encoding.size == specification.encoding.y
                {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .validationFailed,
                            message: "Bubble size must use a distinct field."))
                }
            }
        case .histogram:
            require(specification.encoding.x, .quantitative, "Binned field")
            if let binCount = specification.binCount,
                !(1...1_000).contains(binCount)
            {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message: "Requested histogram bin count must be between 1 and 1000."))
            }
        case .boxPlot:
            require(specification.encoding.y, .quantitative, "Measure")
            if let x = specification.encoding.x {
                require(x, .nominal, "Category")
                if let categoryProfile = profiles[x],
                    categoryProfile.isCategorical,
                    let y = specification.encoding.y,
                    let measureProfile = profiles[y],
                    measureProfile.isQuantitative,
                    measureProfile.numericValueCount > 0,
                    boxPlotIncludesMissingCategory(
                        snapshot: snapshot,
                        categoryID: x,
                        categorySemanticType: categoryProfile.semanticType,
                        measureID: y,
                        memo: memo,
                        cancellationRequested: cancellationRequested)
                {
                    issues.append(
                        .init(
                            severity: .warning,
                            code: .boxPlotMissingCategoryGroup,
                            message:
                                "Unrenderable box-plot categories are combined into one missing-value group.",
                            family: .boxPlot,
                            columnIDs: [x]))
                }
            }
        case .heatmap:
            require(specification.encoding.x, .nominal, "X category")
            require(specification.encoding.y, .nominal, "Y category")
            rejectMissing(specification.encoding.x, "Heatmap x categories")
            rejectMissing(specification.encoding.y, "Heatmap y categories")
        case .range:
            require(specification.encoding.x, .nominal, "Category")
            require(specification.encoding.start, .temporal, "Start")
            require(specification.encoding.end, .temporal, "End")
            rejectMissing(specification.encoding.x, "Range categories")
            rejectMissing(specification.encoding.start, "Range starts")
            rejectMissing(specification.encoding.end, "Range ends")
        case .faceted:
            require(specification.encoding.facet, .nominal, "Facet")
            rejectMissing(specification.encoding.facet, "Facet fields")
            let baseFamily = resolvedFacetBaseFamily(
                specification: specification,
                profiles: profiles)
            switch baseFamily {
            case .bar:
                require(specification.encoding.x, .nominal, "Category")
            case .line:
                guard let x = specification.encoding.x, let profile = profiles[x],
                    profile.isTemporal || profile.semanticType == .ordinal
                else {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .validationFailed,
                            message:
                                "Faceted line charts require an ordered or temporal x-axis."
                        ))
                    break
                }
            case .scatter:
                guard let x = specification.encoding.x, let profile = profiles[x],
                    profile.isQuantitative || profile.isTemporal
                else {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .validationFailed,
                            message:
                                "Faceted scatter charts require a quantitative or temporal x-axis."
                        ))
                    break
                }
            default:
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message:
                            "Faceted charts require a bar, line, or scatter base family."
                    ))
            }
            if specification.facetBaseFamily == nil, baseFamily != nil {
                issues.append(
                    .init(
                        severity: .warning,
                        code: .validationFailed,
                        message:
                            "Facet base family was inferred for a legacy specification; encode it explicitly before persisting again."
                    ))
            }
            require(specification.encoding.y, .quantitative, "Measure")
        }
        if specification.family == .heatmap,
            specification.encoding.x == specification.encoding.y
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message: "Heatmap x and y categories must use distinct fields."))
        }
        if specification.encoding.series != nil,
            specification.encoding.series == specification.encoding.x
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message: "Series and x-axis encodings must use distinct fields."))
        }
        if specification.family == .faceted,
            let facet = specification.encoding.facet,
            facet == specification.encoding.x || facet == specification.encoding.series
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message: "Facet, x-axis, and series encodings must use distinct fields."))
        }
        if [.groupedBar, .stackedBar, .normalizedBar].contains(specification.family),
            specification.encoding.series == nil
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message: "Series is required."))
        }
        if specification.encoding.series != nil {
            let supportsSeries: Set<AutoChartFamily> = [
                .groupedBar, .stackedBar, .normalizedBar,
                .line, .pointLine, .area,
                .scatter, .bubble, .faceted,
            ]
            if supportsSeries.contains(specification.family) {
                require(specification.encoding.series, .nominal, "Series")
                rejectMissing(specification.encoding.series, "Series fields")
            } else {
                issues.append(
                    .init(
                        severity: .error,
                        code: .validationFailed,
                        message:
                            "\(specification.family.displayName) does not support a series encoding."
                    ))
            }
        }
        func rejectUnsupportedChannel(
            _ isPresent: Bool,
            name: String,
            supportedFamilies: Set<AutoChartFamily>
        ) {
            guard isPresent, !supportedFamilies.contains(specification.family) else { return }
            let article = name.first.map { "aeiou".contains($0) } == true ? "an" : "a"
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message:
                        "\(specification.family.displayName) does not support \(article) \(name) encoding."
                ))
        }
        rejectUnsupportedChannel(
            specification.encoding.size != nil,
            name: "size",
            supportedFamilies: [.bubble])
        rejectUnsupportedChannel(
            specification.encoding.start != nil,
            name: "start",
            supportedFamilies: [.range])
        rejectUnsupportedChannel(
            specification.encoding.end != nil,
            name: "end",
            supportedFamilies: [.range])
        if specification.binCount != nil, specification.family != .histogram {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message:
                        "\(specification.family.displayName) does not support a histogram bin count."
                ))
        }
        if specification.encoding.facet != nil, specification.family != .faceted {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message:
                        "\(specification.family.displayName) does not support a facet encoding."
                ))
        }
        if specification.facetBaseFamily != nil, specification.family != .faceted {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message:
                        "\(specification.family.displayName) does not support a facet base family."
                ))
        }
        let temporalReferences = orderedUnique(
            [
                specification.encoding.x,
                specification.encoding.start,
                specification.encoding.end,
            ].compactMap { $0 })
        for id in temporalReferences {
            guard let profile = profiles[id], profile.isTemporal,
                profile.temporalValueCount + profile.nonFiniteDateCount
                    != profile.nonNullCount
            else { continue }
            issues.append(
                .init(
                    severity: .error,
                    code: .invalidTemporalRange,
                    message: "Temporal field \(id.rawValue) contains unparseable values."))
        }
        for id in temporalReferences {
            guard let profile = profiles[id], profile.isTemporal,
                profile.hasNonFiniteDateValues
            else { continue }
            let isRequiredRangeEndpoint = specification.family == .range
                && (id == specification.encoding.start || id == specification.encoding.end)
            issues.append(
                .init(
                    severity: isRequiredRangeEndpoint ? .error : .warning,
                    code: .nonFiniteValueOmitted,
                    message: isRequiredRangeEndpoint
                        ? "Temporal field \(id.rawValue) contains non-finite dates."
                        : "Temporal field \(id.rawValue) contains non-finite dates that will be omitted."
                ))
        }
        for id in referenced {
            guard let profile = profiles[id], profile.isQuantitative,
                profile.numericTypeCount != profile.nonNullCount
            else { continue }
            issues.append(
                .init(
                    severity: .error,
                    code: .invalidInput,
                    message: "Quantitative field \(id.rawValue) contains non-numeric values."))
        }
        let requiresCompleteQuantitativeValues: Set<AutoChartFamily> = [
            .kpi, .donut, .stackedBar, .normalizedBar,
        ]
        for id in referenced {
            guard let profile = profiles[id], profile.isQuantitative,
                profile.hasNonFiniteNumericValues
            else { continue }
            let isRequired =
                requiresCompleteQuantitativeValues.contains(specification.family)
                || (specification.family == .bubble && id == specification.encoding.size)
            issues.append(
                .init(
                    severity: isRequired ? .error : .warning,
                    code: .nonFiniteValueOmitted,
                    message: isRequired
                        ? "Quantitative field \(id.rawValue) contains non-finite values."
                        : "Quantitative field \(id.rawValue) contains non-finite values that will be omitted."
                ))
        }
        for id in referenced {
                guard let profile = profiles[id] else { continue }
                if profile.isQuantitative, !profile.hasFiniteNumericSpan {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .chartUnavailable,
                            message:
                                "Quantitative field \(id.rawValue) spans a range too large to render safely."
                        ))
                }
                if profile.isTemporal, !profile.hasFiniteTemporalSpan {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .invalidTemporalRange,
                            message:
                                "Temporal field \(id.rawValue) spans a range too large to render safely."
                        ))
                }
        }
        let expectedAggregation: AutoChartAggregation? =
            switch specification.family {
            case .histogram, .heatmap:
                .count
            case .donut:
                specification.encoding.y.flatMap { profiles[$0] }.flatMap {
                    safeRollupAggregation($0.column.hints)
                }
            case .kpi, .boxPlot, .scatter, .bubble, .range:
                AutoChartAggregation.none
            default:
                nil
            }
        if let expectedAggregation, specification.aggregation != expectedAggregation {
            issues.append(
                .init(
                    severity: .error,
                    code: .unsafeAggregation,
                    message:
                        "\(specification.family.displayName) requires \(expectedAggregation.rawValue) aggregation."
                ))
        }
        let expectedStacking: AutoChartStacking =
            switch specification.family {
            case .stackedBar:
                .standard
            case .normalizedBar:
                .normalized
            default:
                .none
            }
        if specification.stacking != expectedStacking {
            issues.append(
                .init(
                    severity: .error,
                    code: .validationFailed,
                    message:
                        "\(specification.family.displayName) requires \(expectedStacking.rawValue) stacking."
                ))
        }
        if snapshot.metadata.isTruncated {
            let truncationMessage: String? =
                switch specification.family {
                case .kpi:
                    "Key values require a complete result."
                case .heatmap:
                    "Frequency heatmaps require a complete result."
                case .donut, .stackedBar, .normalizedBar:
                    "Composition charts require a complete result."
                case .bar, .rankedDot, .groupedBar, .range:
                    "This chart family requires a complete result."
                case .faceted:
                    if resolvedFacetBaseFamily(
                        specification: specification,
                        profiles: profiles) == .bar
                    {
                        "Categorical small multiples require a complete result."
                    } else {
                        nil
                    }
                default:
                    nil
                }
            if let truncationMessage {
                issues.append(
                    .init(
                        severity: .error,
                        code: .incompleteResult,
                        message: truncationMessage))
            } else {
                // Descriptive families may honestly describe a subset, but the
                // caution must survive caller-provided specifications too, not
                // only engine-generated recommendations. Keep this diagnostic
                // identical to the engine's candidate warning so the two
                // sources deduplicate.
                issues.append(
                    .init(
                        severity: .warning,
                        code: .incompleteResult,
                        message:
                            "Based on the first returned rows; totals and composition are suppressed.",
                        family: specification.family))
            }
        }
        if cancellationRequested() { return AutoChartValidationResult(issues: []) }
        if let riskyColumns = fanOutRisk(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles,
            memo: memo)
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .fanOutRisk,
                    message:
                        "This chart would combine a measure across a finer-grain dimension and may double-count values from a one-to-many join.",
                    family: specification.family,
                    columnIDs: riskyColumns))
        }
        if let riskyColumns = chasmRisk(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles)
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .chasmRisk,
                    message:
                        "This chart combines measures from unrelated child grains and may multiply both sides of a multi-join result.",
                    family: specification.family,
                    columnIDs: riskyColumns))
        }
        if [.donut, .stackedBar, .normalizedBar].contains(specification.family) {
            rejectMissing(specification.encoding.x, "Composition categories")
            rejectMissing(specification.encoding.y, "Composition measures")
            if let y = specification.encoding.y,
                let profile = profiles[y],
                !compositionIsSafe(profile.column.hints)
            {
                issues.append(
                    .init(
                        severity: .error,
                        code: .unsafeAggregation,
                        message: "Composition requires an additive or safely counted measure."))
            }
            // Missing, non-numeric, and non-finite measures all shrink the
            // renderable count and are reported above, so this error is reserved
            // for a complete measure that really is zero or negative — including
            // one with no values at all to compose.
            if specification.aggregation != .count,
                let y = specification.encoding.y,
                let profile = profiles[y],
                profile.renderableValueCount == snapshot.rows.count,
                (profile.numericMinimum ?? 0) <= 0
            {
                issues.append(
                    .init(
                        severity: .error,
                        code: .unsafeAggregation,
                        message: "Composition requires positive values."))
            }
        }
        if specification.aggregation != .none,
            ![.histogram, .heatmap, .donut].contains(specification.family),
            let y = specification.encoding.y,
            let profile = profiles[y]
        {
            switch safeRollupResolution(profile.column.hints) {
            case .allowed(let safeAggregation):
                if specification.aggregation != safeAggregation {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .unsafeAggregation,
                            message:
                                "Aggregation must use the declared safe \(safeAggregation.rawValue) operation."
                        ))
                }
            case .rejectsSummationFromSource where specification.aggregation == .sum:
                issues.append(
                    .init(
                        severity: .error,
                        code: .nonAdditiveSourceSummation,
                        message:
                            "Aggregation cannot sum a measure whose source is already a non-additive summary."
                    ))
            case .rejectsSummationFromSource, .unavailable:
                issues.append(
                    .init(
                        severity: .error,
                        code: .unsafeAggregation,
                        message: "Aggregation requires an explicitly safe measure."))
            }
        }
        let markFields: [AutoChartColumnID?] =
            switch specification.family {
            case .bar, .rankedDot, .donut:
                [specification.encoding.x]
            case .groupedBar, .stackedBar, .normalizedBar:
                [specification.encoding.x, specification.encoding.series]
            case .line, .pointLine, .area:
                [specification.encoding.x, specification.encoding.series]
            case .faceted:
                [
                    specification.encoding.facet,
                    specification.encoding.x,
                    specification.encoding.series,
                ]
            default:
                []
            }
        if specification.aggregation == .none,
            !markFields.isEmpty,
            let y = specification.encoding.y,
            !hasUniqueCombination(
                snapshot: snapshot,
                fields: markFields.compactMap { $0 },
                measure: y,
                profiles: profiles,
                droppingRowsMissing: Set([specification.encoding.x].compactMap { $0 }),
                memo: memo,
                cancellationRequested: cancellationRequested)
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .duplicateMark,
                    message: "Duplicate marks require an explicit safe aggregation."))
        }
        if specification.family == .range,
            let start = specification.encoding.start,
            let end = specification.encoding.end,
            snapshot.rows.contains(where: { row in
                if cancellationRequested() { return true }
                guard let startDate = row.values[start].flatMap(AutoChartProfiler.dateValue),
                    let endDate = row.values[end].flatMap(AutoChartProfiler.dateValue)
                else { return false }
                return startDate > endDate
            })
        {
            issues.append(
                .init(
                    severity: .error,
                    code: .invalidTemporalRange,
                    message: "Range starts must not occur after their ends."))
        }
        if cancellationRequested() { return AutoChartValidationResult(issues: []) }
        let structuralValidation = AutoChartValidationResult(issues: issues)
        guard validatesPreparedNumericDomain else { return structuralValidation }
        return validatePreparedNumericDomain(
            structuralValidation: structuralValidation,
            specification: specification,
            snapshot: snapshot,
            profiles: profiles,
            preparedData: preparedData)
    }

    private static func candidate(
        family: AutoChartFamily,
        x: AutoChartColumnProfile? = nil,
        y: AutoChartColumnProfile? = nil,
        series: AutoChartColumnProfile? = nil,
        context: AutoChartContext,
        start: AutoChartColumnProfile? = nil,
        end: AutoChartColumnProfile? = nil,
        aggregation: AutoChartAggregation = .none,
        binCount: Int? = nil,
        orientation: AutoChartOrientation = .vertical,
        stacking: AutoChartStacking = .none,
        sort: AutoChartSort = .source,
        score: Double,
        rationale: [String],
        warnings: [String] = []
    ) -> AutoChartRecommendation {
        let title = context.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedTitle: String = {
            if aggregation == .count,
                ![.histogram, .heatmap].contains(family),
                let x
            {
                let category = AutoChartProfiler.displayName(x.column)
                if let y {
                    return "Count of \(AutoChartProfiler.displayName(y.column)) by \(category)"
                }
                return "Count by \(category)"
            }
            if let y, let x {
                return
                    "\(AutoChartProfiler.displayName(y.column)) by \(AutoChartProfiler.displayName(x.column))"
            }
            if let y { return AutoChartProfiler.displayName(y.column) }
            if let x { return AutoChartProfiler.displayName(x.column) }
            return family.displayName
        }()
        return AutoChartRecommendation(
            specification: AutoChartSpecification(
                family: family,
                encoding: AutoChartEncoding(
                    x: x?.column.id,
                    y: y?.column.id,
                    series: series?.column.id,
                    start: start?.column.id,
                    end: end?.column.id),
                aggregation: aggregation,
                binCount: binCount,
                orientation: orientation,
                stacking: stacking,
                sort: sort,
                title: title?.isEmpty == false ? title! : generatedTitle),
            score: score + preferredTransformBonus(aggregation, y),
            rationale: rationale,
            warnings: warnings)
    }

    private static func goalBonus(_ target: AutoChartGoal, _ actual: AutoChartGoal) -> Double {
        target == actual ? 18 : 0
    }

    private static func histogramBinCount(
        for profile: AutoChartColumnProfile
    ) -> Int {
        let fallback = Int(Double(profile.numericValueCount).squareRoot().rounded())
        guard profile.numericValueCount > 1,
            let minimum = profile.numericMinimum,
            let maximum = profile.numericMaximum,
            let quartile1 = profile.numericQuartile1,
            let quartile3 = profile.numericQuartile3
        else { return max(5, min(20, fallback)) }

        let range = maximum - minimum
        let interquartileRange = quartile3 - quartile1
        let width = 2 * interquartileRange
            / pow(Double(profile.numericValueCount), 1.0 / 3.0)
        guard range > 0, width > 0, width.isFinite else {
            return max(5, min(20, fallback))
        }
        // A finite input domain can still overflow while subtracting opposite
        // extremes. That and an overflowing quotient both mean the estimate is
        // above the supported ceiling, not that the fallback is preferable.
        guard range.isFinite else { return 20 }
        let estimate = ceil(range / width)
        guard estimate.isFinite else { return 20 }
        if estimate <= 5 { return 5 }
        if estimate >= 20 { return 20 }
        return Int(estimate)
    }

    private struct DescriptiveSignal {
        var adjustment = 0.0
        var message: String?
        var arguments: [String: AutoChartMessageArgument] = [:]
    }

    private enum DescriptiveSignalCacheKey: Hashable {
        case line(
            x: AutoChartColumnID,
            y: AutoChartColumnID,
            hasSeries: Bool)
        case relationship(x: AutoChartColumnID, y: AutoChartColumnID)
        case categorical(x: AutoChartColumnID, y: AutoChartColumnID)
        case histogram(AutoChartColumnID)
        case boxPlot(category: AutoChartColumnID?, measure: AutoChartColumnID)
        case composition(x: AutoChartColumnID, y: AutoChartColumnID)
    }

    private struct TemporalRegularityCacheKey: Hashable {
        var x: AutoChartColumnID
        var series: AutoChartColumnID?
        var facet: AutoChartColumnID?
    }

    private static func descriptiveSignalCacheKey(
        for specification: AutoChartSpecification
    ) -> DescriptiveSignalCacheKey? {
        switch specification.family {
        case .line, .pointLine, .area:
            guard let x = specification.encoding.x, let y = specification.encoding.y else {
                return nil
            }
            return .line(x: x, y: y, hasSeries: specification.encoding.series != nil)
        case .scatter, .bubble:
            guard let x = specification.encoding.x, let y = specification.encoding.y else {
                return nil
            }
            return .relationship(x: x, y: y)
        case .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar:
            guard let x = specification.encoding.x, let y = specification.encoding.y else {
                return nil
            }
            return .categorical(x: x, y: y)
        case .histogram:
            return specification.encoding.x.map(DescriptiveSignalCacheKey.histogram)
        case .boxPlot:
            guard let y = specification.encoding.y else { return nil }
            return .boxPlot(category: specification.encoding.x, measure: y)
        case .donut:
            guard let x = specification.encoding.x, let y = specification.encoding.y else {
                return nil
            }
            return .composition(x: x, y: y)
        case .kpi, .heatmap, .range, .faceted:
            return nil
        }
    }

    private static func dataAwareRecommendation(
        _ recommendation: AutoChartRecommendation,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        descriptiveSignalCache: inout [DescriptiveSignalCacheKey: DescriptiveSignal],
        temporalRegularityCache: inout [TemporalRegularityCacheKey: Double]
    ) -> AutoChartRecommendation {
        var result = recommendation
        let specification = recommendation.specification
        let familyPrior = familyPrior(
            for: specification,
            profiles: profiles)
        let preferredTransform = specification.encoding.y.flatMap { profiles[$0] }.map {
            preferredTransformBonus(specification.aggregation, $0)
        } ?? 0
        let taskFit = recommendation.score - familyPrior - preferredTransform
        let signal: DescriptiveSignal
        if let key = descriptiveSignalCacheKey(for: specification) {
            if let cached = descriptiveSignalCache[key] {
                signal = cached
            } else {
                let computed = descriptiveSignal(
                    for: specification,
                    snapshot: snapshot,
                    profiles: profiles)
                descriptiveSignalCache[key] = computed
                signal = computed
            }
        } else {
            signal = descriptiveSignal(
                for: specification,
                snapshot: snapshot,
                profiles: profiles)
        }
        let readabilityPenalty = readabilityPenalty(
            for: specification,
            snapshot: snapshot,
            profiles: profiles,
            temporalRegularityCache: &temporalRegularityCache)
        let breakdown = AutoChartScoreBreakdown(
            familyPrior: familyPrior,
            taskFit: taskFit,
            preferredTransform: preferredTransform,
            signal: signal.adjustment,
            readabilityPenalty: readabilityPenalty)
        result.scoreBreakdown = breakdown
        result.score = breakdown.total
        if let message = signal.message {
            result.rationale.append(
                AutoChartMessage(
                    category: .rationale,
                    code: .dataSignalRationale,
                    arguments: signal.arguments,
                    defaultText: message))
        }
        if readabilityPenalty >= 1 {
            result.rationale.append(
                AutoChartMessage(
                    category: .rationale,
                    code: .readabilityRationale,
                    arguments: ["penalty": .number(readabilityPenalty)],
                    defaultText:
                        "Dense marks or categories reduce this chart's readability score by \(readabilityPenalty.formatted(.number.precision(.fractionLength(0...1)))) points."
                ))
        }
        return result
    }

    private static func familyPrior(
        for specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> Double {
        let family = specification.family == .faceted
            ? specification.facetBaseFamily ?? .bar
            : specification.family
        let base: Double = switch family {
        case .kpi: 98
        case .bar: 82
        case .rankedDot: 74
        case .groupedBar: 76
        case .stackedBar: 69
        case .normalizedBar: 62
        case .line: specification.encoding.series == nil ? 84 : 87
        case .pointLine: 80
        case .area: 70
        case .scatter:
            specification.encoding.x.flatMap { profiles[$0] }?.isTemporal == true ? 72 : 81
        case .bubble: 68
        case .histogram: 71
        case .boxPlot: specification.encoding.x == nil ? 66 : 73
        case .heatmap: 67
        case .donut: 58
        case .range: specification.encoding.start == specification.encoding.end ? 70 : 78
        case .faceted: 0
        }
        return specification.family == .faceted ? base - 4 : base
    }

    private static func descriptiveSignal(
        for specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> DescriptiveSignal {
        switch specification.family {
        case .line, .pointLine, .area:
            guard specification.encoding.series == nil,
                let x = specification.encoding.x,
                let y = specification.encoding.y,
                let rho = spearmanCorrelation(
                    pairedNumbers(snapshot: snapshot, x: x, y: y)),
                abs(rho) >= 0.35
            else { return DescriptiveSignal() }
            let adjustment = min(4, abs(rho) * 4)
            return DescriptiveSignal(
                adjustment: adjustment,
                message:
                    "The measure follows the ordered axis consistently (Spearman rho \(rho.formatted(.number.precision(.fractionLength(2)))); this is descriptive, not a significance claim).",
                arguments: ["spearmanRho": .number(rho)])
        case .scatter, .bubble:
            guard let x = specification.encoding.x,
                let y = specification.encoding.y
            else { return DescriptiveSignal() }
            let pairs = pairedNumbers(snapshot: snapshot, x: x, y: y)
            guard let pearson = pearsonCorrelation(pairs),
                let spearman = spearmanCorrelation(pairs)
            else { return DescriptiveSignal() }
            let strength = max(abs(pearson), abs(spearman))
            guard strength >= 0.35 else { return DescriptiveSignal() }
            return DescriptiveSignal(
                adjustment: min(4, strength * 4),
                message:
                    "The two measures show a descriptive relationship (Pearson \(pearson.formatted(.number.precision(.fractionLength(2)))), Spearman \(spearman.formatted(.number.precision(.fractionLength(2)))); neither value is a significance claim).",
                arguments: [
                    "pearson": .number(pearson),
                    "spearmanRho": .number(spearman),
                ])
        case .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar:
            guard let x = specification.encoding.x,
                let y = specification.encoding.y,
                let effect = categoricalEffect(
                    snapshot: snapshot,
                    category: x,
                    measure: y,
                    semanticType: profiles[x]?.semanticType),
                effect >= 0.2
            else { return DescriptiveSignal() }
            return DescriptiveSignal(
                adjustment: min(3, effect * 3),
                message:
                    "Differences between returned groups account for \((effect * 100).formatted(.number.precision(.fractionLength(0))))% of the observed measure variation.",
                arguments: ["etaSquared": .number(effect)])
        case .histogram:
            guard let x = specification.encoding.x,
                let skewness = profiles[x]?.numericSkewness,
                abs(skewness) >= 0.5
            else { return DescriptiveSignal() }
            return DescriptiveSignal(
                adjustment: min(2, abs(skewness)),
                message:
                    "The returned distribution is asymmetric (skewness \(skewness.formatted(.number.precision(.fractionLength(2))))).",
                arguments: ["skewness": .number(skewness)])
        case .boxPlot:
            guard let y = specification.encoding.y,
                let fraction = outlierFraction(
                    snapshot: snapshot,
                    category: specification.encoding.x,
                    measure: y,
                    profile: profiles[y],
                    profiles: profiles),
                fraction > 0
            else { return DescriptiveSignal() }
            let message = specification.encoding.x == nil
                ? "\((fraction * 100).formatted(.number.precision(.fractionLength(0))))% of returned values fall beyond the 1.5-IQR fences."
                : "\((fraction * 100).formatted(.number.precision(.fractionLength(0))))% of returned values fall beyond their displayed group's 1.5-IQR fences."
            return DescriptiveSignal(
                adjustment: min(2, fraction * 8),
                message: message,
                arguments: ["outlierFraction": .number(fraction)])
        case .donut:
            guard let x = specification.encoding.x,
                let y = specification.encoding.y,
                let shares = compositionShares(
                    snapshot: snapshot,
                    category: x,
                    measure: y,
                    semanticType: profiles[x]?.semanticType),
                shares.count >= 2
            else { return DescriptiveSignal() }
            let largest = shares.max() ?? 0
            let normalizedEntropy = -shares.reduce(0.0) {
                $0 + ($1 > 0 ? $1 * log($1) : 0)
            } / log(Double(shares.count))
            let penalty = (largest >= 0.8 ? 3.0 : 0)
                + (normalizedEntropy >= 0.95 ? 1.5 : 0)
            guard penalty > 0 else { return DescriptiveSignal() }
            return DescriptiveSignal(
                adjustment: -penalty,
                message:
                    "The composition is visually weak because its largest share is \((largest * 100).formatted(.number.precision(.fractionLength(0))))% or its sectors are nearly uniform.",
                arguments: [
                    "largestShare": .number(largest),
                    "normalizedEntropy": .number(normalizedEntropy),
                ])
        case .kpi, .heatmap, .range, .faceted:
            return DescriptiveSignal()
        }
    }

    private static func readabilityPenalty(
        for specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        temporalRegularityCache: inout [TemporalRegularityCacheKey: Double]
    ) -> Double {
        var penalty = 0.0
        if let x = specification.encoding.x,
            profiles[x]?.isCategorical == true
        {
            let count = profiles[x]?.distinctCount ?? 0
            penalty += min(8, Double(max(0, count - 6)) * 0.5)
        }
        if let series = specification.encoding.series {
            let count = profiles[series]?.distinctCount ?? 0
            penalty += min(4, Double(max(0, count - 3)) * 0.75)
        }
        if let facet = specification.encoding.facet {
            let count = profiles[facet]?.distinctCount ?? 0
            penalty += min(4, Double(max(0, count - 3)))
        }
        if [.scatter, .bubble].contains(specification.family), snapshot.rows.count > 200 {
            penalty += min(4, Double(snapshot.rows.count - 200) / 75)
        }
        let effectiveFamily = specification.family == .faceted
            ? specification.facetBaseFamily
            : specification.family
        if let effectiveFamily,
            [.line, .pointLine, .area].contains(effectiveFamily),
            let x = specification.encoding.x,
            profiles[x]?.isTemporal == true
        {
            let key = TemporalRegularityCacheKey(
                x: x,
                series: specification.encoding.series,
                facet: specification.encoding.facet)
            let fraction: Double
            if let cached = temporalRegularityCache[key] {
                fraction = cached
            } else {
                struct Group: Hashable {
                    var series: AutoChartValueIdentity
                    var facet: AutoChartValueIdentity
                }
                var datesByGroup: [Group: [Date]] = [:]
                for row in snapshot.rows {
                    guard let date = row.values[x].flatMap(AutoChartProfiler.dateValue) else {
                        continue
                    }
                    let series = specification.encoding.series.map {
                        AutoChartProfiler.identity(
                            row.values[$0], semanticType: profiles[$0]?.semanticType)
                    } ?? .missing
                    let facet = specification.encoding.facet.map {
                        AutoChartProfiler.identity(
                            row.values[$0], semanticType: profiles[$0]?.semanticType)
                    } ?? .missing
                    datesByGroup[Group(series: series, facet: facet), default: []].append(date)
                }
                var irregularContributions: [Double] = []
                var gapCount = 0
                for dates in datesByGroup.values {
                    let uniqueCount = Set(dates).count
                    guard uniqueCount > 1,
                        let groupFraction = AutoChartProfiler.temporalIrregularityFraction(dates)
                    else { continue }
                    let groupGapCount = uniqueCount - 1
                    irregularContributions.append(groupFraction * Double(groupGapCount))
                    gapCount += groupGapCount
                }
                fraction = gapCount == 0
                    ? 0 : deterministicSum(irregularContributions) / Double(gapCount)
                temporalRegularityCache[key] = fraction
            }
            penalty += min(2, fraction * 2)
        }
        return penalty
    }

    private static func pairedNumbers(
        snapshot: AutoChartSnapshot,
        x: AutoChartColumnID,
        y: AutoChartColumnID
    ) -> [(Double, Double)] {
        snapshot.rows.compactMap { row in
            let xValue: Double? = row.values[x]?.numericValue
                ?? row.values[x].flatMap(AutoChartProfiler.dateValue)?
                    .timeIntervalSinceReferenceDate
            guard let xValue, let yValue = row.values[y]?.numericValue else { return nil }
            return (xValue, yValue)
        }
    }

    private static func pearsonCorrelation(
        _ values: [(Double, Double)]
    ) -> Double? {
        guard values.count >= 5 else { return nil }
        let count = Double(values.count)
        let meanX = values.reduce(0.0) { $0 + $1.0 } / count
        let meanY = values.reduce(0.0) { $0 + $1.1 } / count
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (x, y) in values {
            let dx = x - meanX
            let dy = y - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        let denominator = (varianceX * varianceY).squareRoot()
        guard denominator > 0, denominator.isFinite else { return nil }
        let result = covariance / denominator
        return result.isFinite ? max(-1, min(1, result)) : nil
    }

    private static func spearmanCorrelation(
        _ values: [(Double, Double)]
    ) -> Double? {
        guard values.count >= 5 else { return nil }
        let xRanks = averageRanks(values.map(\.0))
        let yRanks = averageRanks(values.map(\.1))
        return pearsonCorrelation(Array(zip(xRanks, yRanks)))
    }

    private static func averageRanks(_ values: [Double]) -> [Double] {
        let indexed = values.enumerated().sorted {
            $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element
        }
        var result = Array(repeating: 0.0, count: values.count)
        var lower = 0
        while lower < indexed.count {
            var upper = lower + 1
            while upper < indexed.count,
                indexed[upper].element == indexed[lower].element
            {
                upper += 1
            }
            let rank = (Double(lower + 1) + Double(upper)) / 2
            for offset in lower..<upper { result[indexed[offset].offset] = rank }
            lower = upper
        }
        return result
    }

    private static func categoricalEffect(
        snapshot: AutoChartSnapshot,
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        semanticType: AutoChartSemanticType?
    ) -> Double? {
        var groups: [AutoChartValueIdentity: [Double]] = [:]
        for row in snapshot.rows {
            guard let value = row.values[measure]?.numericValue else { continue }
            let identity = AutoChartProfiler.identity(
                row.values[category], semanticType: semanticType)
            guard identity != .missing else { continue }
            groups[identity, default: []].append(value)
        }
        let orderedGroups = Array(groups.values)
        let count = orderedGroups.reduce(0) { $0 + $1.count }
        guard count >= 8, groups.count >= 2, groups.count < count else { return nil }
        let values = orderedGroups.flatMap { $0 }
        let mean = deterministicSum(values) / Double(count)
        let total = deterministicSum(values.map { ($0 - mean) * ($0 - mean) })
        guard total > 0, total.isFinite else { return nil }
        let between = deterministicSum(orderedGroups.map { values in
            let groupMean = deterministicSum(values) / Double(values.count)
            return Double(values.count) * (groupMean - mean) * (groupMean - mean)
        })
        let effect = between / total
        return effect.isFinite ? max(0, min(1, effect)) : nil
    }

    private static func outlierFraction(
        snapshot: AutoChartSnapshot,
        category: AutoChartColumnID?,
        measure: AutoChartColumnID,
        profile: AutoChartColumnProfile?,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> Double? {
        func outliers(in values: [Double], quartiles: (Double, Double)? = nil)
            -> (count: Int, population: Int)?
        {
            guard values.count >= 5 else { return nil }
            let sorted = values.sorted()
            guard let quartile1 = quartiles?.0
                    ?? AutoChartProfiler.quantile(sorted, probability: 0.25),
                let quartile3 = quartiles?.1
                    ?? AutoChartProfiler.quantile(sorted, probability: 0.75)
            else { return nil }
            let interquartileRange = quartile3 - quartile1
            guard interquartileRange > 0, interquartileRange.isFinite else { return nil }
            let lower = quartile1 - 1.5 * interquartileRange
            let upper = quartile3 + 1.5 * interquartileRange
            return (values.lazy.filter { $0 < lower || $0 > upper }.count, values.count)
        }

        guard let category else {
            let values = snapshot.rows.compactMap { $0.values[measure]?.numericValue }
            let profileQuartiles = profile.flatMap { profile -> (Double, Double)? in
                guard let first = profile.numericQuartile1,
                    let third = profile.numericQuartile3
                else { return nil }
                return (first, third)
            }
            guard let result = outliers(in: values, quartiles: profileQuartiles) else {
                return nil
            }
            return Double(result.count) / Double(result.population)
        }

        var groups: [AutoChartValueIdentity: [Double]] = [:]
        for row in snapshot.rows {
            guard let value = row.values[measure]?.numericValue else { continue }
            let identity = AutoChartProfiler.identity(
                row.values[category], semanticType: profiles[category]?.semanticType)
            groups[identity, default: []].append(value)
        }
        var outlierCount = 0
        var population = 0
        for values in groups.values {
            guard let result = outliers(in: values) else { continue }
            outlierCount += result.count
            population += result.population
        }
        guard population > 0 else { return nil }
        return Double(outlierCount) / Double(population)
    }

    private static func compositionShares(
        snapshot: AutoChartSnapshot,
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        semanticType: AutoChartSemanticType?
    ) -> [Double]? {
        var valuesByCategory: [AutoChartValueIdentity: [Double]] = [:]
        for row in snapshot.rows {
            guard let value = row.values[measure]?.numericValue, value > 0 else { continue }
            let identity = AutoChartProfiler.identity(
                row.values[category], semanticType: semanticType)
            guard identity != .missing else { continue }
            valuesByCategory[identity, default: []].append(value)
        }
        let totals = valuesByCategory.keys.sorted {
            ($0.stringValue ?? "") < ($1.stringValue ?? "")
        }.compactMap { identity in
            valuesByCategory[identity].map(deterministicSum)
        }
        let total = deterministicSum(totals)
        guard total > 0, total.isFinite else { return nil }
        return totals.map { $0 / total }
    }

    /// Floating-point addition is order-sensitive. Score inputs originating in
    /// dictionaries are sorted by magnitude and bit pattern before summation so
    /// equal data produces equal scores across process launches.
    private static func deterministicSum(_ values: [Double]) -> Double {
        values.sorted {
            let lhsMagnitude = abs($0)
            let rhsMagnitude = abs($1)
            if lhsMagnitude != rhsMagnitude { return lhsMagnitude < rhsMagnitude }
            return $0.bitPattern < $1.bitPattern
        }.reduce(0, +)
    }

    private static func fanOutRisk(
        specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        memo: AutoChartValidationMemo?
    ) -> [AutoChartColumnID]? {
        guard let semanticModel = snapshot.metadata.semanticModel else { return nil }

        // These aggregations are invariant under repeated source values (or,
        // for count, intentionally describe returned observations). In
        // particular, heatmap y is a category rather than a measure.
        switch specification.aggregation {
        case .minimum, .maximum, .count, .countDistinct:
            return nil
        case .none, .sum, .mean:
            break
        }

        guard let measureID = specification.encoding.y,
            let measure = profiles[measureID]?.column,
            let measureGrain = measure.provenance?.sourceGrain
        else { return nil }

        let wasCombinedUpstream: Bool = {
            guard let semantics = measure.hints.measureSemantics,
                case .aggregated = semantics.source
            else { return false }
            return true
        }()
        let baseFamily = specification.family == .faceted
            ? specification.facetBaseFamily
            : specification.family
        let rawValuesAreDuplicateSensitive = baseFamily == .boxPlot
        guard specification.aggregation != .none || wasCombinedUpstream
            || rawValuesAreDuplicateSensitive
        else {
            return nil
        }

        let groupingIDs = orderedUnique(
            [
                specification.encoding.x,
                specification.encoding.series,
                specification.encoding.facet,
            ].compactMap { $0 })
        for groupingID in groupingIDs {
            guard let groupingGrain = profiles[groupingID]?.column.provenance?.sourceGrain,
                semanticModel.isStrictlyFiner(groupingGrain, than: measureGrain)
            else { continue }
            return [groupingID, measureID]
        }
        if let rowGrain = snapshot.metadata.rowGrain,
            semanticModel.isStrictlyFiner(rowGrain, than: measureGrain)
        {
            let accountedEntities = measureGrain.entities + groupingIDs.flatMap { groupingID in
                profiles[groupingID]?.column.provenance?.sourceGrain?.entities ?? []
            }
            let accountedGrain = AutoChartGrain(accountedEntities)
            if !semanticModel.isAtLeastAsFine(accountedGrain, as: rowGrain) {
                return orderedUnique(groupingIDs + [measureID])
            }

            let identifyingGroupingEntities: [AutoChartEntityID] = groupingIDs.flatMap {
                groupingID in
                guard let profile = profiles[groupingID],
                    providesIdentifierEvidence(profile)
                else {
                    return [AutoChartEntityID]()
                }
                return profile.column.provenance?.sourceGrain?.entities ?? []
            }
            let explicitlyIdentifiedGrain = AutoChartGrain(
                measureGrain.entities + identifyingGroupingEntities)
            if semanticModel.isAtLeastAsFine(explicitlyIdentifiedGrain, as: rowGrain) {
                return nil
            }

            // Naming the entities that refine row grain is not enough to prove
            // that the displayed values identify those entity instances. A
            // quarter derived from a month-grain column, for example, still
            // repeats a property measure for every month in the quarter.
            if hasUniqueCombination(
                snapshot: snapshot,
                fields: groupingIDs,
                measure: measureID,
                profiles: profiles,
                memo: memo)
            {
                return nil
            }

            // A result can also prove the rollup safe by retaining identifiers
            // for the measure grain. In that case each measure entity must occur
            // at most once for the displayed grouping values.
            let measureIdentifierProfiles = profiles.values.filter { profile in
                guard providesIdentifierEvidence(profile),
                    let identifierGrain = profile.column.provenance?.sourceGrain
                else { return false }
                return semanticModel.isAtLeastAsFine(measureGrain, as: identifierGrain)
            }.sorted {
                $0.column.id.rawValue < $1.column.id.rawValue
            }
            let measureIdentifierGrain = AutoChartGrain(
                measureIdentifierProfiles.flatMap {
                    $0.column.provenance?.sourceGrain?.entities ?? []
                })
            if semanticModel.isAtLeastAsFine(measureIdentifierGrain, as: measureGrain),
                hasUniqueCombination(
                    snapshot: snapshot,
                    fields: measureIdentifierProfiles.map(\.column.id) + groupingIDs,
                    measure: measureID,
                    profiles: profiles,
                    memo: memo)
            {
                return nil
            }
            return orderedUnique(groupingIDs + [measureID])
        }
        return nil
    }

    private static func chasmRisk(
        specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartColumnID]? {
        let baseFamily = specification.family == .faceted
            ? specification.facetBaseFamily
            : specification.family
        guard [.scatter, .bubble].contains(baseFamily),
            let semanticModel = snapshot.metadata.semanticModel,
            let xID = specification.encoding.x,
            let yID = specification.encoding.y,
            profiles[xID]?.isQuantitative == true,
            profiles[yID]?.isQuantitative == true,
            let xGrain = profiles[xID]?.column.provenance?.sourceGrain,
            let yGrain = profiles[yID]?.column.provenance?.sourceGrain,
            xGrain != yGrain
        else { return nil }

        guard !semanticModel.isAtLeastAsFine(xGrain, as: yGrain),
            !semanticModel.isAtLeastAsFine(yGrain, as: xGrain)
        else { return nil }
        return [xID, yID]
    }

    /// Composition marks must partition a whole, so contributions have to be
    /// non-negative and add up to a meaningful total. Summing an additive
    /// measure qualifies, and so does counting rows, which stays honest even
    /// for a measure containing negative values. Distinct counts are excluded
    /// because per-category distinct counts overlap and do not partition.
    private static func compositionIsSafe(_ hints: AutoChartColumnHints) -> Bool {
        guard let aggregation = safeRollupAggregation(hints) else { return false }
        switch aggregation {
        case .sum, .count:
            return true
        case .none, .mean, .minimum, .maximum, .countDistinct:
            return false
        }
    }

    private enum SafeRollupResolution {
        case allowed(AutoChartAggregation)
        case rejectsSummationFromSource
        case unavailable
    }

    private static func safeRollupResolution(
        _ hints: AutoChartColumnHints
    ) -> SafeRollupResolution {
        guard let semantics = hints.measureSemantics else { return .unavailable }
        switch semantics.rollup {
        case .additive:
            guard sourceSupportsAdditiveRollup(semantics.source) else {
                return .rejectsSummationFromSource
            }
            return .allowed(.sum)
        case .safe(let operation):
            // A named safe operation still cannot make an upstream summary
            // summable; only summation combines values additively, so it is
            // the one operation the source has to vouch for.
            guard operation != .sum || sourceSupportsAdditiveRollup(semantics.source)
            else { return .rejectsSummationFromSource }
            return .allowed(operation)
        case .nonAdditive, .unknown:
            return .unavailable
        }
    }

    private static func safeRollupAggregation(
        _ hints: AutoChartColumnHints
    ) -> AutoChartAggregation? {
        guard case .allowed(let aggregation) = safeRollupResolution(hints) else {
            return nil
        }
        return aggregation
    }

    /// Already-aggregated measures are additive only for upstream sums and
    /// ordinary counts; a mean, distinct count, or other summary does not
    /// become summable because the host labeled the column additive.
    private static func sourceSupportsAdditiveRollup(
        _ source: AutoChartMeasureSource
    ) -> Bool {
        switch source {
        case .rowLevel, .derived:
            return true
        case .aggregated(let operation):
            return operation == .sum || operation == .count
        }
    }

    /// A small ranking bonus when a candidate uses the transform the host
    /// declared as preferred. Preference influences ranking only; safety has
    /// already constrained which aggregations reach this point.
    private static func preferredTransformBonus(
        _ aggregation: AutoChartAggregation,
        _ measure: AutoChartColumnProfile?
    ) -> Double {
        guard aggregation != .none,
            measure?.column.hints.measureSemantics?.preferredTransform == aggregation
        else { return 0 }
        return 4
    }

    /// Whether preparation can create a numeric domain that is not bounded by the
    /// source column's individual values.
    private static func requiresPreparedNumericDomainValidation(
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> Bool {
        guard let y = specification.encoding.y,
            profiles[y]?.isQuantitative == true
        else { return false }
        if [.donut, .stackedBar, .normalizedBar].contains(specification.family) {
            return true
        }
        return specification.aggregation != .none
            && ![.histogram, .heatmap].contains(specification.family)
    }

    /// Adds validation that depends on prepared marks only after structural
    /// validation has established that preparation is safe.
    static func validatePreparedNumericDomain(
        structuralValidation: AutoChartValidationResult,
        specification: AutoChartSpecification,
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        preparedData: [AutoChartDatum]?
    ) -> AutoChartValidationResult {
        guard structuralValidation.isValid,
            requiresPreparedNumericDomainValidation(
                specification: specification,
                profiles: profiles),
            let y = specification.encoding.y,
            profiles[y]?.hasFiniteNumericSpan == true
        else {
            return structuralValidation
        }
        let data: [AutoChartDatum]
        if let preparedData {
            data = preparedData
        } else {
            data = AutoChartDataPreparation.preparedData(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles).data
        }
        return AutoChartValidationResult(
            issues: structuralValidation.issues
                + preparedNumericDomainIssues(
                    specification: specification,
                    data: data,
                    y: y))
    }

    private struct PreparedStackKey: Hashable {
        var x: String?
        var facet: String?
    }

    /// A running total that leaves the representable range only when the terms
    /// it was given really do.
    ///
    /// Terms accumulate in units of the largest power of two any of them has
    /// reached, so the running total is bounded by the number of terms however
    /// they are ordered and no intermediate can overflow ahead of the total
    /// itself. Scaling by a power of two is exact, and `compensation` carries
    /// the rounding each addition drops, so the total reported for a set of
    /// terms stays within an ulp of their exact sum whatever order they arrived
    /// in — near enough that only a sum sitting within that ulp of the edge of
    /// the range could still be decided by ordering.
    private struct ScaledSum {
        /// The exponent the running total is expressed in.
        private var unit = 0
        private var scaled = 0.0
        private var compensation = 0.0

        mutating func add(_ term: Double) {
            guard term.isFinite else {
                scaled += term
                return
            }
            guard term != 0 else { return }
            if term.exponent > unit { restate(in: term.exponent) }
            let scaledTerm = Self.shifted(term, by: -unit)
            let updated = scaled + scaledTerm
            // Whichever addend is the larger keeps the low bits the sum drops.
            compensation +=
                scaled.magnitude >= scaledTerm.magnitude
                ? (scaled - updated) + scaledTerm
                : (scaledTerm - updated) + scaled
            scaled = updated
        }

        /// The total in ordinary units, non-finite exactly when the terms
        /// reached beyond what a `Double` can hold.
        var value: Double { Self.shifted(scaled + compensation, by: unit) }

        /// Restates the running total in larger units. A power of two makes
        /// that exact until the old total falls below what the new unit can
        /// represent, by which point it sits far beneath the total's last bit.
        private mutating func restate(in newUnit: Int) {
            let shift = unit - newUnit
            scaled = Self.shifted(scaled, by: shift)
            compensation = Self.shifted(compensation, by: shift)
            unit = newUnit
        }

        private static func shifted(_ value: Double, by exponent: Int) -> Double {
            guard value != 0, value.isFinite else { return value }
            return Double(
                sign: value.sign,
                exponent: value.exponent + exponent,
                significand: value.significand)
        }
    }

    /// The subtotals one stack contributes to its value axis.
    ///
    /// `.standard` stacking grows each sign away from zero independently, so
    /// both subtotals bound the axis and the net difference between them bounds
    /// nothing. Each sign is accumulated on its own, so cancellation cannot
    /// hide a segment the axis has to reach, and each subtotal is a `ScaledSum`
    /// so that a segment order which overflows midway cannot reject a subtotal
    /// the axis can represent.
    private struct PreparedStackTotals {
        private var positiveTotal = ScaledSum()
        private var negativeTotal = ScaledSum()

        mutating func add(_ value: Double) {
            if value < 0 {
                negativeTotal.add(value)
            } else {
                positiveTotal.add(value)
            }
        }

        var positive: Double { positiveTotal.value }
        var negative: Double { negativeTotal.value }

        var isFinite: Bool { positive.isFinite && negative.isFinite }

        /// The combined total, or `nil` when either side left the range. Adding
        /// two finite subtotals of opposite sign cannot leave it.
        var total: Double? { isFinite ? positive + negative : nil }
    }

    private static func preparedNumericDomainIssues(
        specification: AutoChartSpecification,
        data: [AutoChartDatum],
        y: AutoChartColumnID
    ) -> [AutoChartDiagnostic] {
        let values = data.compactMap(\.yNumber)
        if values.contains(where: { !$0.isFinite }) {
            return [
                .init(
                    severity: .error,
                    code: .nonFiniteValueOmitted,
                    message:
                        "Aggregation of quantitative field \(y.rawValue) produces non-finite values."
                )
            ]
        }

        if specification.family == .donut {
            var composition = PreparedStackTotals()
            for value in values { composition.add(value) }
            guard composition.total != nil else {
                return [
                    .init(
                        severity: .error,
                        code: .nonFiniteValueOmitted,
                        message:
                            "Composition of quantitative field \(y.rawValue) produces a non-finite total."
                    )
                ]
            }
            return []
        }

        var domainValues = values
        if [.stackedBar, .normalizedBar].contains(specification.family) {
            var stacks: [PreparedStackKey: PreparedStackTotals] = [:]
            for datum in data {
                guard let value = datum.yNumber else { continue }
                let key = PreparedStackKey(
                    x: datum.xIdentity ?? datum.xLabel,
                    facet: datum.facetIdentity ?? datum.facet)
                stacks[key, default: PreparedStackTotals()].add(value)
            }
            // Both ends of every stack have to land on the axis, so each stack
            // contributes the extent it reaches in each direction.
            var extents: [Double] = []
            extents.reserveCapacity(stacks.count * 2)
            for totals in stacks.values {
                guard totals.isFinite else {
                    return [
                        .init(
                            severity: .error,
                            code: .nonFiniteValueOmitted,
                            message:
                                "Stacking quantitative field \(y.rawValue) produces non-finite totals."
                        )
                    ]
                }
                extents.append(totals.positive)
                extents.append(totals.negative)
            }
            if specification.family == .normalizedBar { return [] }
            domainValues = extents
        }

        if let minimum = domainValues.min(), let maximum = domainValues.max(),
            !(maximum - minimum).isFinite
        {
            return [
                .init(
                    severity: .error,
                    code: .chartUnavailable,
                    message:
                        "Aggregated quantitative field \(y.rawValue) spans a range too large to render safely."
                )
            ]
        }
        return []
    }

    private static func orderedUnique(
        _ references: [AutoChartColumnID]
    ) -> [AutoChartColumnID] {
        var seen: Set<AutoChartColumnID> = []
        return references.compactMap { reference in
            guard seen.insert(reference).inserted else { return nil }
            return reference
        }
    }

    static func resolvedFacetBaseFamily(
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> AutoChartFamily? {
        if let baseFamily = specification.facetBaseFamily { return baseFamily }
        guard specification.family == .faceted,
            let x = specification.encoding.x,
            let profile = profiles[x]
        else { return nil }
        if profile.semanticType == .ordinal { return .line }
        if profile.isTemporal { return .line }
        if profile.isQuantitative { return .scatter }
        if profile.isCategorical { return .bar }
        return nil
    }

    private struct AutoChartCombinationRequest: Hashable {
        var snapshotIdentity: UUID
        var fields: [AutoChartColumnID]
        var measure: AutoChartColumnID
        var droppingRowsMissing: Set<AutoChartColumnID>
    }

    final class AutoChartValidationMemo {
        private let boxPlotCategoryIndex: BoxPlotCategoryIndex?
        private var uniqueCombinations: [AutoChartCombinationRequest: Bool] = [:]
        #if ATC_TEST_HOOKS
        private(set) var uniqueCombinationScanCountForTesting = 0
        #endif

        init() {
            boxPlotCategoryIndex = nil
        }

        init(
            snapshot: AutoChartSnapshot,
            categories: [AutoChartColumnProfile],
            measures: [AutoChartColumnProfile],
            maximumCategoryCount: Int
        ) {
            boxPlotCategoryIndex = BoxPlotCategoryIndex(
                snapshot: snapshot,
                categories: categories,
                measures: measures,
                maximumCategoryCount: maximumCategoryCount)
        }

        func boundedBoxPlotCategoryCount(
            snapshotIdentity: UUID,
            categoryID: AutoChartColumnID,
            measureID: AutoChartColumnID
        ) -> Int? {
            guard boxPlotCategoryIndex?.snapshotIdentity == snapshotIdentity else {
                return nil
            }
            return boxPlotCategoryIndex?.boundedCategoryCount(
                categoryID: categoryID,
                measureID: measureID)
        }

        func boxPlotIncludesMissing(
            snapshotIdentity: UUID,
            categoryID: AutoChartColumnID,
            measureID: AutoChartColumnID
        ) -> Bool? {
            guard boxPlotCategoryIndex?.snapshotIdentity == snapshotIdentity else {
                return nil
            }
            return boxPlotCategoryIndex?.includesMissing(
                categoryID: categoryID,
                measureID: measureID)
        }

        func uniqueCombination(
            snapshotIdentity: UUID,
            fields: [AutoChartColumnID],
            measure: AutoChartColumnID,
            droppingRowsMissing: Set<AutoChartColumnID>
        ) -> Bool? {
            let request = AutoChartCombinationRequest(
                snapshotIdentity: snapshotIdentity,
                fields: fields,
                measure: measure,
                droppingRowsMissing: droppingRowsMissing)
            if let exact = uniqueCombinations[request] { return exact }

            // Adding a grouping field cannot create a duplicate when a known
            // subset is already unique. Faceted candidates add exactly one field
            // to their validated base, so this avoids rescanning every row for
            // each facet/base cross-product.
            guard fields.count > 1 else { return nil }
            for index in fields.indices {
                var subset = fields
                subset.remove(at: index)
                let subsetRequest = AutoChartCombinationRequest(
                    snapshotIdentity: snapshotIdentity,
                    fields: subset,
                    measure: measure,
                    droppingRowsMissing: droppingRowsMissing)
                if uniqueCombinations[subsetRequest] == true { return true }
            }
            return nil
        }

        func storeUniqueCombination(
            _ value: Bool,
            snapshotIdentity: UUID,
            fields: [AutoChartColumnID],
            measure: AutoChartColumnID,
            droppingRowsMissing: Set<AutoChartColumnID>
        ) {
            uniqueCombinations[
                AutoChartCombinationRequest(
                    snapshotIdentity: snapshotIdentity,
                    fields: fields,
                    measure: measure,
                    droppingRowsMissing: droppingRowsMissing)
            ] = value
        }

        #if ATC_TEST_HOOKS
        func recordUniqueCombinationScanForTesting() {
            uniqueCombinationScanCountForTesting += 1
        }
        #endif
    }

    private static func hasUniqueCombination(
        snapshot: AutoChartSnapshot,
        fields: [AutoChartColumnID],
        measure: AutoChartColumnID,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        droppingRowsMissing: Set<AutoChartColumnID> = [],
        memo: AutoChartValidationMemo? = nil,
        cancellationRequested: () -> Bool = { false }
    ) -> Bool {
        let fields = orderedUnique(fields)
        guard !fields.isEmpty else { return false }
        if fields.count == 1,
            let field = fields.first,
            droppingRowsMissing.contains(field),
            let profile = profiles[field],
            profile.isUniqueAtRowGrain
        {
            memo?.storeUniqueCombination(
                true,
                snapshotIdentity: snapshot.validationIdentity,
                fields: fields,
                measure: measure,
                droppingRowsMissing: droppingRowsMissing)
            return true
        }
        if let cached = memo?.uniqueCombination(
            snapshotIdentity: snapshot.validationIdentity,
            fields: fields,
            measure: measure,
            droppingRowsMissing: droppingRowsMissing)
        {
            return cached
        }
        #if ATC_TEST_HOOKS
        memo?.recordUniqueCombinationScanForTesting()
        #endif
        var seen: Set<[AutoChartValueIdentity]> = []
        var isUnique = true
        for row in snapshot.rows {
            if cancellationRequested() { return false }
            guard row.values[measure]?.numericValue != nil else { continue }
            let values = fields.map { field in
                AutoChartProfiler.identity(
                    row.values[field], semanticType: profiles[field]?.semanticType)
            }
            let dropsRow = zip(fields, values).contains { field, value in
                droppingRowsMissing.contains(field) && value == .missing
            }
            if dropsRow { continue }
            if !seen.insert(values).inserted {
                isUnique = false
                break
            }
        }
        memo?.storeUniqueCombination(
            isUnique,
            snapshotIdentity: snapshot.validationIdentity,
            fields: fields,
            measure: measure,
            droppingRowsMissing: droppingRowsMissing)
        return isUnique
    }

    private static func familyPriority(_ family: AutoChartFamily) -> Int {
        AutoChartFamily.allCases.firstIndex(of: family) ?? Int.max
    }

    private static func providesIdentifierEvidence(
        _ profile: AutoChartColumnProfile
    ) -> Bool {
        profile.column.hints.role == .identifier || profile.semanticType == .identifier
    }

    private static func recommendationPrecedes(
        _ lhs: AutoChartRecommendation,
        _ rhs: AutoChartRecommendation
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsFamily = familyPriority(lhs.specification.family)
        let rhsFamily = familyPriority(rhs.specification.family)
        if lhsFamily != rhsFamily { return lhsFamily < rhsFamily }
        return lhs.id < rhs.id
    }

    /// Selects a bounded set without letting the lexical order of specification
    /// IDs concentrate every base on the same x, y, or series column.
    private static func balancedFacetBases(
        _ candidates: [AutoChartRecommendation],
        limit: Int,
        isValid: (AutoChartRecommendation) -> Bool
    ) -> [AutoChartRecommendation] {
        balancedFacetBasesImplementation(
            candidates,
            limit: limit,
            isValid: isValid,
            comparisonObserver: AutoChartNoOpComparisonObserver())
    }

    private static func balancedFacetBasesImplementation<Observer>(
        _ candidates: [AutoChartRecommendation],
        limit: Int,
        isValid: (AutoChartRecommendation) -> Bool,
        comparisonObserver: Observer
    ) -> [AutoChartRecommendation]
    where Observer: AutoChartRecommendationComparisonObserving {
        guard limit > 0 else { return [] }
        var remaining = Array(candidates.indices)
        var output: [AutoChartRecommendation] = []
        var xUses: [AutoChartColumnID: Int] = [:]
        var yUses: [AutoChartColumnID: Int] = [:]
        var seriesUses: [AutoChartColumnID: Int] = [:]
        var reuseScores = Array(repeating: 0, count: candidates.count)

        func reuseCount(_ recommendation: AutoChartRecommendation) -> Int {
            let encoding = recommendation.specification.encoding
            return (encoding.x.map { xUses[$0, default: 0] } ?? 0)
                + (encoding.y.map { yUses[$0, default: 0] } ?? 0)
                + (encoding.series.map { seriesUses[$0, default: 0] } ?? 0)
        }

        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            comparisonObserver.recordComparison()
            let proposal = candidates[lhs]
            let incumbent = candidates[rhs]
            let proposalReuse = reuseScores[lhs]
            let incumbentReuse = reuseScores[rhs]
            if proposalReuse != incumbentReuse { return proposalReuse < incumbentReuse }
            if proposal.score != incumbent.score { return proposal.score > incumbent.score }
            if proposal.id != incumbent.id { return proposal.id < incumbent.id }
            return lhs < rhs
        }

        func siftDown(from start: Int) {
            var parent = start
            while parent * 2 + 1 < remaining.count {
                var child = parent * 2 + 1
                if child + 1 < remaining.count,
                    precedes(remaining[child + 1], remaining[child])
                {
                    child += 1
                }
                guard precedes(remaining[child], remaining[parent]) else { return }
                remaining.swapAt(parent, child)
                parent = child
            }
        }

        while output.count < limit, !remaining.isEmpty {
            for index in remaining {
                reuseScores[index] = reuseCount(candidates[index])
            }
            // Reuse priorities only change after accepting a candidate. Heapify
            // once per accepted base, then discard invalid picks in O(log n).
            if remaining.count > 1 {
                for parent in stride(from: remaining.count / 2 - 1, through: 0, by: -1) {
                    siftDown(from: parent)
                }
            }
            while !remaining.isEmpty {
                let recommendation = candidates[remaining[0]]
                remaining.swapAt(0, remaining.count - 1)
                remaining.removeLast()
                if !remaining.isEmpty { siftDown(from: 0) }
                guard isValid(recommendation) else { continue }
                output.append(recommendation)
                let encoding = recommendation.specification.encoding
                if let x = encoding.x { xUses[x, default: 0] += 1 }
                if let y = encoding.y { yUses[y, default: 0] += 1 }
                if let series = encoding.series { seriesUses[series, default: 0] += 1 }
                break
            }
        }
        return output
    }

    #if ATC_TEST_HOOKS
    static func balancedFacetBasesForTesting(
        _ candidates: [AutoChartRecommendation],
        limit: Int,
        isValid: (AutoChartRecommendation) -> Bool,
        onComparison: @escaping () -> Void = {}
    ) -> [AutoChartRecommendation] {
        balancedFacetBasesImplementation(
            candidates, limit: limit, isValid: isValid,
            comparisonObserver: AutoChartComparisonObserverForTesting(
                body: onComparison))
    }
    #endif

    private static func selectFeaturedSet(
        _ ranked: [AutoChartRecommendation],
        limit: Int,
        isValid: (AutoChartRecommendation) -> Bool
    ) -> [AutoChartRecommendation] {
        var output: [AutoChartRecommendation] = []
        var remaining = ranked
        var coveredFields: Set<AutoChartColumnID> = []
        var coveredTasks: Set<AutoChartGoal> = []
        var coveredVisualGroups: Set<String> = []
        var coveredQueries: Set<String> = []

        while output.count < limit, !remaining.isEmpty {
            var selectedOffset: Int?
            var selectedGain = -Double.infinity
            for (offset, recommendation) in remaining.enumerated() {
                let fields = Set(recommendation.specification.encoding.columnIDs)
                let task = recommendationTask(recommendation.specification)
                let visualGroup = visualRedundancyGroup(recommendation.specification)
                let query = dataQuerySignature(recommendation.specification)
                let gain = recommendation.score
                    + Double(fields.subtracting(coveredFields).count) * 2
                    + (coveredTasks.contains(task) ? 0 : 6)
                    - (coveredQueries.contains(query) ? 12 : 0)
                    - (coveredVisualGroups.contains(visualGroup) ? 4 : 0)
                guard gain > selectedGain, isValid(recommendation) else { continue }
                selectedGain = gain
                selectedOffset = offset
            }
            guard let selectedOffset else { break }
            let selected = remaining.remove(at: selectedOffset)
            output.append(selected)
            coveredFields.formUnion(selected.specification.encoding.columnIDs)
            coveredTasks.insert(recommendationTask(selected.specification))
            coveredVisualGroups.insert(visualRedundancyGroup(selected.specification))
            coveredQueries.insert(dataQuerySignature(selected.specification))
        }
        return output
    }

    private static func recommendationTask(
        _ specification: AutoChartSpecification
    ) -> AutoChartGoal {
        switch specification.family {
        case .kpi: .overview
        case .bar, .groupedBar: .comparison
        case .rankedDot: .ranking
        case .stackedBar, .normalizedBar, .donut: .composition
        case .line, .pointLine, .area: .trend
        case .scatter, .bubble, .heatmap: .relationship
        case .histogram, .boxPlot: .distribution
        case .range: .range
        case .faceted:
            recommendationTask(
                AutoChartSpecification(
                    family: specification.facetBaseFamily ?? .bar,
                    encoding: specification.encoding))
        }
    }

    private static func visualRedundancyGroup(
        _ specification: AutoChartSpecification
    ) -> String {
        switch specification.family {
        case .bar, .rankedDot: "categorical-magnitude"
        case .groupedBar: "grouped-magnitude"
        case .stackedBar, .normalizedBar, .donut: "composition"
        case .line, .pointLine, .area: "trend"
        case .scatter, .bubble: "relationship"
        case .histogram, .boxPlot: "distribution"
        case .kpi, .heatmap, .range: specification.family.rawValue
        case .faceted: "faceted-\(specification.facetBaseFamily?.rawValue ?? "bar")"
        }
    }

    private static func dataQuerySignature(
        _ specification: AutoChartSpecification
    ) -> String {
        let fields = specification.encoding.columnIDs.map(\.rawValue).sorted()
        return fields.joined(separator: "|") + "|\(specification.aggregation.rawValue)"
    }
}
