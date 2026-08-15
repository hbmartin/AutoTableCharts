import Foundation

/// A stable identifier for a column exposed through ``AutoChartTable``.
///
/// Identifiers, rather than display names, connect column metadata to values
/// and chart encodings. Keep an identifier stable while its display name changes.
public struct AutoChartColumnID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    /// The caller-defined identifier value.
    public var rawValue: String

    /// Creates an identifier from its stored representation.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates an identifier from a string literal.
    public init(stringLiteral value: String) { self.rawValue = value }
    /// The unmodified identifier value.
    public var description: String { rawValue }
}

/// A stable identifier for a source row.
///
/// The renderer preserves these identifiers through grouping and binning so a
/// selection can identify every contributing source row.
public struct AutoChartRowID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    /// The caller-defined identifier value.
    public var rawValue: String

    /// Creates an identifier from its stored representation.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates an identifier from a string literal.
    public init(stringLiteral value: String) { self.rawValue = value }
    /// The unmodified identifier value.
    public var description: String { rawValue }
}

/// A typed cell value supplied by an ``AutoChartRow``.
///
/// Preserve the source value's real type whenever possible. Type information
/// is used for semantic inference, validation, aggregation, and rendering.
public enum AutoChartValue: Hashable, Codable, Sendable {
    /// A missing value, which is excluded from chart marks rather than treated as zero.
    case null
    /// A Boolean value that can be used as a categorical dimension.
    case boolean(Bool)
    /// A signed integer value that can participate in quantitative encodings.
    case integer(Int64)
    /// A finite floating-point value.
    case double(Double)
    /// A base-10 decimal value, useful when the source requires decimal semantics.
    case decimal(Decimal)
    /// A textual value, which may also be recognized as an ISO-formatted date.
    case text(String)
    /// A date value used by temporal encodings.
    case date(Date)
    /// An opaque value that is deliberately unsupported as a chart encoding.
    case binary(Data)

    /// A finite `Double` representation for quantitative values, or `nil` otherwise.
    ///
    /// Non-finite floating-point and decimal values return `nil` and aren't rendered.
    public var numericValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .double(let value): return value.isFinite ? value : nil
        case .decimal(let value):
            let result = NSDecimalNumber(decimal: value).doubleValue
            return result.isFinite ? result : nil
        default: return nil
        }
    }

    /// A concise, locale-aware representation suitable for labels and selections.
    public var displayString: String {
        switch self {
        case .null: "—"
        case .boolean(let value): value ? "Yes" : "No"
        case .integer(let value): value.formatted(.number.grouping(.automatic))
        case .double(let value):
            value.formatted(
                .number.grouping(.automatic).precision(.fractionLength(0...3)))
        case .decimal(let value):
            value.formatted(
                .number.grouping(.automatic).precision(.fractionLength(0...3)))
        case .text(let value): value
        case .date(let value):
            value.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: .omitted,
                    timeZone: TimeZone.gmt))
        case .binary: "<binary>"
        }
    }
}

/// The semantic interpretation of a column after hints and inference are applied.
public enum AutoChartSemanticType: String, CaseIterable, Codable, Sendable {
    /// Numeric magnitudes for measures, positions, sizes, or distributions.
    case quantitative
    /// Ordered points or intervals in time.
    case temporal
    /// Unordered categories.
    case nominal
    /// Categories whose order is meaningful.
    case ordinal
    /// Keys used for identity rather than measurement.
    case identifier
    /// A two-valued categorical field.
    case boolean
    /// Values that can't be represented safely by the supported chart families.
    case unsupported
}

/// The analytical purpose a column serves in a result.
public enum AutoChartAnalyticRole: String, CaseIterable, Codable, Sendable {
    /// A field used to partition or group observations.
    case dimension
    /// A field whose magnitude is measured or summarized.
    case measure
    /// A key that identifies an entity or record and must not be treated as a measure.
    case identifier
    /// Human-readable text used to identify a mark or interval.
    case label
    /// A low-cardinality dimension intended to distinguish multiple series.
    case series
    /// The beginning of a temporal interval.
    case intervalStart
    /// The end of a temporal interval.
    case intervalEnd
}

/// Unit metadata used to format and reason about quantitative values.
public enum AutoChartUnit: Hashable, Codable, Sendable {
    /// A unitless number.
    case number
    /// An amount in an ISO-style currency code, such as `USD`.
    case currency(code: String)
    /// `fractional` means values are stored from zero through one.
    case percent(fractional: Bool)
    /// A duration expressed in a caller-defined unit.
    case duration(unit: String)
    /// An area expressed in a caller-defined unit.
    case area(unit: String)
    /// A domain-specific unit label.
    case custom(String)
}

/// A transformation that combines values represented by one chart mark.
public enum AutoChartAggregation: String, CaseIterable, Codable, Sendable {
    /// Preserve one mark per result-grain observation.
    case none
    /// Add contributing values.
    case sum
    /// Compute the arithmetic mean of contributing values.
    case mean
    /// Select the smallest contributing value.
    case minimum
    /// Select the largest contributing value.
    case maximum
    /// Count contributing rows.
    case count
    /// Count distinct contributing values.
    case countDistinct
}

/// Declares whether a measure may be aggregated without changing its meaning.
///
/// Recommendation safety is conservative: unknown or unsafe aggregation blocks
/// implicit rollups, and already-aggregated measures are additive only for
/// upstream sums and ordinary counts. Both roll up by summing their values.
public enum AutoChartAggregationSafety: String, Codable, Sendable {
    /// The caller hasn't established whether aggregation is semantically valid.
    case unknown
    /// Values occur at the table's row grain but aren't explicitly declared additive.
    case rowLevel
    /// Values may use the declared aggregation, or sum when none is declared.
    case safe
    /// Values were aggregated upstream; only sums and ordinary counts may be summed again.
    case alreadyAggregated
    /// Values must never be aggregated automatically.
    case unsafe
}

/// Caller-supplied semantic metadata for a column.
///
/// Explicit hints take precedence over value-based inference. Supplying roles,
/// units, aggregation safety, and grain is the best way to prevent a plausible
/// chart from misrepresenting a result.
public struct AutoChartColumnHints: Hashable, Codable, Sendable {
    /// An explicit semantic type, or `nil` to infer it from values and the column name.
    public var semanticType: AutoChartSemanticType?
    /// The column's intended analytical role.
    public var role: AutoChartAnalyticRole?
    /// Unit metadata used for formatting and semantic context.
    public var unit: AutoChartUnit?
    /// The aggregation already applied upstream or preferred by the caller.
    public var aggregation: AutoChartAggregation?
    /// Whether further aggregation is safe.
    public var aggregationSafety: AutoChartAggregationSafety
    /// A caller-defined description of the entity or grouping level represented.
    public var grain: String?

    /// Creates semantic hints for a column.
    ///
    /// - Parameters:
    ///   - semanticType: An explicit type, or `nil` to use inference.
    ///   - role: The column's analytical role.
    ///   - unit: Formatting and domain unit metadata.
    ///   - aggregation: An upstream or preferred aggregation.
    ///   - aggregationSafety: Whether the engine may roll values up. Defaults to
    ///     the conservative ``AutoChartAggregationSafety/unknown`` state.
    ///   - grain: A human-readable description of the value grain.
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

/// The identity, display name, and semantic hints for a table column.
public struct AutoChartColumn: Identifiable, Hashable, Codable, Sendable {
    /// The stable identifier used by row lookups and chart encodings.
    public var id: AutoChartColumnID
    /// A human-readable source name used to generate titles and labels.
    public var name: String
    /// An optional presentation label used verbatim in generated titles and axes.
    public var displayName: String?
    /// Semantic metadata that overrides or supplements profiling.
    public var hints: AutoChartColumnHints

    /// Creates a column description.
    ///
    /// - Parameters:
    ///   - id: The stable column identifier.
    ///   - name: A source or display name.
    ///   - displayName: An optional caller-authored presentation label.
    ///   - hints: Optional semantic metadata.
    public init(
        id: AutoChartColumnID,
        name: String,
        displayName: String? = nil,
        hints: AutoChartColumnHints = AutoChartColumnHints()
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.hints = hints
    }
}

/// Result-level metadata that affects recommendation safety and explanation.
public struct AutoChartTableMetadata: Hashable, Codable, Sendable {
    /// Whether the supplied rows are only an incomplete prefix or subset of the result.
    ///
    /// Truncated results suppress totals, composition, frequency heatmaps, and
    /// other chart families that require a complete population.
    public var isTruncated: Bool
    /// A caller-defined description of the entity or grouping level of each row.
    public var grain: String?
    /// A caller-defined description of the result's source or transformation history.
    public var provenance: String?

    /// Creates metadata for a chartable table.
    ///
    /// - Parameters:
    ///   - isTruncated: Whether the supplied rows are incomplete.
    ///   - grain: The result's row-level grain.
    ///   - provenance: A description of the result's source or lineage.
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

/// A source row that provides stable identity and typed values by column.
public protocol AutoChartRow: Sendable {
    /// A stable identifier preserved by selections, grouping, and binning.
    var chartRowID: AutoChartRowID { get }
    /// Returns the typed value associated with a column.
    ///
    /// Return ``AutoChartValue/null`` when the row has no value for the column.
    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue
}

/// A typed, random-access table that can be profiled and visualized.
///
/// The engine copies the declared columns and supplied rows into an immutable
/// snapshot. It never samples, reorders, or mutates consumer-owned storage.
public protocol AutoChartTable: Sendable {
    /// The random-access collection that stores this table's rows.
    associatedtype ChartRows: RandomAccessCollection & Sendable
    where ChartRows.Element: AutoChartRow

    /// Column descriptions in source order.
    var chartColumns: [AutoChartColumn] { get }
    /// The complete collection of rows supplied for this recommendation request.
    var chartRows: ChartRows { get }
    /// Result-level completeness, grain, and provenance metadata.
    var chartMetadata: AutoChartTableMetadata { get }
    /// A caller-managed identifier for the exact table contents, used to reuse
    /// prepared rendering data across SwiftUI view reconstruction.
    ///
    /// Change this value whenever columns, rows, values, or metadata change. The
    /// default is `nil`, which keeps content-derived invalidation behavior.
    var chartDataVersion: String? { get }
}

extension AutoChartTable {
    public var chartDataVersion: String? { nil }
}

/// The analytical task used to favor otherwise valid recommendations.
///
/// A goal adjusts ranking but never overrides semantic or aggregation safety.
public enum AutoChartGoal: String, CaseIterable, Codable, Sendable {
    /// Provide a general-purpose overview of the available fields.
    case overview
    /// Compare magnitudes across observations or categories.
    case comparison
    /// Order observations by magnitude.
    case ranking
    /// Examine change over ordered time.
    case trend
    /// Examine spread, shape, or frequency of quantitative values.
    case distribution
    /// Examine association between two fields.
    case relationship
    /// Examine contributions to a complete, additive whole.
    case composition
    /// Examine temporal starts, ends, or events.
    case range
    /// Examine extreme observations or distribution tails.
    case outlier
}

/// Request-level intent and presentation context for recommendation.
public struct AutoChartContext: Hashable, Codable, Sendable {
    /// The analytical task used by ranking.
    public var goal: AutoChartGoal
    /// An optional title applied to every generated specification.
    public var title: String?

    /// Creates a recommendation context.
    ///
    /// - Parameters:
    ///   - goal: The analytical task to favor.
    ///   - title: An optional caller-supplied chart title.
    public init(goal: AutoChartGoal = .overview, title: String? = nil) {
        self.goal = goal
        self.title = title
    }
}

/// Limits candidate output and visual density.
///
/// Initializer inputs are clamped to safe minimums: at least one
/// recommendation and at least two categories, sectors, series, facets, or
/// candidate columns per semantic type.
public struct AutoChartOptions: Hashable, Codable, Sendable {
    /// The maximum number of diverse recommendations returned. Defaults to five.
    public var maximumRecommendations: Int {
        didSet { maximumRecommendations = max(1, maximumRecommendations) }
    }
    /// The maximum categorical cardinality for ordinary category axes. Defaults to twenty.
    public var maximumCategories: Int {
        didSet { maximumCategories = max(2, maximumCategories) }
    }
    /// The maximum number of sectors permitted in a donut chart. Defaults to six.
    public var maximumDonutSectors: Int {
        didSet { maximumDonutSectors = max(2, maximumDonutSectors) }
    }
    /// The maximum number of series permitted in a multi-series chart. Defaults to six.
    public var maximumSeries: Int {
        didSet { maximumSeries = max(2, maximumSeries) }
    }
    /// The maximum number of panels permitted in a faceted chart. Defaults to six.
    public var maximumFacets: Int {
        didSet { maximumFacets = max(2, maximumFacets) }
    }
    /// The maximum columns of each semantic type considered during candidate generation.
    /// Defaults to twenty-four. Profiling and caller-specification validation still cover
    /// every declared column.
    public var maximumCandidateColumns: Int {
        didSet { maximumCandidateColumns = max(2, maximumCandidateColumns) }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRecommendations
        case maximumCategories
        case maximumDonutSectors
        case maximumSeries
        case maximumFacets
        case maximumCandidateColumns
    }

    /// Creates recommendation and density limits.
    ///
    /// - Parameters:
    ///   - maximumRecommendations: Maximum returned alternatives.
    ///   - maximumCategories: Maximum category-axis cardinality.
    ///   - maximumDonutSectors: Maximum donut cardinality.
    ///   - maximumSeries: Maximum series cardinality.
    ///   - maximumFacets: Maximum facet cardinality.
    ///   - maximumCandidateColumns: Maximum candidate columns per semantic type.
    public init(
        maximumRecommendations: Int = 5,
        maximumCategories: Int = 20,
        maximumDonutSectors: Int = 6,
        maximumSeries: Int = 6,
        maximumFacets: Int = 6,
        maximumCandidateColumns: Int = 24
    ) {
        self.maximumRecommendations = max(1, maximumRecommendations)
        self.maximumCategories = max(2, maximumCategories)
        self.maximumDonutSectors = max(2, maximumDonutSectors)
        self.maximumSeries = max(2, maximumSeries)
        self.maximumFacets = max(2, maximumFacets)
        self.maximumCandidateColumns = max(2, maximumCandidateColumns)
    }

    /// Decodes recommendation limits and applies the same safe minimums as the initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumRecommendations: try container.decode(
                Int.self, forKey: .maximumRecommendations),
            maximumCategories: try container.decode(Int.self, forKey: .maximumCategories),
            maximumDonutSectors: try container.decode(
                Int.self, forKey: .maximumDonutSectors),
            maximumSeries: try container.decode(Int.self, forKey: .maximumSeries),
            maximumFacets: try container.decode(Int.self, forKey: .maximumFacets),
            maximumCandidateColumns: try container.decodeIfPresent(
                Int.self, forKey: .maximumCandidateColumns) ?? 24)
    }
}

/// A visualization family supported by recommendation, validation, and rendering.
public enum AutoChartFamily: String, CaseIterable, Codable, Sendable {
    /// A tabular fallback when no safe chart is available.
    case table
    /// A single quantitative key value from a complete one-row result.
    case kpi
    /// Length-encoded categorical comparison.
    case bar
    /// Position-encoded categorical ranking on a common scale.
    case rankedDot
    /// Side-by-side categorical series.
    case groupedBar
    /// Additive contributions stacked within categories.
    case stackedBar
    /// Proportional contributions normalized within categories.
    case normalizedBar
    /// A connected temporal or ordinal trend.
    case line
    /// A connected trend with explicit observation points.
    case pointLine
    /// A nonnegative temporal trend filled to its baseline.
    case area
    /// A relationship between two quantitative or temporal/quantitative fields.
    case scatter
    /// A scatter-style relationship with a third nonnegative size encoding.
    case bubble
    /// Binned frequencies for one quantitative field.
    case histogram
    /// Quartiles and extrema for one quantitative field, optionally by category.
    case boxPlot
    /// Counts for combinations of two categorical fields.
    case heatmap
    /// Positive additive contributions to a complete whole.
    case donut
    /// Temporal intervals or discrete events aligned by a categorical label.
    case range
    /// Repeated low-cardinality panels that separate a base chart by category.
    case faceted

    /// A concise localized-ready family label used by fallback UI and accessibility.
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

/// The direction in which a chart's primary categorical or interval axis is laid out.
public enum AutoChartOrientation: String, Codable, Sendable {
    /// Categories progress along the horizontal axis and values along the vertical axis.
    case vertical
    /// Categories progress along the vertical axis and values along the horizontal axis.
    case horizontal
}

/// The method used to combine series sharing a category.
public enum AutoChartStacking: String, Codable, Sendable {
    /// Draw series without stacking.
    case none
    /// Stack raw additive values.
    case standard
    /// Normalize each stack to compare proportions.
    case normalized
}

/// The order applied to prepared chart marks.
public enum AutoChartSort: String, Codable, Sendable {
    /// Preserve the order in which data or grouped marks are prepared.
    case source
    /// Sort by increasing quantitative value with labels as a stable tie-breaker.
    case ascending
    /// Sort by decreasing quantitative value with labels as a stable tie-breaker.
    case descending
}

/// Column-to-channel assignments used by a chart specification.
///
/// Required channels depend on ``AutoChartFamily`` and are checked by
/// ``AutoChartEngine/validate(specification:for:)``.
public struct AutoChartEncoding: Hashable, Codable, Sendable {
    /// The primary horizontal, categorical, temporal, or quantitative field.
    public var x: AutoChartColumnID?
    /// The primary vertical measure or second categorical field.
    public var y: AutoChartColumnID?
    /// A categorical field that separates marks into series.
    public var series: AutoChartColumnID?
    /// A nonnegative quantitative field that controls bubble size.
    public var size: AutoChartColumnID?
    /// A low-cardinality categorical field that creates panels.
    public var facet: AutoChartColumnID?
    /// The temporal start of a range mark.
    public var start: AutoChartColumnID?
    /// The temporal end of a range mark.
    public var end: AutoChartColumnID?

    /// Creates a set of channel assignments.
    ///
    /// - Parameters:
    ///   - x: The primary x or category field.
    ///   - y: The primary y or measure field.
    ///   - series: A categorical series field.
    ///   - size: A quantitative size field.
    ///   - facet: A categorical facet field.
    ///   - start: A temporal interval start.
    ///   - end: A temporal interval end.
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

/// A declarative, renderer-independent description of one supported chart.
///
/// Validate caller-authored specifications before rendering. Engine-generated
/// specifications have already passed the same validation rules.
public struct AutoChartSpecification: Identifiable, Hashable, Codable, Sendable {
    /// The visual family and its required channel semantics.
    public var family: AutoChartFamily
    /// Column assignments for the family's visual channels.
    public var encoding: AutoChartEncoding
    /// The transformation applied when multiple source rows contribute to a mark.
    public var aggregation: AutoChartAggregation
    /// The requested number of histogram bins, or `nil` for the renderer default.
    public var binCount: Int?
    /// The layout direction for families that support orientation.
    public var orientation: AutoChartOrientation
    /// The series-stacking behavior.
    public var stacking: AutoChartStacking
    /// The line, bar, or scatter family repeated by a faceted chart.
    ///
    /// Legacy decoded specifications may leave this `nil`; validation then reports
    /// a warning and the renderer infers a compatible family from the x-axis type.
    public var facetBaseFamily: AutoChartFamily?
    /// The order applied to prepared marks.
    public var sort: AutoChartSort
    /// The visible and accessible chart title.
    public var title: String

    /// Creates a chart specification.
    ///
    /// - Parameters:
    ///   - family: The chart family to render.
    ///   - encoding: Column-to-channel assignments.
    ///   - aggregation: A grouping transformation, if any.
    ///   - binCount: The number of histogram bins.
    ///   - orientation: The primary layout direction.
    ///   - stacking: The series-stacking behavior.
    ///   - facetBaseFamily: The base family repeated by a faceted chart.
    ///   - sort: The mark order.
    ///   - title: The visible and accessible title.
    public init(
        family: AutoChartFamily,
        encoding: AutoChartEncoding = AutoChartEncoding(),
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

    /// A deterministic identity derived from the recommendation policy and visual fields.
    ///
    /// The title is intentionally excluded. Use
    /// ``AutoTableCharts/recommendationPolicyVersion`` when deciding whether to
    /// invalidate persisted identifiers after a policy update.
    public var id: String {
        func optionalColumn(_ id: AutoChartColumnID?) -> String {
            id.map { "value:\($0.rawValue)" } ?? "nil"
        }
        func encode(_ component: String) -> String {
            "\(component.utf8.count):\(component)"
        }
        let components = [
            String(AutoTableCharts.recommendationPolicyVersion),
            family.rawValue,
            optionalColumn(encoding.x),
            optionalColumn(encoding.y),
            optionalColumn(encoding.series),
            optionalColumn(encoding.size),
            optionalColumn(encoding.facet),
            optionalColumn(encoding.start),
            optionalColumn(encoding.end),
            aggregation.rawValue,
            binCount.map { "value:\($0)" } ?? "nil",
            orientation.rawValue,
            stacking.rawValue,
            facetBaseFamily.map { "value:\($0.rawValue)" } ?? "nil",
            sort.rawValue,
        ]
        return components.map(encode).joined(separator: "|")
    }
}

/// A validated chart specification plus its rank, explanation, and cautions.
public struct AutoChartRecommendation: Identifiable, Hashable, Codable, Sendable {
    /// The specification that can be rendered by ``AutoChartView``.
    public var specification: AutoChartSpecification
    /// The policy score used to rank candidates within this recommendation request.
    ///
    /// Scores are useful for ordering but aren't probabilities and shouldn't be
    /// compared across policy versions.
    public var score: Double
    /// Human-readable reasons the candidate fits the data and task.
    public var rationale: [String]
    /// Human-readable limitations, including incomplete-result warnings.
    public var warnings: [String]

    /// Creates a recommendation record.
    ///
    /// - Parameters:
    ///   - specification: A chart specification.
    ///   - score: Its relative policy score.
    ///   - rationale: Reasons for the recommendation.
    ///   - warnings: Limitations the UI should present with the chart.
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

    /// The deterministic identifier of the enclosed specification.
    public var id: String { specification.id }
}

/// The bounded, diverse output of one recommendation request.
public struct AutoChartRecommendationSet: Hashable, Codable, Sendable {
    /// Recommendations in deterministic rank order, including a possible table fallback.
    public var recommendations: [AutoChartRecommendation]
    /// Why no safe chart was available, or `nil` when chart recommendations exist.
    public var fallbackReason: String?

    /// Creates a recommendation result.
    ///
    /// - Parameters:
    ///   - recommendations: Ranked chart or fallback recommendations.
    ///   - fallbackReason: The reason only a table can safely represent the data.
    public init(
        recommendations: [AutoChartRecommendation],
        fallbackReason: String? = nil
    ) {
        self.recommendations = recommendations
        self.fallbackReason = fallbackReason
    }

    /// Recommendations that render charts, excluding the table fallback family.
    public var chartRecommendations: [AutoChartRecommendation] {
        recommendations.filter { $0.specification.family != .table }
    }
}

/// The exact source rows represented by a selected mark or group of marks.
public struct AutoChartSelection: Hashable, Codable, Sendable {
    /// Every source-row identifier contributing to the selection.
    public var sourceRowIDs: Set<AutoChartRowID>
    /// A concise human-readable description of the selected category or mark.
    public var label: String
    /// A formatted value and contributing-row summary.
    public var valueDescription: String

    /// Creates linked-selection state.
    ///
    /// - Parameters:
    ///   - sourceRowIDs: Every contributing source row.
    ///   - label: A human-readable selection label.
    ///   - valueDescription: A formatted value and lineage summary.
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

/// The impact of a specification-validation issue.
public enum AutoChartValidationSeverity: String, Codable, Sendable {
    /// A non-fatal condition callers should present or review.
    case warning
    /// A condition that prevents semantically safe rendering.
    case error
}

/// A diagnostic emitted while validating a caller-provided specification.
public struct AutoChartValidationIssue: Hashable, Codable, Sendable {
    /// Whether the issue blocks rendering.
    public var severity: AutoChartValidationSeverity
    /// A human-readable explanation of the invalid or cautionary condition.
    public var message: String

    /// Creates a validation diagnostic.
    ///
    /// - Parameters:
    ///   - severity: Whether the issue is a warning or error.
    ///   - message: A human-readable explanation.
    public init(severity: AutoChartValidationSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// The complete diagnostics produced for a chart specification and table.
public struct AutoChartValidationResult: Hashable, Codable, Sendable {
    /// Validation diagnostics in discovery order.
    public var issues: [AutoChartValidationIssue]
    /// Whether the result contains no error-severity issues.
    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    /// Creates a validation result from diagnostics.
    public init(issues: [AutoChartValidationIssue] = []) {
        self.issues = issues
    }
}

/// The amount of interaction and supporting UI shown by ``AutoChartView``.
public enum AutoChartInteraction: String, Codable, Sendable {
    /// A compact, non-interactive presentation suitable for recommendation galleries.
    case preview
    /// An interactive presentation with selection, dense-axis navigation, and zoom reset.
    case explore
}
