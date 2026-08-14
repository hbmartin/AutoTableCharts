import Foundation

public struct AutoChartColumnID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct AutoChartRowID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public enum AutoChartValue: Hashable, Codable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case decimal(Decimal)
    case text(String)
    case date(Date)
    case binary(Data)

    public var numericValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .double(let value): value.isFinite ? value : nil
        case .decimal(let value): NSDecimalNumber(decimal: value).doubleValue
        default: nil
        }
    }

    public var displayString: String {
        switch self {
        case .null: "—"
        case .boolean(let value): value ? "Yes" : "No"
        case .integer(let value): value.formatted(.number.grouping(.automatic))
        case .double(let value): value.formatted(.number.precision(.fractionLength(0...3)))
        case .decimal(let value): NSDecimalNumber(decimal: value).stringValue
        case .text(let value): value
        case .date(let value): value.formatted(date: .abbreviated, time: .omitted)
        case .binary: "<binary>"
        }
    }
}

public enum AutoChartSemanticType: String, CaseIterable, Codable, Sendable {
    case quantitative
    case temporal
    case nominal
    case ordinal
    case identifier
    case boolean
    case unsupported
}

public enum AutoChartAnalyticRole: String, CaseIterable, Codable, Sendable {
    case dimension
    case measure
    case identifier
    case label
    case series
    case intervalStart
    case intervalEnd
}

public enum AutoChartUnit: Hashable, Codable, Sendable {
    case number
    case currency(code: String)
    /// `fractional` means values are stored from zero through one.
    case percent(fractional: Bool)
    case duration(unit: String)
    case area(unit: String)
    case custom(String)
}

public enum AutoChartAggregation: String, CaseIterable, Codable, Sendable {
    case none
    case sum
    case mean
    case minimum
    case maximum
    case count
    case countDistinct
}

public enum AutoChartAggregationSafety: String, Codable, Sendable {
    case unknown
    case rowLevel
    case safe
    case alreadyAggregated
    case unsafe
}

public struct AutoChartColumnHints: Hashable, Codable, Sendable {
    public var semanticType: AutoChartSemanticType?
    public var role: AutoChartAnalyticRole?
    public var unit: AutoChartUnit?
    public var aggregation: AutoChartAggregation?
    public var aggregationSafety: AutoChartAggregationSafety
    public var grain: String?

    public init(
        semanticType: AutoChartSemanticType? = nil,
        role: AutoChartAnalyticRole? = nil,
        unit: AutoChartUnit? = nil,
        aggregation: AutoChartAggregation? = nil,
        aggregationSafety: AutoChartAggregationSafety = .unknown,
        grain: String? = nil
    ) {
        self.semanticType = semanticType
        self.role = role
        self.unit = unit
        self.aggregation = aggregation
        self.aggregationSafety = aggregationSafety
        self.grain = grain
    }
}

public struct AutoChartColumn: Identifiable, Hashable, Codable, Sendable {
    public var id: AutoChartColumnID
    public var name: String
    public var hints: AutoChartColumnHints

    public init(
        id: AutoChartColumnID,
        name: String,
        hints: AutoChartColumnHints = AutoChartColumnHints()
    ) {
        self.id = id
        self.name = name
        self.hints = hints
    }
}

public struct AutoChartTableMetadata: Hashable, Codable, Sendable {
    public var isTruncated: Bool
    public var grain: String?
    public var provenance: String?

    public init(
        isTruncated: Bool = false,
        grain: String? = nil,
        provenance: String? = nil
    ) {
        self.isTruncated = isTruncated
        self.grain = grain
        self.provenance = provenance
    }
}

public protocol AutoChartRow: Sendable {
    var chartRowID: AutoChartRowID { get }
    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue
}

public protocol AutoChartTable: Sendable {
    associatedtype ChartRows: RandomAccessCollection & Sendable
        where ChartRows.Element: AutoChartRow

    var chartColumns: [AutoChartColumn] { get }
    var chartRows: ChartRows { get }
    var chartMetadata: AutoChartTableMetadata { get }
}

public enum AutoChartGoal: String, CaseIterable, Codable, Sendable {
    case overview
    case comparison
    case ranking
    case trend
    case distribution
    case relationship
    case composition
    case range
    case outlier
}

public struct AutoChartContext: Hashable, Codable, Sendable {
    public var goal: AutoChartGoal
    public var title: String?

    public init(goal: AutoChartGoal = .overview, title: String? = nil) {
        self.goal = goal
        self.title = title
    }
}

public struct AutoChartOptions: Hashable, Codable, Sendable {
    public var maximumRecommendations: Int
    public var maximumCategories: Int
    public var maximumDonutSectors: Int
    public var maximumSeries: Int
    public var maximumFacets: Int

    public init(
        maximumRecommendations: Int = 5,
        maximumCategories: Int = 20,
        maximumDonutSectors: Int = 6,
        maximumSeries: Int = 6,
        maximumFacets: Int = 6
    ) {
        self.maximumRecommendations = max(1, maximumRecommendations)
        self.maximumCategories = max(2, maximumCategories)
        self.maximumDonutSectors = max(2, maximumDonutSectors)
        self.maximumSeries = max(2, maximumSeries)
        self.maximumFacets = max(2, maximumFacets)
    }
}

public enum AutoChartFamily: String, CaseIterable, Codable, Sendable {
    case table
    case kpi
    case bar
    case rankedDot
    case groupedBar
    case stackedBar
    case normalizedBar
    case line
    case pointLine
    case area
    case scatter
    case bubble
    case histogram
    case boxPlot
    case heatmap
    case donut
    case range
    case faceted

    public var displayName: String {
        switch self {
        case .table: "Table"
        case .kpi: "Key value"
        case .bar: "Bar"
        case .rankedDot: "Ranked dot"
        case .groupedBar: "Grouped bar"
        case .stackedBar: "Stacked bar"
        case .normalizedBar: "100% stacked bar"
        case .line: "Line"
        case .pointLine: "Line with points"
        case .area: "Area"
        case .scatter: "Scatter"
        case .bubble: "Bubble"
        case .histogram: "Histogram"
        case .boxPlot: "Box plot"
        case .heatmap: "Heatmap"
        case .donut: "Donut"
        case .range: "Range"
        case .faceted: "Small multiples"
        }
    }
}

public enum AutoChartOrientation: String, Codable, Sendable {
    case vertical
    case horizontal
}

public enum AutoChartStacking: String, Codable, Sendable {
    case none
    case standard
    case normalized
}

public enum AutoChartSort: String, Codable, Sendable {
    case source
    case ascending
    case descending
}

public struct AutoChartEncoding: Hashable, Codable, Sendable {
    public var x: AutoChartColumnID?
    public var y: AutoChartColumnID?
    public var series: AutoChartColumnID?
    public var size: AutoChartColumnID?
    public var facet: AutoChartColumnID?
    public var start: AutoChartColumnID?
    public var end: AutoChartColumnID?

    public init(
        x: AutoChartColumnID? = nil,
        y: AutoChartColumnID? = nil,
        series: AutoChartColumnID? = nil,
        size: AutoChartColumnID? = nil,
        facet: AutoChartColumnID? = nil,
        start: AutoChartColumnID? = nil,
        end: AutoChartColumnID? = nil
    ) {
        self.x = x
        self.y = y
        self.series = series
        self.size = size
        self.facet = facet
        self.start = start
        self.end = end
    }
}

public struct AutoChartSpecification: Identifiable, Hashable, Codable, Sendable {
    public var family: AutoChartFamily
    public var encoding: AutoChartEncoding
    public var aggregation: AutoChartAggregation
    public var binCount: Int?
    public var orientation: AutoChartOrientation
    public var stacking: AutoChartStacking
    public var sort: AutoChartSort
    public var title: String

    public init(
        family: AutoChartFamily,
        encoding: AutoChartEncoding = AutoChartEncoding(),
        aggregation: AutoChartAggregation = .none,
        binCount: Int? = nil,
        orientation: AutoChartOrientation = .vertical,
        stacking: AutoChartStacking = .none,
        sort: AutoChartSort = .source,
        title: String = ""
    ) {
        self.family = family
        self.encoding = encoding
        self.aggregation = aggregation
        self.binCount = binCount
        self.orientation = orientation
        self.stacking = stacking
        self.sort = sort
        self.title = title
    }

    public var id: String {
        var components: [String] = []
        components.append(String(AutoTableCharts.recommendationPolicyVersion))
        components.append(family.rawValue)
        components.append(encoding.x?.rawValue ?? "")
        components.append(encoding.y?.rawValue ?? "")
        components.append(encoding.series?.rawValue ?? "")
        components.append(encoding.size?.rawValue ?? "")
        components.append(encoding.facet?.rawValue ?? "")
        components.append(encoding.start?.rawValue ?? "")
        components.append(encoding.end?.rawValue ?? "")
        components.append(aggregation.rawValue)
        components.append(String(binCount ?? 0))
        components.append(orientation.rawValue)
        components.append(stacking.rawValue)
        components.append(sort.rawValue)
        return components.joined(separator: "|")
    }
}

public struct AutoChartRecommendation: Identifiable, Hashable, Codable, Sendable {
    public var specification: AutoChartSpecification
    public var score: Double
    public var rationale: [String]
    public var warnings: [String]

    public init(
        specification: AutoChartSpecification,
        score: Double,
        rationale: [String],
        warnings: [String] = []
    ) {
        self.specification = specification
        self.score = score
        self.rationale = rationale
        self.warnings = warnings
    }

    public var id: String { specification.id }
}

public struct AutoChartRecommendationSet: Hashable, Codable, Sendable {
    public var recommendations: [AutoChartRecommendation]
    public var fallbackReason: String?

    public init(
        recommendations: [AutoChartRecommendation],
        fallbackReason: String? = nil
    ) {
        self.recommendations = recommendations
        self.fallbackReason = fallbackReason
    }

    public var chartRecommendations: [AutoChartRecommendation] {
        recommendations.filter { $0.specification.family != .table }
    }
}

public struct AutoChartSelection: Hashable, Codable, Sendable {
    public var sourceRowIDs: Set<AutoChartRowID>
    public var label: String
    public var valueDescription: String

    public init(
        sourceRowIDs: Set<AutoChartRowID>,
        label: String,
        valueDescription: String
    ) {
        self.sourceRowIDs = sourceRowIDs
        self.label = label
        self.valueDescription = valueDescription
    }
}

public enum AutoChartValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct AutoChartValidationIssue: Hashable, Codable, Sendable {
    public var severity: AutoChartValidationSeverity
    public var message: String

    public init(severity: AutoChartValidationSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct AutoChartValidationResult: Hashable, Codable, Sendable {
    public var issues: [AutoChartValidationIssue]
    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    public init(issues: [AutoChartValidationIssue] = []) {
        self.issues = issues
    }
}

public enum AutoChartInteraction: String, Codable, Sendable {
    case preview
    case explore
}
