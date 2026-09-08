import Foundation

package struct AutoChartDatum: Identifiable, Sendable {
    package var id: String
    package var sourceRowIDs: Set<Int>
    package var xIdentity: String? = nil
    package var xSourceValue: AutoChartValue? = nil
    package var xCategoryValue: AutoChartValue? = nil
    package var xLabel: String?
    package var xNumber: Double?
    package var xDate: Date?
    package var yIdentity: String? = nil
    package var ySourceValue: AutoChartValue? = nil
    package var yCategoryValue: AutoChartValue? = nil
    package var yLabel: String?
    package var yNumber: Double?
    package var seriesIdentity: String? = nil
    package var seriesSourceValue: AutoChartValue? = nil
    package var seriesCategoryValue: AutoChartValue? = nil
    package var series: String?
    package var size: Double?
    package var facetIdentity: String? = nil
    package var facetSourceValue: AutoChartValue? = nil
    package var facetCategoryValue: AutoChartValue? = nil
    package var facet: String?
    package var startDate: Date?
    package var endDate: Date?
    package var lower: Double?
    package var quartile1: Double?
    package var median: Double?
    package var quartile3: Double?
    package var upper: Double?
}

/// The single place mark accessibility labels are assembled.
///
/// Callers pass components already formatted with the chart's own formatters,
/// so the timezone, locale, and unit a mark shows are the ones its label reads
/// out. The components also reach the resolver as arguments: a host that wants
/// to translate or reorder a label needs the pieces, not one English sentence
/// it can only pass through unchanged. Faceted labels retain the legacy combined
/// `facet` argument and also provide `facetTitle` and `facetValue` separately.
package enum AutoChartAccessibility {
    package static func markLabel(
        name: String,
        series: String? = nil,
        facetTitle: String? = nil,
        facetValue: String? = nil,
        valueDescription: String? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> String {
        func present(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let resolvedFacetTitle = present(facetTitle)
        let resolvedFacetValue = present(facetValue)
        let facetDescription: String?
        switch (resolvedFacetTitle, resolvedFacetValue) {
        case (.some(let title), .some(let value)):
            facetDescription = "\(title): \(value)"
        case (.some(let title), nil):
            facetDescription = title
        case (nil, .some(let value)):
            facetDescription = value
        case (nil, nil):
            facetDescription = nil
        }
        let defaultText = [name, series, facetDescription, valueDescription]
            .compactMap(present)
            .joined(separator: ", ")
        return label(
            components: [
                ("name", name),
                ("series", series),
                ("facet", facetDescription),
                ("facetTitle", facetTitle),
                ("facetValue", facetValue),
                ("value", valueDescription),
            ],
            defaultText: defaultText,
            textResolver: textResolver)
    }

    package static func kpiLabel(
        title: String,
        valueDescription: String,
        textResolver: AutoChartTextResolver
    ) -> String {
        textResolver(
            AutoChartMessage(
                category: .accessibility,
                code: .kpiAccessibility,
                arguments: [
                    "title": .string(title),
                    "value": .string(valueDescription),
                ],
                defaultText: "\(title), \(valueDescription)"))
    }

    package static func heatmapLabel(
        category: String,
        secondaryCategory: String,
        valueDescription: String? = nil,
        textResolver: AutoChartTextResolver = .default
    ) -> String {
        label(
            components: [
                ("category", category),
                ("secondaryCategory", secondaryCategory),
                ("value", valueDescription),
            ],
            textResolver: textResolver)
    }

    package static func rangeValueDescription(
        for datum: AutoChartDatum,
        measureSemantics: AutoChartRenderedMeasureSemantics,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver = .default
    ) -> String? {
        guard let start = datum.startDate else { return nil }
        let rangeColumns = AutoChartFormattingLineage.rangeColumns(
            columnID: measureSemantics.columnID,
            startColumnID: measureSemantics.rangeStartColumnID,
            endColumnID: measureSemantics.rangeEndColumnID,
            resolve: { profiles[$0]?.column })
        let startText = formatters.format(
            column: rangeColumns.start,
            value: .date(start),
            context: .markAccessibility)
        guard let end = datum.endDate, end != start else {
            return textResolver(
                AutoChartMessage(
                    category: .accessibility,
                    code: .markAccessibilityDate,
                    arguments: ["date": .string(startText)],
                    defaultText: "Date: \(startText)"))
        }
        let endText = formatters.format(
            column: rangeColumns.end,
            value: .date(end),
            context: .markAccessibility)
        return rangeLabel(
            startText: startText,
            endText: endText,
            textResolver: textResolver)
    }

    package static func histogramBinLabel(
        lower: Double,
        upper: Double,
        column: AutoChartColumn?,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver = .default
    ) -> String {
        let lowerText = formatters.format(
            AutoChartFormattingRequest(
                column: column,
                value: .double(lower),
                context: .markAccessibility))
        let upperText = formatters.format(
            AutoChartFormattingRequest(
                column: column,
                value: .double(upper),
                context: .markAccessibility))
        return rangeLabel(
            startText: lowerText,
            endText: upperText,
            code: .histogramBinAccessibility,
            compatibilityCode: .markAccessibilityRange,
            textResolver: textResolver)
    }

    private static func rangeLabel(
        startText: String,
        endText: String,
        code: AutoChartMessage.Code = .markAccessibilityRange,
        compatibilityCode: AutoChartMessage.Code? = nil,
        textResolver: AutoChartTextResolver
    ) -> String {
        let arguments: [String: AutoChartMessageArgument] = [
            "start": .string(startText),
            "end": .string(endText),
        ]
        let defaultText = "From \(startText) to \(endText)"
        let message = AutoChartMessage(
            category: .accessibility,
            code: code,
            arguments: arguments,
            defaultText: defaultText)
        if let resolved = textResolver.resolve(message) {
            return resolved
        }
        if let compatibilityCode,
            let resolved = textResolver.resolve(
                AutoChartMessage(
                    category: .accessibility,
                    code: compatibilityCode,
                    arguments: arguments,
                    defaultText: defaultText))
        {
            return resolved
        }
        return defaultText
    }

    private static func label(
        components: [(key: String, value: String?)],
        defaultText suppliedDefaultText: String? = nil,
        textResolver: AutoChartTextResolver
    ) -> String {
        let present = components.compactMap { component -> (String, String)? in
            guard let value = component.value, !value.isEmpty else { return nil }
            return (component.key, value)
        }
        let defaultText = suppliedDefaultText
            ?? present.map(\.1).joined(separator: ", ")
        return textResolver(
            AutoChartMessage(
                category: .accessibility,
                code: .markAccessibility,
                arguments: Dictionary(
                    uniqueKeysWithValues: present.map {
                        ($0.0, AutoChartMessageArgument.string($0.1))
                    }),
                defaultText: defaultText))
    }
}

/// Returns one canonical typed source value represented by every element.
///
/// Matching semantic identities are necessary but not sufficient: selection
/// exposes an `AutoChartValue`, so it must not choose arbitrarily between raw
/// representations such as `.integer(1)` and `.double(1)`.
private func identicalSourceValue<Elements: Collection>(
    in elements: Elements,
    value: (Elements.Element) -> AutoChartValue?,
    identity: (Elements.Element) -> String?
) -> AutoChartValue? {
    guard let first = elements.first else { return nil }
    let firstIdentity = identity(first)
    guard let firstValue = value(first),
        elements.dropFirst().allSatisfy({ element in
            identity(element) == firstIdentity
                && hasSameSemanticValue(value(element), as: firstValue)
        }),
        firstIdentity != nil || firstValue == .null
    else { return nil }
    return canonicalSelectionValue(firstValue)
}

/// Selection follows `AutoChartValue`'s public equality semantics after category
/// identity has established that the values represent the same dimension.
private func hasSameSemanticValue(
    _ candidate: AutoChartValue?,
    as reference: AutoChartValue
) -> Bool {
    candidate == reference
}

/// Removes storage-only distinctions from a selected value so merged categories
/// return the same representation regardless of source-row order.
private func canonicalSelectionValue(_ value: AutoChartValue) -> AutoChartValue {
    switch value {
    case .double(let number):
        return .double(number == 0 ? 0 : number)
    case .decimal(var number):
        guard !number.isNaN else { return value }
        NSDecimalCompact(&number)
        return .decimal(number)
    case .date(let date):
        let interval = date.timeIntervalSinceReferenceDate
        return interval == 0 ? .date(Date(timeIntervalSinceReferenceDate: 0)) : value
    default:
        return value
    }
}

private struct AutoChartCategorySortKey {
    var displayValue: String
    var identity: String
    var sourceOffset: Int
}

/// Applies the category ordering ladder consistently across preparation and
/// presentation. Resolved presentation text uses the formatter locale; raw
/// preparation labels retain deterministic lexical ordering.
private func categoryPrecedes(
    _ lhs: AutoChartCategorySortKey,
    _ rhs: AutoChartCategorySortKey,
    locale: Locale? = nil
) -> Bool {
    if lhs.displayValue != rhs.displayValue {
        if let locale {
            let comparison = lhs.displayValue.compare(
                rhs.displayValue,
                options: [],
                range: nil,
                locale: locale)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        } else {
            return lhs.displayValue < rhs.displayValue
        }
    }
    if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
    return lhs.sourceOffset < rhs.sourceOffset
}

private func requiresContinuousXOrdering(
    family: AutoChartFamily,
    semanticType: AutoChartSemanticType?
) -> Bool {
    guard semanticType == .temporal || semanticType == .quantitative else {
        return false
    }
    return switch family {
    case .line, .pointLine, .area, .faceted: true
    default: false
    }
}

private func orderedByMeasure(
    _ data: [AutoChartDatum],
    sort: AutoChartSort,
    locale: Locale? = nil,
    categoryKey: (Int, AutoChartDatum) -> AutoChartCategorySortKey
) -> [AutoChartDatum] {
    let sortsAscending: Bool
    switch sort {
    case .source:
        return data
    case .ascending:
        sortsAscending = true
    case .descending:
        sortsAscending = false
    }
    return data.enumerated().map { offset, datum in
        (
            datum: datum,
            value: datum.yNumber,
            categoryKey: categoryKey(offset, datum)
        )
    }.sorted { lhs, rhs in
        switch (lhs.value, rhs.value) {
        case (nil, nil):
            return categoryPrecedes(lhs.categoryKey, rhs.categoryKey, locale: locale)
        case (nil, _):
            return false
        case (_, nil):
            return true
        case (.some(let left), .some(let right)):
            if left.isNaN || right.isNaN {
                if left.isNaN != right.isNaN {
                    return !left.isNaN
                }
                return categoryPrecedes(lhs.categoryKey, rhs.categoryKey, locale: locale)
            }
            if left != right {
                return sortsAscending ? left < right : left > right
            }
            return categoryPrecedes(lhs.categoryKey, rhs.categoryKey, locale: locale)
        }
    }.map(\.datum)
}

package enum AutoChartSelectionPreparation {
    package struct SemanticValues: Sendable {
        package var dimensions: [AutoChartSelectedDimension]
        package var rangeDimensions: [AutoChartSelectedRangeDimension]
        package var measure: AutoChartSelectedMeasure?
    }

    /// The union of source-row offsets behind the selected marks, or `nil`
    /// when the selection has no lineage to report. Label and value text come
    /// from ``AutoChartSelection/presentation(columns:formatters:textResolver:)``,
    /// which resolves and formats them for the host.
    package static func sourceRowOffsets(for matches: [AutoChartDatum]) -> Set<Int>? {
        guard !matches.isEmpty else { return nil }
        let rowIDs = matches.reduce(into: Set<Int>()) {
            $0.formUnion($1.sourceRowIDs)
        }
        return rowIDs.isEmpty ? nil : rowIDs
    }

    package static func angleMatch(
        to selectedAngle: Double,
        in candidates: [AutoChartDatum]
    ) -> AutoChartDatum? {
        guard selectedAngle.isFinite, selectedAngle >= 0 else { return nil }
        var cumulative = 0.0
        for datum in candidates {
            cumulative += datum.yNumber ?? 0
            if selectedAngle <= cumulative {
                return datum.sourceRowIDs.isEmpty ? nil : datum
            }
        }
        return nil
    }

    package static func nearestDateMatches(
        to selectedDate: Date,
        in candidates: [AutoChartDatum]
    ) -> [AutoChartDatum] {
        let eligible = candidates.compactMap { datum -> (AutoChartDatum, Date)? in
            guard !datum.sourceRowIDs.isEmpty, let xDate = datum.xDate else { return nil }
            return (datum, xDate)
        }
        guard
            let nearestDate = eligible.min(by: {
                abs($0.1.timeIntervalSince(selectedDate))
                    < abs($1.1.timeIntervalSince(selectedDate))
            })?.1
        else { return [] }
        return eligible.filter { $0.1 == nearestDate }.map(\.0)
    }

    package static func nearestNumberMatches(
        to selectedNumber: Double,
        in candidates: [AutoChartDatum]
    ) -> [AutoChartDatum] {
        let eligible = candidates.compactMap { datum -> (AutoChartDatum, Double)? in
            guard !datum.sourceRowIDs.isEmpty, let xNumber = datum.xNumber else { return nil }
            return (datum, xNumber)
        }
        guard
            let nearestNumber = eligible.min(by: {
                abs($0.1 - selectedNumber) < abs($1.1 - selectedNumber)
            })?.1
        else { return [] }
        return eligible.filter { $0.1 == nearestNumber }.map(\.0)
    }

    package static func aggregatedNumericValue(
        for matches: [AutoChartDatum],
        aggregation: AutoChartAggregation
    ) -> Double? {
        let numericMatches = matches.compactMap { datum -> (value: Double, weight: Int)? in
            guard let value = datum.yNumber else { return nil }
            return (value, datum.sourceRowIDs.count)
        }
        guard !numericMatches.isEmpty else { return nil }
        if numericMatches.count == 1 { return numericMatches[0].value }
        switch aggregation {
        case .sum, .count:
            return numericMatches.reduce(0) { $0 + $1.value }
        case .mean:
            let totalWeight = numericMatches.reduce(0) { $0 + $1.weight }
            guard totalWeight > 0 else { return nil }
            return numericMatches.reduce(0) {
                $0 + $1.value * Double($1.weight)
            } / Double(totalWeight)
        case .minimum:
            return numericMatches.map(\.value).min()
        case .maximum:
            return numericMatches.map(\.value).max()
        case .none, .countDistinct:
            return nil
        }
    }

    package static func identicalValue<Value: Equatable>(in values: [Value]) -> Value? {
        guard let first = values.first, values.dropFirst().allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    package static func semanticValues(
        for matches: [AutoChartDatum],
        specification: AutoChartSpecification,
        measureSemantics: AutoChartRenderedMeasureSemantics
    ) -> SemanticValues {
        var dimensions: [AutoChartSelectedDimension] = []
        var rangeDimensions: [AutoChartSelectedRangeDimension] = []

        if let x = specification.encoding.x {
            if specification.family == .histogram {
                let ranges = matches.compactMap { datum -> AutoChartSelectedRangeValue? in
                    guard let lower = datum.lower, let upper = datum.upper else { return nil }
                    return .numeric(lower: lower, upper: upper)
                }
                if ranges.count == matches.count,
                    let range = identicalValue(in: ranges)
                {
                    rangeDimensions.append(.init(columnID: x, value: range))
                }
            } else {
                if let value = identicalSourceValue(
                    in: matches,
                    value: \.xSourceValue,
                    identity: \.xIdentity)
                {
                    dimensions.append(.init(columnID: x, value: value))
                }
            }
        }
        if specification.family == .heatmap, let y = specification.encoding.y {
            if let value = identicalSourceValue(
                in: matches,
                value: \.ySourceValue,
                identity: \.yIdentity)
            {
                dimensions.append(.init(columnID: y, value: value))
            }
        }
        if let series = specification.encoding.series {
            if let value = identicalSourceValue(
                in: matches,
                value: \.seriesSourceValue,
                identity: \.seriesIdentity)
            {
                dimensions.append(.init(columnID: series, value: value))
            }
        }
        if let facet = specification.encoding.facet {
            if let value = identicalSourceValue(
                in: matches,
                value: \.facetSourceValue,
                identity: \.facetIdentity)
            {
                dimensions.append(.init(columnID: facet, value: value))
            }
        }

        let markValue: AutoChartMarkValue? = {
            if let value = aggregatedNumericValue(
                for: matches,
                aggregation: measureSemantics.aggregation)
            {
                return .scalar(.double(value))
            }
            let values = matches.map(markValue(for:))
            guard !values.contains(where: { $0 == nil }),
                let value = identicalValue(in: values.compactMap { $0 })
            else { return nil }
            return value
        }()
        let measure = markValue.map {
            let rangeStartColumnID: AutoChartColumnID?
            let rangeEndColumnID: AutoChartColumnID?
            if case .temporalRange = $0 {
                rangeStartColumnID = measureSemantics.rangeStartColumnID
                rangeEndColumnID = measureSemantics.rangeEndColumnID
            } else {
                rangeStartColumnID = nil
                rangeEndColumnID = nil
            }
            return AutoChartSelectedMeasure(
                columnID: measureSemantics.columnID,
                rangeStartColumnID: rangeStartColumnID,
                rangeEndColumnID: rangeEndColumnID,
                aggregation: measureSemantics.aggregation,
                value: $0)
        }
        return SemanticValues(
            dimensions: dimensions,
            rangeDimensions: rangeDimensions,
            measure: measure)
    }

    private static func markValue(for datum: AutoChartDatum) -> AutoChartMarkValue? {
        if let start = datum.startDate, let end = datum.endDate {
            return .temporalRange(start: start, end: end)
        }
        if let lower = datum.lower, let upper = datum.upper,
            let quartile1 = datum.quartile1, let median = datum.median,
            let quartile3 = datum.quartile3
        {
            return .distribution(
                lower: lower,
                quartile1: quartile1,
                median: median,
                quartile3: quartile3,
                upper: upper)
        }
        if let lower = datum.lower, let upper = datum.upper {
            return .numericRange(lower: lower, upper: upper)
        }
        return nil
    }
}

package enum AutoChartRenderedMeasureKind: Hashable, Sendable {
    case value
    case aggregated(AutoChartAggregation)
}

/// The row-level rules shared by box-plot recommendation and preparation.
/// A category emits a box only when its row has a finite numeric measure, and
/// category grouping always uses the profiled semantic identity.
package enum AutoChartBoxPlotGrouping {
    package static func measure(
        in row: AutoChartSnapshot.Row,
        columnID: AutoChartColumnID
    ) -> Double? {
        row.values[columnID]?.numericValue
    }

    package static func categoryIdentity(
        in row: AutoChartSnapshot.Row,
        columnID: AutoChartColumnID?,
        semanticType: AutoChartSemanticType?
    ) -> AutoChartValueIdentity {
        guard let columnID else { return .missing }
        return AutoChartProfiler.identity(
            row.values[columnID],
            semanticType: semanticType)
    }
}

/// Presentation semantics produced by the same plan that prepares chart marks.
/// Storing these with the prepared core keeps every presentation surface aligned
/// with values that have already been grouped or transformed.
package struct AutoChartRenderedMeasureSemantics: Hashable, Sendable {
    package let columnID: AutoChartColumnID?
    package let rangeStartColumnID: AutoChartColumnID?
    package let rangeEndColumnID: AutoChartColumnID?
    package let kind: AutoChartRenderedMeasureKind
    package let usesNormalizedMeasureAxis: Bool

    package init(
        columnID: AutoChartColumnID?,
        rangeStartColumnID: AutoChartColumnID? = nil,
        rangeEndColumnID: AutoChartColumnID? = nil,
        kind: AutoChartRenderedMeasureKind,
        usesNormalizedMeasureAxis: Bool
    ) {
        if case .aggregated(.none) = kind {
            preconditionFailure("Prepared aggregated measures require an aggregation.")
        }
        precondition(
            (rangeStartColumnID == nil) == (rangeEndColumnID == nil),
            "Prepared range measures require both endpoint columns.")
        if rangeStartColumnID != nil, case .aggregated = kind {
            preconditionFailure("Prepared range measures cannot be aggregated.")
        }
        self.columnID = columnID
        self.rangeStartColumnID = rangeStartColumnID
        self.rangeEndColumnID = rangeEndColumnID
        self.kind = kind
        self.usesNormalizedMeasureAxis = usesNormalizedMeasureAxis
    }

    package var aggregation: AutoChartAggregation {
        switch kind {
        case .value:
            .none
        case .aggregated(let aggregation):
            aggregation
        }
    }

    package var formattingPurpose: AutoChartFormattingPurpose {
        .renderedMeasure(aggregation)
    }
}

private func expandedFiniteRange(
    _ range: ClosedRange<Double>,
    padding: Double
) -> ClosedRange<Double>? {
    guard range.lowerBound.isFinite, range.upperBound.isFinite,
        padding.isFinite, padding >= 0
    else { return nil }
    let paddedLower = range.lowerBound - padding
    let paddedUpper = range.upperBound + padding
    let lower = paddedLower.isFinite ? paddedLower : range.lowerBound
    let upper = paddedUpper.isFinite ? paddedUpper : range.upperBound
    if lower < upper {
        if (upper - lower).isFinite { return lower...upper }
        // Padding near a finite limit can make an otherwise usable span
        // overflow. Prefer the unpadded range in that case.
        if range.lowerBound < range.upperBound,
            (range.upperBound - range.lowerBound).isFinite
        {
            return range
        }
        return nil
    }

    // A zero or underflowed padding can leave a singleton. Move by one
    // representable value where possible without creating infinity.
    let previous = range.lowerBound.nextDown
    let next = range.upperBound.nextUp
    let finiteLower = previous.isFinite ? previous : range.lowerBound
    let finiteUpper = next.isFinite ? next : range.upperBound
    guard finiteLower < finiteUpper,
        (finiteUpper - finiteLower).isFinite
    else { return nil }
    return finiteLower...finiteUpper
}

private func finiteSingletonPadding(for value: Double) -> Double {
    precondition(value.isFinite)
    let relativePadding = abs(value) * 0.05
    if relativePadding > 0 {
        return relativePadding
    }
    return value == 0 ? 1 : 0
}

package enum AutoChartDataPreparation {
    package struct PreparedData: Sendable {
        package var data: [AutoChartDatum]
        package var measureSemantics: AutoChartRenderedMeasureSemantics
    }

    private enum Operation {
        case raw
        case grouped(AutoChartAggregation)
        case histogram
        case boxPlot
        case heatmap
    }

    private struct Plan {
        var operation: Operation
        var measureSemantics: AutoChartRenderedMeasureSemantics
    }

    /// A deterministic category label derived from the normalized identity.
    /// Numeric identities use the same concise, ungrouped category formatting
    /// as raw source values, while identities that merge storage families never
    /// inherit a label from whichever source row happened to arrive first.
    private static func categoryLabel(
        for identity: AutoChartValueIdentity
    ) -> String? {
        return identity.categoryValue?.categoryString()
    }

    private static func nonMissingCategoryLabel(
        for identity: AutoChartValueIdentity
    ) -> String {
        precondition(identity != .missing)
        guard let label = categoryLabel(for: identity) else {
            preconditionFailure("A nonmissing category identity must have a display value.")
        }
        return label
    }

    package static func preparedData(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> PreparedData {
        let plan = preparationPlan(for: specification)
        let data = switch plan.operation {
        case .raw:
            sorted(
                raw(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles),
                specification: specification,
                profiles: profiles)
        case .grouped(let aggregation):
            grouped(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles,
                aggregation: aggregation)
        case .histogram:
            histogram(snapshot: snapshot, specification: specification)
        case .boxPlot:
            boxPlot(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        case .heatmap:
            heatmap(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        }
        return PreparedData(data: data, measureSemantics: plan.measureSemantics)
    }

    private static func preparationPlan(
        for specification: AutoChartSpecification
    ) -> Plan {
        let rangeStartColumnID: AutoChartColumnID?
        let rangeEndColumnID: AutoChartColumnID?
        if specification.family == .range,
            let start = specification.encoding.start,
            let end = specification.encoding.end
        {
            rangeStartColumnID = start
            rangeEndColumnID = end
        } else {
            rangeStartColumnID = nil
            rangeEndColumnID = nil
        }
        let usesNormalizedMeasureAxis =
            specification.family == .normalizedBar
            && specification.stacking == .normalized
        func valueSemantics() -> AutoChartRenderedMeasureSemantics {
            AutoChartRenderedMeasureSemantics(
                columnID: specification.encoding.y,
                rangeStartColumnID: rangeStartColumnID,
                rangeEndColumnID: rangeEndColumnID,
                kind: .value,
                usesNormalizedMeasureAxis: usesNormalizedMeasureAxis)
        }
        func aggregatedSemantics(
            _ aggregation: AutoChartAggregation
        ) -> AutoChartRenderedMeasureSemantics {
            AutoChartRenderedMeasureSemantics(
                columnID: aggregation.preservesMeasureLineage
                    ? specification.encoding.y : nil,
                kind: .aggregated(aggregation),
                usesNormalizedMeasureAxis: usesNormalizedMeasureAxis)
        }

        switch specification.family {
        case .histogram:
            return Plan(
                operation: .histogram,
                measureSemantics: aggregatedSemantics(.count))
        case .heatmap:
            return Plan(
                operation: .heatmap,
                measureSemantics: aggregatedSemantics(.count))
        case .boxPlot:
            return Plan(operation: .boxPlot, measureSemantics: valueSemantics())
        case .kpi:
            return Plan(operation: .raw, measureSemantics: valueSemantics())
        case .donut:
            precondition(
                specification.aggregation != .none,
                "Donut preparation requires structural validation and an aggregation.")
            return Plan(
                operation: .grouped(specification.aggregation),
                measureSemantics: aggregatedSemantics(specification.aggregation))
        case .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar,
            .line, .pointLine, .area, .scatter, .bubble, .range, .faceted:
            if specification.aggregation == .none {
                return Plan(operation: .raw, measureSemantics: valueSemantics())
            }
            return Plan(
                operation: .grouped(specification.aggregation),
                measureSemantics: aggregatedSemantics(specification.aggregation))
        }
    }

    private static func raw(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        let encoding = specification.encoding
        return snapshot.rows.enumerated().compactMap { index, row in
            let xValue = encoding.x.flatMap { row.values[$0] }
            let yValue = encoding.y.flatMap { row.values[$0] }
            let seriesValue = encoding.series.flatMap { row.values[$0] }
            let facetValue = encoding.facet.flatMap { row.values[$0] }
            let start = encoding.start.flatMap { row.values[$0] }
            let end = encoding.end.flatMap { row.values[$0] }
            let xValueIdentity = encoding.x.map { id in
                AutoChartProfiler.identity(
                    xValue, semanticType: profiles[id]?.semanticType)
            }
            let seriesValueIdentity = encoding.series.map { id in
                AutoChartProfiler.identity(
                    seriesValue, semanticType: profiles[id]?.semanticType)
            }
            let facetValueIdentity = encoding.facet.map { id in
                AutoChartProfiler.identity(
                    facetValue, semanticType: profiles[id]?.semanticType)
            }
            let xIdentity = xValueIdentity?.stringValue
            let startDate = start.flatMap(AutoChartProfiler.dateValue)
            let endDate = end.flatMap(AutoChartProfiler.dateValue)
            if specification.family == .range {
                guard startDate != nil, endDate != nil else { return nil }
            } else if specification.family != .kpi,
                encoding.x != nil
            {
                guard xIdentity != nil else { return nil }
            }
            if specification.family != .kpi,
                encoding.y != nil,
                yValue?.numericValue == nil
            {
                return nil
            }
            return AutoChartDatum(
                id: "row-\(index)-\(row.id)",
                sourceRowIDs: [row.id],
                xIdentity: xIdentity,
                xSourceValue: xValue,
                xCategoryValue: xValueIdentity?.categoryValue,
                xLabel: xValueIdentity.flatMap { categoryLabel(for: $0) },
                xNumber: xValue?.numericValue,
                xDate: xValue.flatMap(AutoChartProfiler.dateValue),
                ySourceValue: yValue,
                yNumber: yValue?.numericValue,
                seriesIdentity: seriesValueIdentity?.stringValue,
                seriesSourceValue: seriesValue,
                seriesCategoryValue: seriesValueIdentity?.categoryValue,
                series: seriesValueIdentity.flatMap { categoryLabel(for: $0) },
                size: encoding.size.flatMap { row.values[$0]?.numericValue },
                facetIdentity: facetValueIdentity?.stringValue,
                facetSourceValue: facetValue,
                facetCategoryValue: facetValueIdentity?.categoryValue,
                facet: facetValueIdentity.flatMap { categoryLabel(for: $0) },
                startDate: startDate,
                endDate: endDate)
        }
    }

    private struct GroupKey: Hashable {
        var x: String
        var series: String
        var facet: String
    }

    private static func grouped(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        aggregation: AutoChartAggregation
    ) -> [AutoChartDatum] {
        guard aggregation != .none else { return [] }
        let rawData = raw(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let groups = Dictionary(grouping: rawData.enumerated()) { indexedDatum in
            let datum = indexedDatum.element
            return GroupKey(
                x: datum.xIdentity ?? "missing",
                series: datum.seriesIdentity ?? "missing",
                facet: datum.facetIdentity ?? "missing")
        }
        let aggregated = groups.sorted {
            $0.value[0].offset < $1.value[0].offset
        }.compactMap { _, indexedGroup -> AutoChartDatum? in
            let group = indexedGroup.map { $0.element }
            let values = group.compactMap { $0.yNumber }
            let result: Double
            switch aggregation {
            case .none:
                return nil
            case .sum:
                result = values.reduce(0, +)
            case .mean:
                guard !values.isEmpty else { return nil }
                result = values.reduce(0, +) / Double(values.count)
            case .minimum:
                guard let minimum = values.min() else { return nil }
                result = minimum
            case .maximum:
                guard let maximum = values.max() else { return nil }
                result = maximum
            case .count:
                result = Double(group.count)
            case .countDistinct:
                result = Double(
                    Set(
                        group.compactMap {
                            AutoChartProfiler.exactNumericIdentity($0.ySourceValue)
                        }
                    ).count)
            }
            let first = group[0]
            let xSourceValue = identicalSourceValue(
                in: group,
                value: \.xSourceValue,
                identity: \.xIdentity)
            let seriesSourceValue = identicalSourceValue(
                in: group,
                value: \.seriesSourceValue,
                identity: \.seriesIdentity)
            let facetSourceValue = identicalSourceValue(
                in: group,
                value: \.facetSourceValue,
                identity: \.facetIdentity)
            return AutoChartDatum(
                id: "group-\(first.id)",
                sourceRowIDs: group.reduce(into: []) {
                    $0.formUnion($1.sourceRowIDs)
                },
                xIdentity: first.xIdentity,
                xSourceValue: xSourceValue,
                xCategoryValue: first.xCategoryValue,
                xLabel: first.xLabel,
                xNumber: first.xNumber,
                xDate: first.xDate,
                yNumber: result,
                seriesIdentity: first.seriesIdentity,
                seriesSourceValue: seriesSourceValue,
                seriesCategoryValue: first.seriesCategoryValue,
                series: first.series,
                facetIdentity: first.facetIdentity,
                facetSourceValue: facetSourceValue,
                facetCategoryValue: first.facetCategoryValue,
                facet: first.facet)
        }
        return sorted(aggregated, specification: specification, profiles: profiles)
    }

    private static func histogram(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x else { return [] }
        let values = snapshot.rows.compactMap { row -> (Double, Int)? in
            guard let value = row.values[x]?.numericValue, value.isFinite else { return nil }
            return (value, row.id)
        }
        guard let first = values.first else { return [] }
        var minimum = first.0
        var maximum = first.0
        for value in values.dropFirst() {
            minimum = min(minimum, value.0)
            maximum = max(maximum, value.0)
        }
        if minimum == maximum {
            guard let bounds = expandedFiniteRange(
                minimum...maximum,
                padding: finiteSingletonPadding(for: minimum))
            else {
                assertionFailure("A finite histogram value requires finite display bounds.")
                return []
            }
            return [
                AutoChartDatum(
                    id: "bin-0",
                    sourceRowIDs: Set(values.map(\.1)),
                    xNumber: minimum,
                    yNumber: Double(values.count),
                    lower: bounds.lowerBound,
                    upper: bounds.upperBound)
            ]
        }
        let requestedCount = min(1_000, max(1, specification.binCount ?? 10))
        let scale = max(abs(minimum), abs(maximum))
        let scaledMinimum = minimum / scale
        let scaledMaximum = maximum / scale
        let scaledSpan = scaledMaximum - scaledMinimum
        func unscaledBoundary(at fraction: Double) -> Double {
            if fraction <= 0 { return minimum }
            if fraction >= 1 { return maximum }
            let scaledBoundary = scaledMinimum + scaledSpan * fraction
            let clamped = min(max(scaledBoundary, scaledMinimum), scaledMaximum)
            return min(max(clamped * scale, minimum), maximum)
        }
        var boundaries = [minimum]
        boundaries.reserveCapacity(requestedCount + 1)
        for index in 1..<requestedCount {
            let candidate = unscaledBoundary(
                at: Double(index) / Double(requestedCount))
            if candidate > boundaries[boundaries.count - 1], candidate < maximum {
                boundaries.append(candidate)
            }
        }
        boundaries.append(maximum)

        let count = boundaries.count - 1
        var bins: [[(Double, Int)]] = Array(repeating: [], count: count)
        for entry in values {
            let index = histogramBinIndex(
                containing: entry.0,
                boundaries: boundaries)
            bins[index].append(entry)
        }
        return bins.enumerated().map { index, bin in
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let exclusiveUpperBound = end.nextDown
            let scaledStart = start / scale
            let scaledEnd = end / scale
            let scaledMidpoint = scaledStart + (scaledEnd - scaledStart) / 2
            let midpoint = min(
                max(scaledMidpoint * scale, start),
                exclusiveUpperBound)
            return AutoChartDatum(
                id: "bin-\(index)",
                sourceRowIDs: Set(bin.map(\.1)),
                xNumber: midpoint,
                yNumber: Double(bin.count),
                lower: start,
                upper: end)
        }
    }

    private static func histogramBinIndex(
        containing value: Double,
        boundaries: [Double]
    ) -> Int {
        precondition(boundaries.count >= 2)
        let count = boundaries.count - 1
        var lowerIndex = 0
        var upperIndex = count
        while lowerIndex < upperIndex {
            let index = lowerIndex + (upperIndex - lowerIndex) / 2
            if value < boundaries[index + 1] {
                upperIndex = index
            } else {
                lowerIndex = index + 1
            }
        }
        return min(lowerIndex, count - 1)
    }

    private static func boxPlot(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let y = specification.encoding.y else { return [] }
        let x = specification.encoding.x
        struct BoxContributingValue {
            var measure: Double
            var rowID: Int
            var xSourceValue: AutoChartValue?
        }
        let allValuesLabel = AutoChartRenderPresentation.allValuesLabelMessage.defaultText
        let missingValueLabel =
            AutoChartRenderPresentation.missingValueLabelMessage.defaultText
        let semanticType = x.flatMap { profiles[$0]?.semanticType }
        var grouped: [AutoChartValueIdentity: [BoxContributingValue]] = [:]
        for row in snapshot.rows {
            guard let measure = AutoChartBoxPlotGrouping.measure(in: row, columnID: y)
            else { continue }
            let groupIdentity = AutoChartBoxPlotGrouping.categoryIdentity(
                in: row,
                columnID: x,
                semanticType: semanticType)
            grouped[groupIdentity, default: []].append(
                BoxContributingValue(
                    measure: measure,
                    rowID: row.id,
                    xSourceValue: x.flatMap { row.values[$0] }))
        }
        return grouped.map { groupIdentity, contributingValues in
            let sortedValues = contributingValues.map(\.measure).sorted()
            let identity = x == nil ? "all" : groupIdentity.stringValue
            let xSourceValue = x.flatMap { _ -> AutoChartValue? in
                guard let first = contributingValues.first?.xSourceValue,
                    contributingValues.dropFirst().allSatisfy({
                        hasSameSemanticValue($0.xSourceValue, as: first)
                    }),
                    groupIdentity != .missing || first == .null
                else { return nil }
                return canonicalSelectionValue(first)
            }
            let xLabel: String
            if x == nil {
                xLabel = allValuesLabel
            } else if groupIdentity == .missing {
                xLabel = missingValueLabel
            } else {
                xLabel = nonMissingCategoryLabel(for: groupIdentity)
            }
            func quantile(_ p: Double) -> Double {
                guard sortedValues.count > 1 else { return sortedValues[0] }
                let position = p * Double(sortedValues.count - 1)
                let lower = Int(position.rounded(.down))
                let upper = Int(position.rounded(.up))
                if lower == upper { return sortedValues[lower] }
                let fraction = position - Double(lower)
                return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
            }
            return AutoChartDatum(
                id: "box-\(identity ?? "missing")",
                sourceRowIDs: Set(contributingValues.map(\.rowID)),
                xIdentity: identity,
                xSourceValue: xSourceValue,
                xCategoryValue: groupIdentity.categoryValue,
                xLabel: xLabel,
                lower: sortedValues.first,
                quartile1: quantile(0.25),
                median: quantile(0.5),
                quartile3: quantile(0.75),
                upper: sortedValues.last)
        }.sorted {
            $0.id < $1.id
        }
    }

    private static func heatmap(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x, let y = specification.encoding.y else {
            return []
        }
        struct Key: Hashable {
            var xIdentity: AutoChartValueIdentity
            var yIdentity: AutoChartValueIdentity
        }
        var groups: [Key: [AutoChartSnapshot.Row]] = [:]
        for row in snapshot.rows {
            let xValueIdentity = AutoChartProfiler.identity(
                row.values[x], semanticType: profiles[x]?.semanticType)
            let yValueIdentity = AutoChartProfiler.identity(
                row.values[y], semanticType: profiles[y]?.semanticType)
            guard xValueIdentity != .missing, yValueIdentity != .missing else { continue }
            groups[
                Key(
                    xIdentity: xValueIdentity,
                    yIdentity: yValueIdentity),
                default: []
            ].append(row)
        }
        return groups.map { key, rows in
            guard let xIdentity = key.xIdentity.stringValue,
                let yIdentity = key.yIdentity.stringValue
            else {
                preconditionFailure("Heatmap groups require two renderable identities.")
            }
            return AutoChartDatum(
                id:
                    "heat-\(xIdentity.utf8.count):\(xIdentity)\(yIdentity.utf8.count):\(yIdentity)",
                sourceRowIDs: Set(rows.map(\.id)),
                xIdentity: xIdentity,
                xSourceValue: identicalSourceValue(
                    in: rows,
                    value: { $0.values[x] },
                    identity: { _ in xIdentity }),
                xCategoryValue: key.xIdentity.categoryValue,
                xLabel: nonMissingCategoryLabel(for: key.xIdentity),
                yIdentity: yIdentity,
                ySourceValue: identicalSourceValue(
                    in: rows,
                    value: { $0.values[y] },
                    identity: { _ in yIdentity }),
                yCategoryValue: key.yIdentity.categoryValue,
                yLabel: nonMissingCategoryLabel(for: key.yIdentity),
                yNumber: Double(rows.count))
        }.sorted {
            ($0.xLabel ?? "", $0.yLabel ?? "", $0.xIdentity ?? "", $0.yIdentity ?? "")
                < ($1.xLabel ?? "", $1.yLabel ?? "", $1.xIdentity ?? "", $1.yIdentity ?? "")
        }
    }

    private static func sorted(
        _ data: [AutoChartDatum],
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        let xSemanticType = specification.encoding.x.flatMap {
            profiles[$0]?.semanticType
        }
        if requiresContinuousXOrdering(
            family: specification.family,
            semanticType: xSemanticType)
        {
            if xSemanticType == .temporal {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xDate ?? .distantPast
                    let right = rhs.element.xDate ?? .distantPast
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
            if xSemanticType == .quantitative {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xNumber ?? -.infinity
                    let right = rhs.element.xNumber ?? -.infinity
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
        }
        return orderedByMeasure(data, sort: specification.sort) { offset, datum in
            AutoChartCategorySortKey(
                displayValue: datum.xLabel ?? "",
                identity: datum.xIdentity ?? "",
                sourceOffset: offset)
        }
    }
}

package func disambiguatedCategoryLabels(
    _ pairs: [(identity: String, label: String)],
    reserving reservedLabels: Set<String> = [],
    textResolver: AutoChartTextResolver
) -> [String: String] {
    let groups = Dictionary(grouping: pairs, by: \.label)
        .map { label, pairs in
            (label: label, identities: Array(Set(pairs.map(\.identity))).sorted())
        }
        .sorted { $0.label < $1.label }
    var labels: [String: String] = [:]
    var usedLabels = reservedLabels.union(groups.map(\.label))
    for (label, identities) in groups {
        if identities.count == 1, let identity = identities.first,
            !reservedLabels.contains(label)
        {
            labels[identity] = label
        }
    }
    for (label, identities) in groups {
        let unresolvedIdentities = identities.filter { labels[$0] == nil }
        guard !unresolvedIdentities.isEmpty else { continue }
        let kinds = unresolvedIdentities.map(
            AutoChartCategoryDisambiguationKind.init(identity:))
        let kindCounts = kinds.reduce(
            into: [AutoChartCategoryDisambiguationKind: Int]()
        ) { counts, kind in
            counts[kind, default: 0] += 1
        }
        var kindIndexes: [AutoChartCategoryDisambiguationKind: Int] = [:]
        for (identity, kind) in zip(unresolvedIdentities, kinds) {
            kindIndexes[kind, default: 0] += 1
            let index =
                kindCounts[kind, default: 0] == 1
                ? nil : kindIndexes[kind, default: 0]
            let qualifier = index.map { "\(kind.defaultText) \($0)" } ?? kind.defaultText
            let defaultText = "\(label) (\(qualifier))"
            var arguments: [String: AutoChartMessageArgument] = [
                "label": .string(label),
                "kind": .string(kind.rawValue),
            ]
            if let index { arguments["index"] = .integer(index) }
            let base = textResolver(
                AutoChartMessage(
                    category: .interface,
                    code: .categoryDisambiguation,
                    arguments: arguments,
                    defaultText: defaultText))
            var candidate = base
            var suffix = 2
            while usedLabels.contains(candidate) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            labels[identity] = candidate
            usedLabels.insert(candidate)
        }
    }
    return labels
}

/// A missing identity always uses the channel's resolved missing value, even
/// when preparation retained a source label for diagnostics or selection.
package func disambiguatedCategoryValue(
    identity: String?,
    label: String?,
    labels: [String: String],
    fallback: String
) -> String {
    guard let identity else { return fallback }
    return labels[identity] ?? label ?? identity
}

/// Gives a host one opportunity to specialize a resolved category for a second
/// surface while preserving the visible, disambiguated label as the fallback.
package func categoryValueForSurface(
    identity: String?,
    value: AutoChartValue?,
    label: String?,
    labels: [String: String],
    fallback: String,
    column: AutoChartColumn?,
    context: AutoChartFormattingContext,
    formatters: AutoChartFormatters
) -> String {
    let resolved = disambiguatedCategoryValue(
        identity: identity,
        label: label,
        labels: labels,
        fallback: fallback)
    guard let value else { return resolved }
    return formatters.formatOverride(
        AutoChartFormattingRequest(
            column: column,
            value: value,
            context: context)) ?? resolved
}

package func resolvedXCategoryDomain(
    in data: [AutoChartDatum],
    labels: [String: String],
    fallback: String
) -> [String] {
    var seen: Set<String> = []
    return data.compactMap { datum in
        let category = disambiguatedCategoryValue(
            identity: datum.xIdentity,
            label: datum.xLabel,
            labels: labels,
            fallback: fallback)
        return seen.insert(category).inserted ? category : nil
    }
}

package func orderedBoxPlotData(
    _ data: [AutoChartDatum],
    labels: [String: String],
    fallback: String,
    locale: Locale
) -> [AutoChartDatum] {
    data.enumerated().map { offset, datum in
        (
            datum: datum,
            sortKey: AutoChartCategorySortKey(
                displayValue: disambiguatedCategoryValue(
                    identity: datum.xIdentity,
                    label: datum.xLabel,
                    labels: labels,
                    fallback: fallback),
                identity: datum.xIdentity ?? "",
                sourceOffset: offset)
        )
    }.sorted {
        categoryPrecedes($0.sortKey, $1.sortKey, locale: locale)
    }.map(\.datum)
}

package struct AutoChartFacetPanel: Sendable {
    package let key: String?
    package let data: [AutoChartDatum]
    package let displayValue: String
}

package func orderedFacetPanels(
    in data: [AutoChartDatum],
    labels: [String: String],
    fallback: String,
    locale: Locale
) -> [AutoChartFacetPanel] {
    let facets = Dictionary(grouping: data, by: \.facetIdentity)
    return facets.map { key, panelData in
        AutoChartFacetPanel(
            key: key,
            data: panelData,
            displayValue: disambiguatedCategoryValue(
                identity: key,
                label: panelData.first?.facet,
                labels: labels,
                fallback: fallback))
    }.enumerated().sorted { lhs, rhs in
        categoryPrecedes(
            AutoChartCategorySortKey(
                displayValue: lhs.element.displayValue,
                identity: lhs.element.key ?? "",
                sourceOffset: lhs.offset),
            AutoChartCategorySortKey(
                displayValue: rhs.element.displayValue,
                identity: rhs.element.key ?? "",
                sourceOffset: rhs.offset),
            locale: locale)
    }.map(\.element)
}

/// Applies presentation-time category labels to ordering decisions without
/// mutating the reusable prepared chart core. Preparation remains deterministic;
/// the rendered view follows the labels the host actually supplied.
package func orderedPresentedData(
    _ data: [AutoChartDatum],
    specification: AutoChartSpecification,
    xLabels: [String: String],
    yLabels: [String: String],
    missingValue: String,
    locale: Locale
) -> [AutoChartDatum] {
    func key(
        identity: String?,
        preparedLabel: String?,
        labels: [String: String],
        offset: Int
    ) -> AutoChartCategorySortKey {
        AutoChartCategorySortKey(
            displayValue: disambiguatedCategoryValue(
                identity: identity,
                label: preparedLabel,
                labels: labels,
                fallback: missingValue),
            identity: identity ?? "",
            sourceOffset: offset)
    }

    if specification.family == .heatmap {
        return data.enumerated().map { offset, datum in
            (
                datum: datum,
                x: key(
                    identity: datum.xIdentity,
                    preparedLabel: datum.xLabel,
                    labels: xLabels,
                    offset: 0),
                y: key(
                    identity: datum.yIdentity,
                    preparedLabel: datum.yLabel,
                    labels: yLabels,
                    offset: offset)
            )
        }.sorted { lhs, rhs in
            if lhs.x.displayValue != rhs.x.displayValue || lhs.x.identity != rhs.x.identity {
                return categoryPrecedes(lhs.x, rhs.x, locale: locale)
            }
            return categoryPrecedes(lhs.y, rhs.y, locale: locale)
        }.map(\.datum)
    }

    guard !xLabels.isEmpty else { return data }
    return orderedByMeasure(
        data,
        sort: specification.sort,
        locale: locale
    ) { offset, datum in
        key(
            identity: datum.xIdentity,
            preparedLabel: datum.xLabel,
            labels: xLabels,
            offset: offset)
    }
}

fileprivate struct AutoChartGeneratedTextRequirements: Sendable {
    var resolvesXTitle: Bool
    var resolvesYTitle: Bool
    var resolvesSeriesTitle: Bool
    var resolvesFacetTitle: Bool
    var countTitle: AutoChartMessage?
    var medianTitle: AutoChartMessage?
    var rangeStartTitle: AutoChartMessage?
    var rangeEndTitle: AutoChartMessage?
    var dateTitle: AutoChartMessage?
    var allValuesLabel: AutoChartMessage?
    var missingValueLabel: AutoChartMessage?
    var missingSeriesLabel: AutoChartMessage?
    var missingFacetLabel: AutoChartMessage?
}

private struct AutoChartGeneratedTextUsage {
    var resolvesXTitle: Bool
    var resolvesYTitle: Bool
    var usesCountTitle: Bool
    var usesMedianTitle: Bool
    var usesRangeTitles: Bool
}

private extension AutoChartFamily {
    var generatedTextUsage: AutoChartGeneratedTextUsage {
        switch self {
        case .kpi:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: false,
                resolvesYTitle: false,
                usesCountTitle: false,
                usesMedianTitle: false,
                usesRangeTitles: false)
        case .histogram:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: true,
                resolvesYTitle: false,
                usesCountTitle: true,
                usesMedianTitle: false,
                usesRangeTitles: false)
        case .heatmap:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: true,
                resolvesYTitle: true,
                usesCountTitle: true,
                usesMedianTitle: false,
                usesRangeTitles: false)
        case .boxPlot:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: true,
                resolvesYTitle: true,
                usesCountTitle: false,
                usesMedianTitle: true,
                usesRangeTitles: false)
        case .range:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: true,
                resolvesYTitle: false,
                usesCountTitle: false,
                usesMedianTitle: false,
                usesRangeTitles: true)
        case .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar,
            .line, .pointLine, .area, .scatter, .bubble, .donut, .faceted:
            AutoChartGeneratedTextUsage(
                resolvesXTitle: true,
                resolvesYTitle: true,
                usesCountTitle: false,
                usesMedianTitle: false,
                usesRangeTitles: false)
        }
    }
}

package struct AutoChartRenderPresentation: Sendable {
    package static let categoryTitleMessage = AutoChartMessage(
        category: .interface, code: .categoryTitle, defaultText: "Category")
    package static let valueTitleMessage = AutoChartMessage(
        category: .interface, code: .valueTitle, defaultText: "Value")
    package static let countTitleMessage = AutoChartMessage(
        category: .interface, code: .countTitle, defaultText: "Count")
    package static let medianTitleMessage = AutoChartMessage(
        category: .interface, code: .medianTitle, defaultText: "Median")
    package static let defaultSeriesTitleMessage = AutoChartMessage(
        category: .interface, code: .seriesTitle, defaultText: "Series")
    package static let defaultFacetTitleMessage = AutoChartMessage(
        category: .interface, code: .facetTitle, defaultText: "Facet")
    package static let rangeStartTitleMessage = AutoChartMessage(
        category: .interface, code: .rangeStartTitle, defaultText: "Start")
    package static let rangeEndTitleMessage = AutoChartMessage(
        category: .interface, code: .rangeEndTitle, defaultText: "End")
    package static let dateTitleMessage = AutoChartMessage(
        category: .interface, code: .dateTitle, defaultText: "Date")
    package static let allValuesLabelMessage = AutoChartMessage(
        category: .interface, code: .allValuesLabel, defaultText: "All")
    package static let missingValueLabelMessage = AutoChartMessage(
        category: .interface, code: .missingValueLabel, defaultText: "Missing value")
    package static let missingSeriesLabelMessage = AutoChartMessage(
        category: .interface, code: .missingSeriesLabel, defaultText: "Missing series")
    package static let missingFacetLabelMessage = AutoChartMessage(
        category: .interface, code: .missingFacetLabel, defaultText: "Missing facet")

    package var sizeBounds: (minimum: Double, maximum: Double)?
    package var sharedYDomain: ClosedRange<Double>?
    package var sharedXDateDomain: ClosedRange<Date>?
    package var sharedXNumberDomain: ClosedRange<Double>?
    package var family: AutoChartFamily
    package var facetBaseFamily: AutoChartFamily?
    package var xTitle: String
    package var xTitleMessage: AutoChartMessage?
    package var yTitle: String
    package var yTitleMessage: AutoChartMessage?
    package var seriesTitle: String
    package var seriesTitleMessage: AutoChartMessage?
    package var facetTitle: String
    package var facetTitleMessage: AutoChartMessage?
    package var xSemanticType: AutoChartSemanticType?
    package var usesXIdentityLabels: Bool
    package var usesYIdentityLabels: Bool
    package var usesSeriesIdentityLabels: Bool
    package var usesFacetIdentityLabels: Bool
    package var usesAnyIdentityLabels: Bool {
        usesXIdentityLabels || usesYIdentityLabels
            || usesSeriesIdentityLabels || usesFacetIdentityLabels
    }
    package var usesSharedXCategoryDomain: Bool
    fileprivate var xCategoryColumn: AutoChartColumn?
    fileprivate var yCategoryColumn: AutoChartColumn?
    fileprivate var seriesCategoryColumn: AutoChartColumn?
    fileprivate var facetCategoryColumn: AutoChartColumn?
    fileprivate var generatedTextRequirements: AutoChartGeneratedTextRequirements
    package var xCategoryCount: Int
    package var timeZoomValueCount: Int
    package var timeZoomSpan: TimeInterval
    package var numberZoomValueCount: Int
    package var numberZoomSpan: Double

    package init(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        data: [AutoChartDatum],
        measureSemantics: AutoChartRenderedMeasureSemantics
    ) {
        func numericDomain(
            _ values: [Double],
            includingZero: Bool
        ) -> ClosedRange<Double>? {
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let lower = includingZero ? min(0, minimum) : minimum
            let upper = includingZero ? max(0, maximum) : maximum
            if lower == upper {
                return expandedFiniteRange(
                    lower...upper,
                    padding: finiteSingletonPadding(for: lower))
            }
            if includingZero {
                return expandedFiniteRange(lower...upper, padding: 0)
            }
            let span = upper - lower
            let padding = span.isFinite ? span * 0.05 : 0
            return expandedFiniteRange(lower...upper, padding: padding)
        }
        func xNumberDomain(_ values: [Double]) -> ClosedRange<Double>? {
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            if minimum == maximum {
                return expandedFiniteRange(
                    minimum...maximum,
                    padding: finiteSingletonPadding(for: minimum))
            }
            let span = maximum - minimum
            let padding = span.isFinite ? span * 0.05 : 0
            return expandedFiniteRange(minimum...maximum, padding: padding)
        }
        func dateDomain(_ values: [Date]) -> ClosedRange<Date>? {
            // A non-finite date can't bound an axis — it collapses the whole
            // domain to NaN — so drop it the way the numeric domains drop theirs.
            let values = values.filter { $0.timeIntervalSinceReferenceDate.isFinite }
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let lowerInterval = minimum.timeIntervalSinceReferenceDate
            let upperInterval = maximum.timeIntervalSinceReferenceDate
            let intervalRange: ClosedRange<Double>
            if minimum == maximum {
                guard let expanded = expandedFiniteRange(
                    lowerInterval...upperInterval,
                    padding: 43_200)
                else { return nil }
                intervalRange = expanded
            } else {
                let span = upperInterval - lowerInterval
                let padding = span.isFinite ? span * 0.05 : 0
                guard let expanded = expandedFiniteRange(
                    lowerInterval...upperInterval,
                    padding: padding)
                else { return nil }
                intervalRange = expanded
            }
            let lower = Date(timeIntervalSinceReferenceDate: intervalRange.lowerBound)
            let upper = Date(timeIntervalSinceReferenceDate: intervalRange.upperBound)
            return lower...upper
        }
        let xSemanticType = specification.encoding.x.flatMap { profiles[$0]?.semanticType }
        let xIsCategorical =
            specification.encoding.x.flatMap {
                profiles[$0]?.isCategorical
            } ?? false
        let xUsesIdentityLabels =
            xIsCategorical
            || (specification.family == .boxPlot && specification.encoding.x == nil)
        let facetBaseFamily = AutoChartRecommendationEngine.resolvedFacetBaseFamily(
            specification: specification,
            profiles: profiles)

        if specification.family == .bubble {
            let sizes = data.compactMap(\.size).filter(\.isFinite)
            if let minimum = sizes.min(), let maximum = sizes.max() {
                sizeBounds = (minimum, maximum)
            } else {
                sizeBounds = nil
            }
        } else {
            sizeBounds = nil
        }

        if specification.family == .faceted {
            sharedYDomain = numericDomain(
                data.compactMap(\.yNumber).filter(\.isFinite),
                includingZero: xIsCategorical)
            sharedXDateDomain =
                xSemanticType == .temporal
                ? dateDomain(data.compactMap(\.xDate)) : nil
            sharedXNumberDomain =
                xSemanticType == .quantitative
                ? xNumberDomain(data.compactMap(\.xNumber).filter(\.isFinite)) : nil
        } else {
            sharedYDomain = nil
            sharedXDateDomain = nil
            sharedXNumberDomain = nil
        }

        family = specification.family
        self.facetBaseFamily = facetBaseFamily
        self.xSemanticType = xSemanticType
        xCategoryColumn = specification.encoding.x.flatMap(snapshot.column)
        yCategoryColumn = specification.encoding.y.flatMap(snapshot.column)
        seriesCategoryColumn = specification.encoding.series.flatMap(snapshot.column)
        facetCategoryColumn = specification.encoding.facet.flatMap(snapshot.column)
        usesXIdentityLabels = xUsesIdentityLabels
        usesYIdentityLabels = specification.family == .heatmap
        usesSeriesIdentityLabels = specification.encoding.series != nil
        usesFacetIdentityLabels = specification.encoding.facet != nil
        usesSharedXCategoryDomain = specification.family == .faceted && xIsCategorical
        xCategoryCount = Set(data.compactMap { $0.xIdentity ?? $0.xLabel }).count
        let zoomSource = specification.family.zoomSource(for: xSemanticType)
        var minimumZoomDate: Date?
        var maximumZoomDate: Date?
        var zoomDateCount = 0
        var minimumZoomNumber: Double?
        var maximumZoomNumber: Double?
        var zoomNumberCount = 0
        func includeZoomDate(_ date: Date?) {
            guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return }
            zoomDateCount += 1
            minimumZoomDate = min(minimumZoomDate ?? date, date)
            maximumZoomDate = max(maximumZoomDate ?? date, date)
        }
        if zoomSource != .none {
            for datum in data {
                switch zoomSource {
                case .intervalDates:
                    includeZoomDate(datum.startDate)
                    includeZoomDate(datum.endDate)
                case .temporalX:
                    includeZoomDate(datum.xDate)
                case .numericX:
                    if let number = datum.xNumber, number.isFinite {
                        zoomNumberCount += 1
                        minimumZoomNumber = min(minimumZoomNumber ?? number, number)
                        maximumZoomNumber = max(maximumZoomNumber ?? number, number)
                    }
                case .none:
                    break
                }
            }
        }
        if let minimumZoomDate, let maximumZoomDate {
            let span = maximumZoomDate.timeIntervalSince(minimumZoomDate)
            timeZoomValueCount = span.isFinite ? zoomDateCount : 0
            timeZoomSpan = span.isFinite ? max(86_400, span) : 86_400
        } else {
            timeZoomValueCount = 0
            timeZoomSpan = 86_400
        }
        if let minimumZoomNumber, let maximumZoomNumber {
            let span = maximumZoomNumber - minimumZoomNumber
            numberZoomValueCount = span.isFinite ? zoomNumberCount : 0
            numberZoomSpan = span.isFinite ? max(1, span) : 1
        } else {
            numberZoomValueCount = 0
            numberZoomSpan = 1
        }
        if let sourceXTitle = specification.encoding.x.flatMap({ snapshot.column($0) })
            .map(AutoChartProfiler.displayName)
        {
            xTitle = sourceXTitle
            xTitleMessage = nil
        } else {
            xTitle = "Category"
            xTitleMessage = Self.categoryTitleMessage
        }
        let sourceYTitle = specification.encoding.y.flatMap { snapshot.column($0) }
            .map(AutoChartProfiler.displayName)
        let resolvedYTitle: (text: String, message: AutoChartMessage?) =
            switch measureSemantics.aggregation {
        case .count where ![.histogram, .heatmap].contains(specification.family):
            (
                "Count",
                Self.countTitleMessage)
        case .countDistinct:
            {
                let text = sourceYTitle.map { "Distinct count of \($0)" }
                    ?? "Distinct count"
                return (
                    text,
                    AutoChartMessage(
                        category: .interface,
                        code: .distinctCountTitle,
                        arguments: sourceYTitle.map { ["column": .string($0)] } ?? [:],
                        defaultText: text))
            }()
        case .none, .sum, .mean, .minimum, .maximum, .count:
            if let sourceYTitle {
                (sourceYTitle, nil)
            } else {
                (
                    "Value",
                    Self.valueTitleMessage)
            }
        }
        yTitle = resolvedYTitle.text
        yTitleMessage = resolvedYTitle.message
        if let sourceSeriesTitle = specification.encoding.series
            .flatMap({ snapshot.column($0) }).map(AutoChartProfiler.displayName)
        {
            seriesTitle = sourceSeriesTitle
            seriesTitleMessage = nil
        } else {
            seriesTitle = "Series"
            seriesTitleMessage = Self.defaultSeriesTitleMessage
        }
        if let sourceFacetTitle = specification.encoding.facet
            .flatMap({ snapshot.column($0) }).map(AutoChartProfiler.displayName)
        {
            facetTitle = sourceFacetTitle
            facetTitleMessage = nil
        } else {
            facetTitle = "Facet"
            facetTitleMessage = Self.defaultFacetTitleMessage
        }
        let generatedTextUsage = specification.family.generatedTextUsage
        generatedTextRequirements = AutoChartGeneratedTextRequirements(
            resolvesXTitle: generatedTextUsage.resolvesXTitle,
            resolvesYTitle: generatedTextUsage.resolvesYTitle,
            resolvesSeriesTitle: specification.encoding.series != nil,
            resolvesFacetTitle: specification.encoding.facet != nil,
            countTitle: generatedTextUsage.usesCountTitle
                ? Self.countTitleMessage : nil,
            medianTitle: generatedTextUsage.usesMedianTitle ? Self.medianTitleMessage : nil,
            rangeStartTitle: generatedTextUsage.usesRangeTitles
                ? Self.rangeStartTitleMessage : nil,
            rangeEndTitle: generatedTextUsage.usesRangeTitles
                ? Self.rangeEndTitleMessage : nil,
            dateTitle: generatedTextUsage.usesRangeTitles ? Self.dateTitleMessage : nil,
            allValuesLabel: specification.family == .boxPlot && specification.encoding.x == nil
                ? Self.allValuesLabelMessage : nil,
            missingValueLabel: xUsesIdentityLabels || specification.family == .heatmap
                ? Self.missingValueLabelMessage : nil,
            missingSeriesLabel: specification.encoding.series == nil
                ? nil : Self.missingSeriesLabelMessage,
            missingFacetLabel: specification.encoding.facet == nil
                ? nil : Self.missingFacetLabelMessage)
    }

    package func resolvedYTitle(using textResolver: AutoChartTextResolver) -> String {
        yTitleMessage.map(textResolver.callAsFunction) ?? yTitle
    }

    package func resolvedPresentation(
        data: [AutoChartDatum],
        using textResolver: AutoChartTextResolver,
        formatters: AutoChartFormatters = .init()
    ) -> AutoChartResolvedPresentation {
        let isReentrant = AutoChartHostCallbackActivity.hasActiveCallback
        let effectiveTextResolver: AutoChartTextResolver =
            isReentrant ? .default : textResolver
        let effectiveFormatters = isReentrant ? formatters.callbackFree : formatters
        return AutoChartResolvedPresentation(
            presentation: self,
            data: data,
            textResolver: effectiveTextResolver,
            formatters: effectiveFormatters,
            histogramLabelResolution: isReentrant ? .callbackFreeFallback : .prepared)
    }
}

private struct AutoChartHistogramBinAccessibilityLabels: Sendable {
    private struct Key: Hashable, Sendable {
        let lowerBitPattern: UInt64
        let upperBitPattern: UInt64

        init(lower: Double, upper: Double) {
            lowerBitPattern = lower.bitPattern
            upperBitPattern = upper.bitPattern
        }
    }

    private struct Bounds {
        let key: Key
        let lower: Double
        let upper: Double

        init?(_ datum: AutoChartDatum) {
            guard let lower = datum.lower, lower.isFinite,
                let upper = datum.upper, upper.isFinite
            else { return nil }
            key = Key(lower: lower, upper: upper)
            self.lower = lower
            self.upper = upper
        }
    }

    private enum Storage: Sendable {
        case prepared(
            labels: [Key: String],
            column: AutoChartColumn?,
            fallbackFormatters: AutoChartFormatters)
        case callbackFreeFallback(
            column: AutoChartColumn?,
            formatters: AutoChartFormatters)
    }

    private let storage: Storage

    init(
        data: [AutoChartDatum],
        column: AutoChartColumn?,
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver
    ) {
        var labels: [Key: String] = [:]
        labels.reserveCapacity(data.count)
        for datum in data {
            guard let bounds = Bounds(datum) else {
                assertionFailure("Prepared histogram bins require finite bounds.")
                continue
            }
            // Equivalent intervals have the same semantic label regardless of
            // datum identity. Resolve each exact pair only once.
            guard labels[bounds.key] == nil else { continue }
            labels[bounds.key] = AutoChartAccessibility.histogramBinLabel(
                lower: bounds.lower,
                upper: bounds.upper,
                column: column,
                formatters: formatters,
                textResolver: textResolver)
        }
        storage = .prepared(
            labels: labels,
            column: column,
            fallbackFormatters: formatters.callbackFree)
    }

    init(
        callbackFreeFallbackFor column: AutoChartColumn?,
        formatters: AutoChartFormatters
    ) {
        storage = .callbackFreeFallback(
            column: column,
            formatters: formatters.callbackFree)
    }

    private static func callbackFreeLabel(
        for bounds: Bounds,
        column: AutoChartColumn?,
        formatters: AutoChartFormatters
    ) -> String {
        AutoChartAccessibility.histogramBinLabel(
            lower: bounds.lower,
            upper: bounds.upper,
            column: column,
            formatters: formatters,
            textResolver: .default)
    }

    func label(for datum: AutoChartDatum) -> String {
        guard let bounds = Bounds(datum) else {
            assertionFailure("Prepared histogram bins require finite bounds.")
            return AutoChartValue.unrepresentableValuePlaceholder
        }
        switch storage {
        case .prepared(let labels, let column, let fallbackFormatters):
            guard let label = labels[bounds.key] else {
                assertionFailure("A histogram bin must retain its exact prepared bounds.")
                return Self.callbackFreeLabel(
                    for: bounds,
                    column: column,
                    formatters: fallbackFormatters)
            }
            return label
        case .callbackFreeFallback(let column, let formatters):
            return Self.callbackFreeLabel(
                for: bounds,
                column: column,
                formatters: formatters)
        }
    }
}

package enum AutoChartHistogramLabelResolution {
    case prepared
    case callbackFreeFallback
}

package struct AutoChartResolvedPresentation: Sendable {
    package var x: String
    package var y: String
    package var series: String
    package var facet: String
    package var count: String
    package var median: String
    package var rangeStart: String
    package var rangeEnd: String
    package var date: String
    package var missingValue: String
    package var missingSeries: String
    package var missingFacet: String
    package var xDisplayLabels: [String: String]
    package var yDisplayLabels: [String: String]
    package var seriesDisplayLabels: [String: String]
    package var facetDisplayLabels: [String: String]
    /// Prepared labels and callback-free fallback state are safe to read from
    /// concurrent SwiftUI view copies.
    private let histogramBinAccessibilityLabels:
        AutoChartHistogramBinAccessibilityLabels?

    package init(
        presentation: AutoChartRenderPresentation,
        data: [AutoChartDatum],
        textResolver: AutoChartTextResolver,
        formatters: AutoChartFormatters,
        histogramLabelResolution: AutoChartHistogramLabelResolution
    ) {
        func resolve(_ message: AutoChartMessage?, fallback: String) -> String {
            message.map(textResolver.callAsFunction) ?? fallback
        }
        let requirements = presentation.generatedTextRequirements
        let resolvedX = resolve(
            requirements.resolvesXTitle ? presentation.xTitleMessage : nil,
            fallback: presentation.xTitle)
        let resolvedY = resolve(
            requirements.resolvesYTitle ? presentation.yTitleMessage : nil,
            fallback: presentation.yTitle)
        let resolvedSeries = resolve(
            requirements.resolvesSeriesTitle ? presentation.seriesTitleMessage : nil,
            fallback: presentation.seriesTitle)
        let resolvedFacet = resolve(
            requirements.resolvesFacetTitle ? presentation.facetTitleMessage : nil,
            fallback: presentation.facetTitle)
        let resolvedCount = resolve(
            requirements.countTitle,
            fallback: AutoChartRenderPresentation.countTitleMessage.defaultText)
        let resolvedMedian = resolve(
            requirements.medianTitle,
            fallback: AutoChartRenderPresentation.medianTitleMessage.defaultText)
        let resolvedRangeStart = resolve(
            requirements.rangeStartTitle,
            fallback: AutoChartRenderPresentation.rangeStartTitleMessage.defaultText)
        let resolvedRangeEnd = resolve(
            requirements.rangeEndTitle,
            fallback: AutoChartRenderPresentation.rangeEndTitleMessage.defaultText)
        let resolvedDate = resolve(
            requirements.dateTitle,
            fallback: AutoChartRenderPresentation.dateTitleMessage.defaultText)
        let resolvedAllValues = resolve(
            requirements.allValuesLabel,
            fallback: AutoChartRenderPresentation.allValuesLabelMessage.defaultText)
        var resolvedMissingValue = AutoChartRenderPresentation.missingValueLabelMessage.defaultText
        var resolvedMissingSeries = AutoChartRenderPresentation.missingSeriesLabelMessage.defaultText
        var resolvedMissingFacet = AutoChartRenderPresentation.missingFacetLabelMessage.defaultText

        struct CategoryEntry {
            var identity: String
            var value: AutoChartValue?
            var preparedLabel: String?
        }

        struct CategoryEntries {
            var values: [CategoryEntry] = []
            var seen: Set<String> = []
            var needsMissing = false

            mutating func include(
                identity: String?,
                value: AutoChartValue?,
                preparedLabel: String?
            ) {
                guard let identity else {
                    needsMissing = true
                    return
                }
                guard seen.insert(identity).inserted else { return }
                values.append(
                    CategoryEntry(
                        identity: identity,
                        value: value,
                        preparedLabel: preparedLabel))
            }
        }

        var xEntries = CategoryEntries()
        var yEntries = CategoryEntries()
        var seriesEntries = CategoryEntries()
        var facetEntries = CategoryEntries()
        if presentation.usesAnyIdentityLabels {
            for datum in data {
                if presentation.usesXIdentityLabels {
                    xEntries.include(
                        identity: datum.xIdentity,
                        value: datum.xCategoryValue,
                        preparedLabel: datum.xLabel)
                }
                if presentation.usesYIdentityLabels {
                    yEntries.include(
                        identity: datum.yIdentity,
                        value: datum.yCategoryValue,
                        preparedLabel: datum.yLabel)
                }
                if presentation.usesSeriesIdentityLabels {
                    seriesEntries.include(
                        identity: datum.seriesIdentity,
                        value: datum.seriesCategoryValue,
                        preparedLabel: datum.series)
                }
                if presentation.usesFacetIdentityLabels {
                    facetEntries.include(
                        identity: datum.facetIdentity,
                        value: datum.facetCategoryValue,
                        preparedLabel: datum.facet)
                }
            }
        }

        func resolvedCategoryPairs(
            _ entries: CategoryEntries,
            column: AutoChartColumn?,
            context: AutoChartFormattingContext
        ) -> [(identity: String, label: String)] {
            guard !entries.values.isEmpty else { return [] }
            let dates = entries.values.compactMap { entry -> Date? in
                guard case .date(let date)? = entry.value else { return nil }
                return date
            }
            let calendar = dates.isEmpty ? nil
                : AutoChartDateFormatting.localeCalendar(
                    locale: formatters.locale,
                    timeZone: formatters.timeZone)
            let datePrecision = calendar.flatMap { calendar in
                dates.map {
                    AutoChartDateFormatting.precision(
                        for: $0,
                        calendar: calendar)
                }.max()
            }
            return entries.values.compactMap { entry -> (String, String)? in
                guard let value = entry.value else {
                    return entry.preparedLabel.map { (entry.identity, $0) }
                }
                return (
                    entry.identity,
                    formatters.formatCategory(
                        column: column,
                        value: value,
                        context: context,
                        datePrecision: datePrecision,
                        calendar: calendar))
            }
        }

        let xPairs = resolvedCategoryPairs(
            xEntries,
            column: presentation.xCategoryColumn,
            context: .axisTick).map { pair in
            (
                pair.identity,
                requirements.allValuesLabel != nil && pair.identity == "all"
                    ? resolvedAllValues : pair.label
            )
        }
        let needsMissingValue = xEntries.needsMissing

        let yPairs = resolvedCategoryPairs(
            yEntries,
            column: presentation.yCategoryColumn,
            context: .axisTick)

        let seriesPairs = resolvedCategoryPairs(
            seriesEntries,
            column: presentation.seriesCategoryColumn,
            context: .legend)
        let needsMissingSeries = seriesEntries.needsMissing

        let facetPairs = resolvedCategoryPairs(
            facetEntries,
            column: presentation.facetCategoryColumn,
            context: .facetHeader)
        let needsMissingFacet = facetEntries.needsMissing

        if needsMissingValue {
            resolvedMissingValue = resolve(
                requirements.missingValueLabel,
                fallback: resolvedMissingValue)
        }
        if needsMissingSeries {
            resolvedMissingSeries = resolve(
                requirements.missingSeriesLabel,
                fallback: resolvedMissingSeries)
        }
        if needsMissingFacet {
            resolvedMissingFacet = resolve(
                requirements.missingFacetLabel,
                fallback: resolvedMissingFacet)
        }

        let resolvedXDisplayLabels =
            presentation.usesXIdentityLabels
            ? disambiguatedCategoryLabels(
                xPairs,
                reserving: needsMissingValue ? [resolvedMissingValue] : [],
                textResolver: textResolver) : [:]
        let resolvedYDisplayLabels =
            presentation.usesYIdentityLabels
            ? disambiguatedCategoryLabels(yPairs, textResolver: textResolver) : [:]
        let resolvedSeriesDisplayLabels =
            presentation.usesSeriesIdentityLabels
            ? disambiguatedCategoryLabels(
                seriesPairs,
                reserving: needsMissingSeries ? [resolvedMissingSeries] : [],
                textResolver: textResolver) : [:]
        let resolvedFacetDisplayLabels =
            presentation.usesFacetIdentityLabels
            ? disambiguatedCategoryLabels(
                facetPairs,
                reserving: needsMissingFacet ? [resolvedMissingFacet] : [],
                textResolver: textResolver) : [:]
        x = resolvedX
        y = resolvedY
        series = resolvedSeries
        facet = resolvedFacet
        count = resolvedCount
        median = resolvedMedian
        rangeStart = resolvedRangeStart
        rangeEnd = resolvedRangeEnd
        date = resolvedDate
        missingValue = resolvedMissingValue
        missingSeries = resolvedMissingSeries
        missingFacet = resolvedMissingFacet
        xDisplayLabels = resolvedXDisplayLabels
        yDisplayLabels = resolvedYDisplayLabels
        seriesDisplayLabels = resolvedSeriesDisplayLabels
        facetDisplayLabels = resolvedFacetDisplayLabels
        if presentation.family != .histogram {
            histogramBinAccessibilityLabels = nil
        } else {
            switch histogramLabelResolution {
            case .prepared:
                histogramBinAccessibilityLabels = AutoChartHistogramBinAccessibilityLabels(
                    data: data,
                    column: presentation.xCategoryColumn,
                    formatters: formatters,
                    textResolver: textResolver)
            case .callbackFreeFallback:
                histogramBinAccessibilityLabels = AutoChartHistogramBinAccessibilityLabels(
                    callbackFreeFallbackFor: presentation.xCategoryColumn,
                    formatters: formatters)
            }
        }
    }

    package func histogramBinAccessibilityLabel(for datum: AutoChartDatum) -> String {
        guard let histogramBinAccessibilityLabels else {
            assertionFailure("Only histograms have prepared bin accessibility labels.")
            return AutoChartValue.unrepresentableValuePlaceholder
        }
        return histogramBinAccessibilityLabels.label(for: datum)
    }
}

private enum AutoChartZoomSource: Equatable {
    case none
    case temporalX
    case numericX
    case intervalDates
}

private extension AutoChartFamily {
    func zoomSource(for semanticType: AutoChartSemanticType?) -> AutoChartZoomSource {
        switch self {
        case .range:
            return .intervalDates
        case .histogram:
            return .numericX
        case .line, .pointLine, .area, .scatter, .bubble:
            if semanticType == .temporal { return .temporalX }
            if semanticType == .quantitative { return .numericX }
            return .none
        default:
            return .none
        }
    }
}

package final class AutoChartPreparedTable: Sendable {
    package let snapshot: AutoChartSnapshot
    package let profiles: [AutoChartColumnID: AutoChartColumnProfile]
    package let fingerprint: Int
    package let estimatedCost: Int

    package init(
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        fingerprint: Int,
        estimatedCost: Int
    ) {
        self.snapshot = snapshot
        self.profiles = profiles
        self.fingerprint = fingerprint
        self.estimatedCost = estimatedCost
    }
}

package struct AutoChartRenderCore: Sendable {
    package let table: AutoChartPreparedTable
    package let data: [AutoChartDatum]
    package let measureSemantics: AutoChartRenderedMeasureSemantics
    package let validation: AutoChartValidationResult
    package let presentation: AutoChartRenderPresentation

    package var snapshot: AutoChartSnapshot { table.snapshot }
    package var fingerprint: Int { table.fingerprint }

    package static func prepare(
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        contentFingerprint: Int,
        estimatedStorageCost: Int,
        recommendation: AutoChartRecommendation
    ) throws -> AutoChartRenderCore {
        let specification = recommendation.specification
        let structuralValidation = AutoChartRecommendationEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles,
            validatesPreparedNumericDomain: false)
        guard structuralValidation.isValid else {
            throw AutoChartPreparationError.invalidSpecification(structuralValidation)
        }
        let preparedData = AutoChartDataPreparation.preparedData(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let validation = AutoChartRecommendationEngine.validatePreparedNumericDomain(
            structuralValidation: structuralValidation,
            specification: specification,
            snapshot: snapshot,
            profiles: profiles,
            preparedData: preparedData.data)
        guard validation.isValid else {
            throw AutoChartPreparationError.invalidSpecification(validation)
        }
        let table = AutoChartPreparedTable(
            snapshot: snapshot,
            profiles: profiles,
            fingerprint: contentFingerprint,
            estimatedCost: estimatedStorageCost)
        return AutoChartRenderCore(
            table: table,
            data: preparedData.data,
            measureSemantics: preparedData.measureSemantics,
            validation: validation,
            presentation: AutoChartRenderPresentation(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles,
                data: preparedData.data,
                measureSemantics: preparedData.measureSemantics))
    }
}
