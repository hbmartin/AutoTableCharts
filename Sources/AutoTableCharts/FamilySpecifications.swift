import Foundation

/// Family-specific chart declarations whose associated values expose only
/// channels and options meaningful to that family.
public enum AutoChartFamilySpecification: Hashable, Codable, Sendable {
    case kpi(measure: AutoChartColumnID, title: String)
    case bar(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        aggregation: AutoChartAggregation, orientation: AutoChartOrientation,
        sort: AutoChartSort, title: String)
    case rankedDot(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        aggregation: AutoChartAggregation, sort: AutoChartSort, title: String)
    case groupedBar(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID, aggregation: AutoChartAggregation,
        orientation: AutoChartOrientation, title: String)
    case stackedBar(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID, aggregation: AutoChartAggregation,
        orientation: AutoChartOrientation, title: String)
    case normalizedBar(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID, aggregation: AutoChartAggregation,
        orientation: AutoChartOrientation, title: String)
    case line(
        x: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID?, aggregation: AutoChartAggregation, title: String)
    case pointLine(
        x: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID?, aggregation: AutoChartAggregation, title: String)
    case area(
        x: AutoChartColumnID, measure: AutoChartColumnID,
        series: AutoChartColumnID?, aggregation: AutoChartAggregation, title: String)
    case scatter(
        x: AutoChartColumnID, y: AutoChartColumnID,
        series: AutoChartColumnID?, title: String)
    case bubble(
        x: AutoChartColumnID, y: AutoChartColumnID, size: AutoChartColumnID,
        series: AutoChartColumnID?, title: String)
    case histogram(value: AutoChartColumnID, binCount: Int?, title: String)
    case boxPlot(measure: AutoChartColumnID, category: AutoChartColumnID?, title: String)
    case heatmap(x: AutoChartColumnID, y: AutoChartColumnID, title: String)
    case donut(
        category: AutoChartColumnID, measure: AutoChartColumnID,
        aggregation: AutoChartAggregation, title: String)
    case range(
        label: AutoChartColumnID, start: AutoChartColumnID,
        end: AutoChartColumnID?, series: AutoChartColumnID?, title: String)
    case faceted(
        baseFamily: AutoChartFamily, x: AutoChartColumnID, y: AutoChartColumnID,
        facet: AutoChartColumnID, series: AutoChartColumnID?,
        aggregation: AutoChartAggregation, orientation: AutoChartOrientation,
        title: String)

    var raw: AutoChartUnsafeRawSpecification {
        switch self {
        case .kpi(let measure, let title):
            .init(family: .kpi, encoding: .init(y: measure), title: title)
        case .bar(let category, let measure, let aggregation, let orientation, let sort, let title):
            .init(
                family: .bar,
                encoding: .init(x: category, y: measure),
                aggregation: aggregation,
                orientation: orientation,
                sort: sort,
                title: title)
        case .rankedDot(let category, let measure, let aggregation, let sort, let title):
            .init(
                family: .rankedDot,
                encoding: .init(x: category, y: measure),
                aggregation: aggregation,
                orientation: .horizontal,
                sort: sort,
                title: title)
        case .groupedBar(
            let category, let measure, let series, let aggregation, let orientation, let title):
            .init(
                family: .groupedBar,
                encoding: .init(x: category, y: measure, series: series),
                aggregation: aggregation,
                orientation: orientation,
                title: title)
        case .stackedBar(
            let category, let measure, let series, let aggregation, let orientation, let title):
            .init(
                family: .stackedBar,
                encoding: .init(x: category, y: measure, series: series),
                aggregation: aggregation,
                orientation: orientation,
                stacking: .standard,
                title: title)
        case .normalizedBar(
            let category, let measure, let series, let aggregation, let orientation, let title):
            .init(
                family: .normalizedBar,
                encoding: .init(x: category, y: measure, series: series),
                aggregation: aggregation,
                orientation: orientation,
                stacking: .normalized,
                title: title)
        case .line(let x, let measure, let series, let aggregation, let title):
            .init(
                family: .line,
                encoding: .init(x: x, y: measure, series: series),
                aggregation: aggregation,
                title: title)
        case .pointLine(let x, let measure, let series, let aggregation, let title):
            .init(
                family: .pointLine,
                encoding: .init(x: x, y: measure, series: series),
                aggregation: aggregation,
                title: title)
        case .area(let x, let measure, let series, let aggregation, let title):
            .init(
                family: .area,
                encoding: .init(x: x, y: measure, series: series),
                aggregation: aggregation,
                title: title)
        case .scatter(let x, let y, let series, let title):
            .init(family: .scatter, encoding: .init(x: x, y: y, series: series), title: title)
        case .bubble(let x, let y, let size, let series, let title):
            .init(
                family: .bubble,
                encoding: .init(x: x, y: y, series: series, size: size),
                title: title)
        case .histogram(let value, let binCount, let title):
            .init(
                family: .histogram,
                encoding: .init(x: value),
                aggregation: .count,
                binCount: binCount,
                title: title)
        case .boxPlot(let measure, let category, let title):
            .init(family: .boxPlot, encoding: .init(x: category, y: measure), title: title)
        case .heatmap(let x, let y, let title):
            .init(
                family: .heatmap,
                encoding: .init(x: x, y: y),
                aggregation: .count,
                title: title)
        case .donut(let category, let measure, let aggregation, let title):
            .init(
                family: .donut,
                encoding: .init(x: category, y: measure),
                aggregation: aggregation,
                title: title)
        case .range(let label, let start, let end, let series, let title):
            .init(
                family: .range,
                encoding: .init(x: label, series: series, start: start, end: end),
                orientation: .horizontal,
                title: title)
        case .faceted(
            let baseFamily, let x, let y, let facet, let series,
            let aggregation, let orientation, let title):
            .init(
                family: .faceted,
                encoding: .init(x: x, y: y, series: series, facet: facet),
                aggregation: aggregation,
                orientation: orientation,
                facetBaseFamily: baseFamily,
                title: title)
        }
    }
}

/// Explicitly unsafe representation for imported or dynamically authored charts.
/// Analysis validation always runs before this representation can be prepared.
public struct AutoChartUnsafeRawSpecification: Hashable, Codable, Sendable {
    public var family: AutoChartFamily
    public var encoding: AutoChartEncoding
    public var aggregation: AutoChartAggregation
    public var binCount: Int?
    public var orientation: AutoChartOrientation
    public var stacking: AutoChartStacking
    public var facetBaseFamily: AutoChartFamily?
    public var sort: AutoChartSort
    public var title: String

    public init(
        family: AutoChartFamily,
        encoding: AutoChartEncoding = .init(),
        aggregation: AutoChartAggregation = .none,
        binCount: Int? = nil,
        orientation: AutoChartOrientation = .vertical,
        stacking: AutoChartStacking = .none,
        facetBaseFamily: AutoChartFamily? = nil,
        sort: AutoChartSort = .source,
        title: String = ""
    ) {
        self.family = family
        self.encoding = encoding
        self.aggregation = aggregation
        self.binCount = binCount
        self.orientation = orientation
        self.stacking = stacking
        self.facetBaseFamily = facetBaseFamily
        self.sort = sort
        self.title = title
    }
}

extension AutoChartSpecification {
    public init(_ familySpecification: AutoChartFamilySpecification) {
        self.init(unsafeRawRepresentation: familySpecification.raw)
    }

    public init(unsafeRawRepresentation raw: AutoChartUnsafeRawSpecification) {
        self.init(
            family: raw.family,
            encoding: raw.encoding,
            aggregation: raw.aggregation,
            binCount: raw.binCount,
            orientation: raw.orientation,
            stacking: raw.stacking,
            facetBaseFamily: raw.facetBaseFamily,
            sort: raw.sort,
            title: raw.title)
    }

    public var unsafeRawRepresentation: AutoChartUnsafeRawSpecification {
        .init(
            family: family,
            encoding: encoding,
            aggregation: aggregation,
            binCount: binCount,
            orientation: orientation,
            stacking: stacking,
            facetBaseFamily: facetBaseFamily,
            sort: sort,
            title: title)
    }
}

extension AutoChartAnalysis {
    public func validation(
        for unsafeRawRepresentation: AutoChartUnsafeRawSpecification
    ) async throws -> AutoChartValidationResult {
        try await validation(
            for: AutoChartSpecification(unsafeRawRepresentation: unsafeRawRepresentation))
    }

    public func prepare(
        _ unsafeRawRepresentation: AutoChartUnsafeRawSpecification
    ) async throws -> AutoChartPreparedChart<RowID> {
        try await prepare(
            AutoChartSpecification(unsafeRawRepresentation: unsafeRawRepresentation))
    }
}
