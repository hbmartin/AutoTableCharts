import Foundation

/// Profiles typed tables and returns a deterministic, semantically safe set of charts.
///
/// The engine generates candidates from table structure, rejects candidates that
/// violate hard constraints, ranks the survivors for the requested task, and
/// returns a bounded set with diverse chart families. It runs synchronously and
/// entirely offline.
enum AutoChartRecommendationEngine {

    static func recommendations<Table: AutoChartTable>(
        for table: Table,
        context: AutoChartContext = .init(),
        options: AutoChartOptions = .init()
    ) -> AutoChartCandidateResults {
        recommendations(
            snapshot: AutoChartSnapshot(table),
            context: context,
            options: options)
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
        options: AutoChartOptions
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
        let validationMemo = AutoChartValidationMemo()
        var structuralValidationResults: [AutoChartSpecification: AutoChartValidationResult] = [:]
        func cachedStructuralValidation(
            _ specification: AutoChartSpecification
        ) -> AutoChartValidationResult {
            if let cached = structuralValidationResults[specification] { return cached }
            let result = validate(
                specification: specification,
                snapshot: snapshot,
                profiles: profileIndex,
                memo: validationMemo,
                validatesPreparedNumericDomain: false)
            structuralValidationResults[specification] = result
            return result
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
            let data = AutoChartDataPreparation.data(
                snapshot: snapshot,
                specification: specification,
                profiles: profileIndex)
            let result = validate(
                specification: specification,
                snapshot: snapshot,
                profiles: profileIndex,
                memo: validationMemo,
                preparedData: data)
            preparedValidationResults[specification] = result
            return result
        }
        var candidates: [AutoChartRecommendation] = []
        let warnings =
            snapshot.metadata.isTruncated
            ? ["Based on the first returned rows; totals and composition are suppressed."]
            : []

        if !snapshot.metadata.isTruncated,
            snapshot.rows.count == 1,
            let measure = quantitative.first(where: { $0.nonNullCount > 0 })
        {
            candidates.append(
                candidate(
                    family: .kpi,
                    y: measure,
                    context: context,
                    score: 98,
                    rationale: ["A single quantitative result is clearest as a key value."]))
        }

        for time in temporal {
            for measure in quantitative {
                candidates.append(
                    candidate(
                        family: .line, x: time, y: measure,
                        context: context,
                        score: 84 + goalBonus(.trend, context.goal),
                        rationale: ["Temporal position reveals change over time."],
                        warnings: warnings))
                candidates.append(
                    candidate(
                        family: .pointLine, x: time, y: measure,
                        context: context,
                        score: 80 + goalBonus(.trend, context.goal),
                        rationale: ["Points preserve exact observations along the trend."],
                        warnings: warnings))
                if (measure.numericMinimum ?? -1) >= 0 {
                    candidates.append(
                        candidate(
                            family: .area, x: time, y: measure,
                            context: context,
                            score: 70 + goalBonus(.trend, context.goal),
                            rationale: ["A nonnegative temporal measure can use an area baseline."],
                            warnings: warnings))
                }
                if let series = categorical.first(where: {
                    $0.distinctCount >= 2 && $0.distinctCount <= options.maximumSeries
                }) {
                    candidates.append(
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
                candidates.append(
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
                candidates.append(
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
                    candidates.append(
                        candidate(
                            family: .donut, x: dimension, y: measure,
                            context: context,
                            aggregation: compositionAggregation,
                            score: 58 + goalBonus(.composition, context.goal),
                            rationale: ["Few positive, additive categories form a complete whole."])
                    )
                }

                if let series = categorical.first(where: {
                    $0.column.id != dimension.column.id
                        && $0.distinctCount >= 2
                        && $0.distinctCount <= options.maximumSeries
                }) {
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
                    candidates.append(
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
                        candidates.append(
                            candidate(
                                family: .stackedBar, x: dimension, y: measure,
                                series: series, context: context,
                                aggregation: seriesAggregation,
                                stacking: .standard,
                                score: 69 + goalBonus(.composition, context.goal),
                                rationale: [
                                    "Stacking shows additive contribution within each category."
                                ]))
                        candidates.append(
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
                candidates.append(
                    candidate(
                        family: .scatter, x: left, y: right,
                        context: context,
                        score: 81 + goalBonus(.relationship, context.goal),
                        rationale: ["Two quantitative fields support relationship analysis."],
                        warnings: warnings))
                if let size = quantitative.first(where: {
                    $0.column.id != left.column.id && $0.column.id != right.column.id
                        && ($0.numericMinimum ?? -1) >= 0
                }) {
                    var bubble = candidate(
                        family: .bubble, x: left, y: right,
                        context: context,
                        score: 68 + goalBonus(.relationship, context.goal),
                        rationale: ["A third nonnegative measure can encode point size."],
                        warnings: warnings)
                    bubble.specification.encoding.size = size.column.id
                    candidates.append(bubble)
                }
            }
        }

        for measure in quantitative {
            let binCount = max(
                5,
                min(20, Int(Double(measure.numericValueCount).squareRoot().rounded())))
            candidates.append(
                candidate(
                    family: .histogram, x: measure, context: context,
                    aggregation: .count, binCount: binCount,
                    score: 71 + goalBonus(.distribution, context.goal),
                    rationale: ["Binning reveals the distribution of a quantitative field."],
                    warnings: warnings))
            candidates.append(
                candidate(
                    family: .boxPlot, y: measure, context: context,
                    score: 66 + goalBonus(.distribution, context.goal)
                        + goalBonus(.outlier, context.goal),
                    rationale: ["Quartiles summarize spread and potential outliers."],
                    warnings: warnings))
            if let group = categorical.first(where: {
                $0.distinctCount >= 2 && $0.distinctCount <= min(10, options.maximumCategories)
            }) {
                let groupedBox = candidate(
                    family: .boxPlot, x: group, y: measure, context: context,
                    score: 73 + goalBonus(.distribution, context.goal),
                    rationale: ["Grouped quartiles compare distributions across categories."],
                    warnings: warnings)
                candidates.append(groupedBox)
            }
        }

        if !snapshot.metadata.isTruncated {
            for (leftIndex, left) in categorical.enumerated()
            where left.distinctCount <= options.maximumCategories {
                for right in categorical.dropFirst(leftIndex + 1)
                where right.distinctCount <= options.maximumCategories {
                    candidates.append(
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
                let series = categorical.first(where: {
                    $0.distinctCount >= 2 && $0.distinctCount <= options.maximumSeries
                })
                candidates.append(
                    candidate(
                        family: .scatter, x: time, y: measure, series: series,
                        context: context,
                        score: 72 + goalBonus(.relationship, context.goal),
                        rationale: ["Dated values can be inspected along a temporal axis."],
                        warnings: warnings))
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
                    candidates.append(
                        candidate(
                            family: .range, x: label, context: context,
                            start: start, end: end,
                            orientation: .horizontal,
                            score: 78 + goalBonus(.range, context.goal),
                            rationale: ["Start and end dates define comparable intervals."],
                            warnings: warnings))
                }
            } else if let time = temporal.first, let label = categorical.first {
                candidates.append(
                    candidate(
                        family: .range, x: label, context: context,
                        start: time, end: time,
                        orientation: .horizontal,
                        score: 70 + goalBonus(.range, context.goal),
                        rationale: ["Discrete events can be inspected on a temporal axis."],
                        warnings: warnings))
            }
        }

        var facetProfile: AutoChartColumnProfile?
        var facetBase: AutoChartRecommendation?
        for facet in categorical
        where facet.distinctCount >= 2 && facet.distinctCount <= options.maximumFacets {
            let base = candidates.first { recommendation in
                [.line, .bar, .scatter].contains(recommendation.specification.family)
                    && recommendation.specification.encoding.x != facet.column.id
                    && recommendation.specification.encoding.y != facet.column.id
                    && recommendation.specification.encoding.series != facet.column.id
                    && cachedStructuralValidation(recommendation.specification).isValid
            }
            guard let base else { continue }
            facetProfile = facet
            facetBase = base
            break
        }
        if let facet = facetProfile, let base = facetBase {
            var faceted = base
            let baseFamily = faceted.specification.family
            faceted.specification.family = .faceted
            faceted.specification.facetBaseFamily = baseFamily
            faceted.specification.encoding.facet = facet.column.id
            faceted.score -= 4
            faceted.rationale = [
                AutoChartMessage(
                    category: .rationale,
                    code: .recommendationRationale,
                    defaultText: "Small multiples separate a low-cardinality dimension.")
            ]
            candidates.append(faceted)
        }

        let best = bestCandidatesByID(candidates)
        let unique = best.filter {
            cachedStructuralValidation($0.specification).isValid
        }
        let ranked = unique.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = familyPriority($0.specification.family)
            let rhs = familyPriority($1.specification.family)
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
        let diverse = diversify(
            ranked,
            limit: options.maximumRecommendations,
            isValid: { cachedPreparedValidation($0.specification).isValid })
        let rankedIDs = Dictionary(
            uniqueKeysWithValues: diverse.enumerated().map { ($0.element.id, $0.offset) })
        let decisions: [AutoChartCandidateDecision] = options.includesDecisionTrace
            ? best.map { candidate in
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
                let prepared = cachedPreparedValidation(candidate.specification)
                if !prepared.isValid {
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
            : []
        guard !diverse.isEmpty else {
            let reason = "No safe chart can represent this result without changing its meaning."
            return AutoChartCandidateResults(
                recommendations: [],
                fallbackReason: reason,
                decisions: decisions)
        }
        return AutoChartCandidateResults(recommendations: diverse, decisions: decisions)
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
        validatesPreparedNumericDomain: Bool = true
    ) -> AutoChartValidationResult {
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
                profile.temporalValues.count + profile.nonFiniteDateCount
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
                        message: "Histogram bin count must be between 1 and 1000."))
            }
        case .boxPlot:
            require(specification.encoding.y, .quantitative, "Measure")
            if specification.encoding.x != nil {
                require(specification.encoding.x, .nominal, "Category")
                rejectMissing(specification.encoding.x, "Box-plot categories")
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
                profile.temporalValues.count + profile.nonFiniteDateCount
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
        if validatesPreparedNumericDomain,
            requiresPreparedNumericDomainValidation(
                specification: specification,
                profiles: profiles),
            let y = specification.encoding.y,
            profiles[y]?.hasFiniteNumericSpan == true
        {
            let data = preparedData
                ?? AutoChartDataPreparation.data(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles)
            issues.append(
                contentsOf: preparedNumericDomainIssues(
                    specification: specification,
                    data: data,
                    y: y))
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
            }
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
                        message: "Composition requires an explicitly additive measure."))
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
            if let safeAggregation = safeRollupAggregation(profile.column.hints) {
                if specification.aggregation != safeAggregation {
                    issues.append(
                        .init(
                            severity: .error,
                            code: .unsafeAggregation,
                            message:
                                "Aggregation must use the declared safe \(safeAggregation.rawValue) operation."
                        ))
                }
            } else {
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
                memo: memo)
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
        return AutoChartValidationResult(issues: issues)
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
            score: score,
            rationale: rationale,
            warnings: warnings)
    }

    private static func goalBonus(_ target: AutoChartGoal, _ actual: AutoChartGoal) -> Double {
        target == actual ? 18 : 0
    }

    private static func compositionIsSafe(_ hints: AutoChartColumnHints) -> Bool {
        guard let semantics = hints.measureSemantics else { return false }
        return semantics.rollup == .additive
    }

    private static func safeRollupAggregation(
        _ hints: AutoChartColumnHints
    ) -> AutoChartAggregation? {
        switch hints.measureSemantics?.rollup {
        case .additive:
            return .sum
        case .safe(let operation):
            return operation
        case .nonAdditive, .unknown, nil:
            return nil
        }
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
        private var uniqueCombinations: [AutoChartCombinationRequest: Bool] = [:]

        func uniqueCombination(
            snapshotIdentity: UUID,
            fields: [AutoChartColumnID],
            measure: AutoChartColumnID,
            droppingRowsMissing: Set<AutoChartColumnID>
        ) -> Bool? {
            uniqueCombinations[
                AutoChartCombinationRequest(
                    snapshotIdentity: snapshotIdentity,
                    fields: fields,
                    measure: measure,
                    droppingRowsMissing: droppingRowsMissing)
            ]
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
    }

    private static func hasUniqueCombination(
        snapshot: AutoChartSnapshot,
        fields: [AutoChartColumnID],
        measure: AutoChartColumnID,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        droppingRowsMissing: Set<AutoChartColumnID> = [],
        memo: AutoChartValidationMemo? = nil
    ) -> Bool {
        guard !fields.isEmpty else { return false }
        if fields.count == 1,
            let field = fields.first,
            droppingRowsMissing.contains(field),
            let profile = profiles[field],
            profile.isUniqueAtRowGrain
        {
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
        var seen: Set<[AutoChartValueIdentity]> = []
        var isUnique = true
        for row in snapshot.rows {
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

    static func bestCandidatesByID(
        _ candidates: [AutoChartRecommendation]
    ) -> [AutoChartRecommendation] {
        var bestCandidateByID: [AutoChartRecommendationID: AutoChartRecommendation] = [:]
        for recommendation in candidates {
            if let existing = bestCandidateByID[recommendation.id],
                existing.score >= recommendation.score
            {
                continue
            }
            bestCandidateByID[recommendation.id] = recommendation
        }
        return Array(bestCandidateByID.values)
    }

    private static func diversify(
        _ ranked: [AutoChartRecommendation],
        limit: Int,
        isValid: (AutoChartRecommendation) -> Bool
    ) -> [AutoChartRecommendation] {
        var output: [AutoChartRecommendation] = []
        var seenFamilies: Set<AutoChartFamily> = []
        for recommendation in ranked where output.count < limit {
            guard !seenFamilies.contains(recommendation.specification.family),
                isValid(recommendation)
            else { continue }
            seenFamilies.insert(recommendation.specification.family)
            output.append(recommendation)
        }
        if output.count < limit {
            for recommendation in ranked
            where output.count < limit
                && !output.contains(where: { $0.id == recommendation.id })
                && isValid(recommendation)
            {
                output.append(recommendation)
            }
        }
        return output
    }
}
