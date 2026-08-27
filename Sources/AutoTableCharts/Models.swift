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

/// A caller-managed identity and revision for immutable chart data.
///
/// Keep `identity` stable for one logical result and change `revision` whenever
/// columns, values, row identifiers, hints, or metadata change. An analyzer can
/// use this contract to find prepared state without rescanning every cell.
public struct AutoChartDataKey: Hashable, Codable, Sendable {
    public var identity: String
    public var revision: String

    public init(identity: String, revision: String) {
        self.identity = identity
        self.revision = revision
    }
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
    /// A floating-point value. Non-finite values are retained as typed input but
    /// omitted from marks.
    case double(Double)
    /// A base-10 decimal value, useful when the source requires decimal semantics.
    case decimal(Decimal)
    /// A textual value, which may also be recognized as an ISO-formatted date.
    case text(String)
    /// A date value used by temporal encodings. Non-finite intervals are retained
    /// as typed input but omitted from marks.
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

    /// Shown wherever a value exists but cannot be rendered as itself: nulls
    /// and non-finite dates. A blank label would read as "nothing is here",
    /// which is exactly the wrong thing to say about a retained value.
    public static let unrepresentableValuePlaceholder = "—"

    /// A concise, locale-aware representation suitable for labels and selections.
    public var displayString: String {
        switch self {
        case .null: Self.unrepresentableValuePlaceholder
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
            value.timeIntervalSinceReferenceDate.isFinite
                ? value.formatted(
                    Date.FormatStyle(
                        date: .abbreviated,
                        time: .omitted,
                        timeZone: TimeZone.gmt))
                : Self.unrepresentableValuePlaceholder
        case .binary: "<binary>"
        }
    }
}

extension AutoChartValue {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return switch (lhs, rhs) {
        case (.null, .null): true
        case (.boolean(let lhs), .boolean(let rhs)): lhs == rhs
        case (.integer(let lhs), .integer(let rhs)): lhs == rhs
        case (.double(let lhs), .double(let rhs)):
            lhs == rhs || (lhs.isNaN && rhs.isNaN)
        case (.decimal(let lhs), .decimal(let rhs)):
            lhs == rhs || (lhs.isNaN && rhs.isNaN)
        case (.text(let lhs), .text(let rhs)): lhs == rhs
        case (.date(let lhs), .date(let rhs)):
            lhs == rhs
                || (lhs.timeIntervalSinceReferenceDate.isNaN
                    && rhs.timeIntervalSinceReferenceDate.isNaN)
        case (.binary(let lhs), .binary(let rhs)): lhs == rhs
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .boolean(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .integer(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(3)
            Self.hash(value, into: &hasher)
        case .decimal(let value):
            hasher.combine(4)
            if value.isNaN {
                hasher.combine("nan")
            } else {
                hasher.combine(value)
            }
        case .text(let value):
            hasher.combine(5)
            hasher.combine(value)
        case .date(let value):
            hasher.combine(6)
            Self.hash(value.timeIntervalSinceReferenceDate, into: &hasher)
        case .binary(let value):
            hasher.combine(7)
            hasher.combine(value)
        }
    }

    private static func hash(_ value: Double, into hasher: inout Hasher) {
        if value.isNaN {
            hasher.combine("nan")
        } else {
            // `0.0 == -0.0`, so equal signed-zero values need one hash identity.
            hasher.combine(value == 0 ? 0.0 : value)
        }
    }
}

extension AutoChartValue {
    private enum CodingKeys: String, CodingKey {
        case null, boolean, integer, double, decimal, text, date, binary
    }

    private enum AssociatedValueCodingKeys: String, CodingKey {
        case value = "_0"
    }

    /// A stable token for floating-point and date payloads that JSON encoders
    /// reject as numbers. Non-finite values are documented as retained typed
    /// input, so persistence must round-trip them rather than throw.
    private enum NonFiniteToken: String, Codable {
        case positiveInfinity = "inf"
        case negativeInfinity = "-inf"
        case notANumber = "nan"

        init(_ value: Double) {
            if value.isNaN {
                self = .notANumber
            } else {
                self = value > 0 ? .positiveInfinity : .negativeInfinity
            }
        }

        var doubleValue: Double {
            switch self {
            case .positiveInfinity: .infinity
            case .negativeInfinity: -.infinity
            case .notANumber: .nan
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one value case."))
        }
        func nested() throws -> KeyedDecodingContainer<AssociatedValueCodingKeys> {
            try container.nestedContainer(
                keyedBy: AssociatedValueCodingKeys.self, forKey: key)
        }
        switch key {
        case .null:
            _ = try nested()
            self = .null
        case .boolean:
            self = .boolean(try nested().decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try nested().decode(Int64.self, forKey: .value))
        case .double:
            let values = try nested()
            if let number = try? values.decode(Double.self, forKey: .value) {
                self = .double(number)
            } else {
                let token = try values.decode(NonFiniteToken.self, forKey: .value)
                self = .double(token.doubleValue)
            }
        case .decimal:
            let values = try nested()
            if let number = try? values.decode(Decimal.self, forKey: .value) {
                self = .decimal(number)
            } else {
                let token = try values.decode(NonFiniteToken.self, forKey: .value)
                guard token == .notANumber else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .value,
                        in: values,
                        debugDescription: "Decimal values support only the nan token.")
                }
                self = .decimal(.nan)
            }
        case .text:
            self = .text(try nested().decode(String.self, forKey: .value))
        case .date:
            let values = try nested()
            if let date = try? values.decode(Date.self, forKey: .value) {
                self = .date(date)
            } else {
                let token = try values.decode(NonFiniteToken.self, forKey: .value)
                self = .date(Date(timeIntervalSinceReferenceDate: token.doubleValue))
            }
        case .binary:
            self = .binary(try nested().decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func nested(
            _ key: CodingKeys
        ) -> KeyedEncodingContainer<AssociatedValueCodingKeys> {
            container.nestedContainer(keyedBy: AssociatedValueCodingKeys.self, forKey: key)
        }
        switch self {
        case .null:
            _ = nested(.null)
        case .boolean(let value):
            var values = nested(.boolean)
            try values.encode(value, forKey: .value)
        case .integer(let value):
            var values = nested(.integer)
            try values.encode(value, forKey: .value)
        case .double(let value):
            var values = nested(.double)
            if value.isFinite {
                try values.encode(value, forKey: .value)
            } else {
                try values.encode(NonFiniteToken(value), forKey: .value)
            }
        case .decimal(let value):
            var values = nested(.decimal)
            if value.isNaN {
                try values.encode(NonFiniteToken.notANumber, forKey: .value)
            } else {
                try values.encode(value, forKey: .value)
            }
        case .text(let value):
            var values = nested(.text)
            try values.encode(value, forKey: .value)
        case .date(let value):
            var values = nested(.date)
            if value.timeIntervalSinceReferenceDate.isFinite {
                try values.encode(value, forKey: .value)
            } else {
                try values.encode(
                    NonFiniteToken(value.timeIntervalSinceReferenceDate), forKey: .value)
            }
        case .binary(let value):
            var values = nested(.binary)
            try values.encode(value, forKey: .value)
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

extension AutoChartAggregation {
    /// Count results are dimensionless even when they originate from a column
    /// that carries currency, percent, or other unit metadata.
    var usesCountFormatting: Bool {
        switch self {
        case .count, .countDistinct: true
        case .none, .sum, .mean, .minimum, .maximum: false
        }
    }

    /// Structural row counts have no source-measure lineage. Every other
    /// aggregation, including distinct count, remains derived from its column.
    var preservesMeasureLineage: Bool {
        switch self {
        case .count:
            false
        case .none, .sum, .mean, .minimum, .maximum, .countDistinct:
            true
        }
    }
}

/// Declares whether a measure may be aggregated without changing its meaning.
///
/// Recommendation safety is conservative: unknown or unsafe aggregation blocks
/// implicit rollups, and already-aggregated measures are additive only for
/// upstream sums and ordinary counts. Both roll up by summing their values.
/// How values in a measure column were produced.
public enum AutoChartMeasureSource: Hashable, Codable, Sendable {
    case rowLevel
    case aggregated(AutoChartAggregation)
    case derived
}

/// Whether and how values may be rolled up into one visual mark.
public enum AutoChartRollupPolicy: Hashable, Codable, Sendable {
    /// Values may be summed when their source supports additive rollup. An
    /// upstream aggregate qualifies only when it is itself a sum or ordinary
    /// count; means, distinct counts, and other summaries remain non-additive.
    case additive
    /// Values must not be combined automatically.
    case nonAdditive
    /// Values may be combined only with the named operation.
    case safe(AutoChartAggregation)
    /// The host has not established safe rollup behavior.
    case unknown
}

/// Explicit provenance and rollup behavior for a measure column.
public struct AutoChartMeasureSemantics: Hashable, Codable, Sendable {
    public var source: AutoChartMeasureSource
    public var rollup: AutoChartRollupPolicy
    public var preferredTransform: AutoChartAggregation?

    public init(
        source: AutoChartMeasureSource = .rowLevel,
        rollup: AutoChartRollupPolicy = .unknown,
        preferredTransform: AutoChartAggregation? = nil
    ) {
        self.source = source
        self.rollup = rollup
        self.preferredTransform = preferredTransform
    }
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
    /// Provenance and safe rollup behavior for a measure.
    public var measureSemantics: AutoChartMeasureSemantics?
    /// A caller-defined description of the entity or grouping level represented.
    public var grain: String?

    /// Creates semantic hints for a column.
    ///
    /// - Parameters:
    ///   - semanticType: An explicit type, or `nil` to use inference.
    ///   - role: The column's analytical role.
    ///   - unit: Formatting and domain unit metadata.
    ///   - measureSemantics: Provenance and safe rollup behavior for a measure.
    ///   - grain: A human-readable description of the value grain.
    public init(
        semanticType: AutoChartSemanticType? = nil,
        role: AutoChartAnalyticRole? = nil,
        unit: AutoChartUnit? = nil,
        measureSemantics: AutoChartMeasureSemantics? = nil,
        grain: String? = nil
    ) {
        self.semanticType = semanticType
        self.role = role
        self.unit = unit
        self.measureSemantics = measureSemantics
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
public protocol AutoChartRow<RowID>: Sendable {
    associatedtype RowID: Hashable & Sendable

    /// A stable identifier preserved by selections, grouping, and binning.
    var chartRowID: RowID { get }
    /// Returns the typed value associated with a column.
    ///
    /// Return ``AutoChartValue/null`` when the row has no value for the column.
    func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue
}

/// A typed, random-access table that can be profiled and visualized.
///
/// The engine copies the declared columns and supplied rows into an immutable
/// snapshot. It never samples, reorders, or mutates consumer-owned storage.
public protocol AutoChartTable<RowID>: Sendable {
    associatedtype RowID: Hashable & Sendable
    /// The random-access collection that stores this table's rows.
    associatedtype ChartRows: RandomAccessCollection & Sendable
    where ChartRows.Element: AutoChartRow, ChartRows.Element.RowID == RowID

    /// Column descriptions in source order.
    var chartColumns: [AutoChartColumn] { get }
    /// The complete collection of rows supplied for this recommendation request.
    var chartRows: ChartRows { get }
    /// Result-level completeness, grain, and provenance metadata.
    var chartMetadata: AutoChartTableMetadata { get }
    /// An optional caller-managed identity and content revision for cache lookup.
    var chartDataKey: AutoChartDataKey? { get }
}

extension AutoChartTable {
    public var chartDataKey: AutoChartDataKey? { nil }
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
    /// Whether candidate acceptance and rejection decisions are retained.
    public var includesDecisionTrace: Bool
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
        case includesDecisionTrace
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
    ///   - includesDecisionTrace: Whether to retain candidate decisions and exclusions.
    public init(
        maximumRecommendations: Int = 5,
        maximumCategories: Int = 20,
        maximumDonutSectors: Int = 6,
        maximumSeries: Int = 6,
        maximumFacets: Int = 6,
        maximumCandidateColumns: Int = 24,
        includesDecisionTrace: Bool = false
    ) {
        self.maximumRecommendations = max(1, maximumRecommendations)
        self.maximumCategories = max(2, maximumCategories)
        self.maximumDonutSectors = max(2, maximumDonutSectors)
        self.maximumSeries = max(2, maximumSeries)
        self.maximumFacets = max(2, maximumFacets)
        self.maximumCandidateColumns = max(2, maximumCandidateColumns)
        self.includesDecisionTrace = includesDecisionTrace
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
                Int.self, forKey: .maximumCandidateColumns) ?? 24,
            includesDecisionTrace: try container.decodeIfPresent(
                Bool.self, forKey: .includesDecisionTrace) ?? false)
    }
}

/// A visualization family supported by recommendation, validation, and rendering.
public enum AutoChartFamily: String, CaseIterable, Codable, Sendable {
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
    /// Sort by increasing quantitative value, then category label, then canonical
    /// category identity and source order.
    case ascending
    /// Sort by decreasing quantitative value, then category label, then canonical
    /// category identity and source order.
    case descending
}

/// Column-to-channel assignments used by a chart specification.
///
/// Required channels depend on ``AutoChartFamily`` and are checked by
/// ``AutoChartAnalysis/validate(_:)``.
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

extension AutoChartEncoding {
    /// Every assigned column in channel order.
    ///
    /// Keeping this list next to the channel declarations prevents validation,
    /// cache accounting, and future cross-channel checks from drifting when a
    /// channel is added.
    var columnIDs: [AutoChartColumnID] {
        [x, y, series, size, facet, start, end].compactMap { $0 }
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

    /// A deterministic structural identity. Policy version and title are excluded.
    public var id: AutoChartSpecificationID {
        func optionalColumn(_ id: AutoChartColumnID?) -> String {
            id.map { "value:\($0.rawValue)" } ?? "nil"
        }
        func encode(_ component: String) -> String {
            "\(component.utf8.count):\(component)"
        }
        let components = [
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
        return AutoChartSpecificationID(
            rawValue: components.map(encode).joined(separator: "|"))
    }
}

extension AutoChartSpecification {
    public static func kpi(
        measure: AutoChartColumnID,
        title: String = ""
    ) -> Self {
        Self(family: .kpi, encoding: .init(y: measure), title: title)
    }

    public static func bar(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        aggregation: AutoChartAggregation = .none,
        orientation: AutoChartOrientation = .vertical,
        sort: AutoChartSort = .source,
        title: String = ""
    ) -> Self {
        Self(
            family: .bar,
            encoding: .init(x: category, y: measure),
            aggregation: aggregation,
            orientation: orientation,
            sort: sort,
            title: title)
    }

    public static func rankedDot(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        aggregation: AutoChartAggregation = .none,
        sort: AutoChartSort = .descending,
        title: String = ""
    ) -> Self {
        Self(
            family: .rankedDot,
            encoding: .init(x: category, y: measure),
            aggregation: aggregation,
            orientation: .horizontal,
            sort: sort,
            title: title)
    }

    public static func groupedBar(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID,
        aggregation: AutoChartAggregation = .none,
        orientation: AutoChartOrientation = .vertical,
        title: String = ""
    ) -> Self {
        Self(
            family: .groupedBar,
            encoding: .init(x: category, y: measure, series: series),
            aggregation: aggregation,
            orientation: orientation,
            title: title)
    }

    public static func stackedBar(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID,
        aggregation: AutoChartAggregation = .sum,
        orientation: AutoChartOrientation = .vertical,
        title: String = ""
    ) -> Self {
        Self(
            family: .stackedBar,
            encoding: .init(x: category, y: measure, series: series),
            aggregation: aggregation,
            orientation: orientation,
            stacking: .standard,
            title: title)
    }

    public static func normalizedBar(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID,
        aggregation: AutoChartAggregation = .sum,
        orientation: AutoChartOrientation = .vertical,
        title: String = ""
    ) -> Self {
        Self(
            family: .normalizedBar,
            encoding: .init(x: category, y: measure, series: series),
            aggregation: aggregation,
            orientation: orientation,
            stacking: .normalized,
            title: title)
    }

    public static func line(
        x: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        aggregation: AutoChartAggregation = .none,
        title: String = ""
    ) -> Self {
        Self(
            family: .line,
            encoding: .init(x: x, y: measure, series: series),
            aggregation: aggregation,
            title: title)
    }

    public static func pointLine(
        x: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        aggregation: AutoChartAggregation = .none,
        title: String = ""
    ) -> Self {
        Self(
            family: .pointLine,
            encoding: .init(x: x, y: measure, series: series),
            aggregation: aggregation,
            title: title)
    }

    public static func area(
        x: AutoChartColumnID,
        measure: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        aggregation: AutoChartAggregation = .none,
        title: String = ""
    ) -> Self {
        Self(
            family: .area,
            encoding: .init(x: x, y: measure, series: series),
            aggregation: aggregation,
            title: title)
    }

    public static func scatter(
        x: AutoChartColumnID,
        y: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        title: String = ""
    ) -> Self {
        Self(
            family: .scatter,
            encoding: .init(x: x, y: y, series: series),
            title: title)
    }

    public static func bubble(
        x: AutoChartColumnID,
        y: AutoChartColumnID,
        size: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        title: String = ""
    ) -> Self {
        Self(
            family: .bubble,
            encoding: .init(x: x, y: y, series: series, size: size),
            title: title)
    }

    public static func histogram(
        value: AutoChartColumnID,
        binCount: Int? = nil,
        title: String = ""
    ) -> Self {
        Self(
            family: .histogram,
            encoding: .init(x: value),
            aggregation: .count,
            binCount: binCount,
            title: title)
    }

    public static func boxPlot(
        measure: AutoChartColumnID,
        category: AutoChartColumnID? = nil,
        title: String = ""
    ) -> Self {
        Self(family: .boxPlot, encoding: .init(x: category, y: measure), title: title)
    }

    public static func heatmap(
        x: AutoChartColumnID,
        y: AutoChartColumnID,
        title: String = ""
    ) -> Self {
        Self(
            family: .heatmap,
            encoding: .init(x: x, y: y),
            aggregation: .count,
            title: title)
    }

    public static func donut(
        category: AutoChartColumnID,
        measure: AutoChartColumnID,
        aggregation: AutoChartAggregation = .sum,
        title: String = ""
    ) -> Self {
        Self(
            family: .donut,
            encoding: .init(x: category, y: measure),
            aggregation: aggregation,
            title: title)
    }

    public static func range(
        label: AutoChartColumnID,
        start: AutoChartColumnID,
        end: AutoChartColumnID? = nil,
        series: AutoChartColumnID? = nil,
        title: String = ""
    ) -> Self {
        Self(
            family: .range,
            encoding: .init(x: label, series: series, start: start, end: end),
            orientation: .horizontal,
            title: title)
    }

    public static func faceted(
        baseFamily: AutoChartFamily,
        x: AutoChartColumnID,
        y: AutoChartColumnID,
        facet: AutoChartColumnID,
        series: AutoChartColumnID? = nil,
        aggregation: AutoChartAggregation = .none,
        orientation: AutoChartOrientation = .vertical,
        title: String = ""
    ) -> Self {
        Self(
            family: .faceted,
            encoding: .init(x: x, y: y, series: series, facet: facet),
            aggregation: aggregation,
            orientation: orientation,
            facetBaseFamily: baseFamily,
            title: title)
    }
}

/// Stable structural identity for a specification.
public struct AutoChartSpecificationID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Persistable identity for one recommendation policy and specification.
public struct AutoChartRecommendationID: Hashable, Sendable, CustomStringConvertible {
    public var policyVersion: Int
    public var specificationID: AutoChartSpecificationID

    public init(policyVersion: Int, specificationID: AutoChartSpecificationID) {
        self.policyVersion = policyVersion
        self.specificationID = specificationID
    }

    public var description: String {
        "v\(policyVersion):\(specificationID.rawValue)"
    }
}

extension AutoChartRecommendationID: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.policyVersion != rhs.policyVersion {
            return lhs.policyVersion < rhs.policyVersion
        }
        return lhs.specificationID.rawValue < rhs.specificationID.rawValue
    }
}

extension AutoChartRecommendationID: Codable {
    private enum CodingKeys: String, CodingKey { case policyVersion, specificationID }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            guard let decoded = Self.decodeLegacy(legacy) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid recommendation ID."))
            }
            self = decoded
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            policyVersion: try values.decode(Int.self, forKey: .policyVersion),
            specificationID: try values.decode(
                AutoChartSpecificationID.self, forKey: .specificationID))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(policyVersion, forKey: .policyVersion)
        try values.encode(specificationID, forKey: .specificationID)
    }

    private static func decodeLegacy(_ rawValue: String) -> Self? {
        let bytes = Array(rawValue.utf8)
        var offset = 0
        var components: [String] = []
        while offset < bytes.count {
            guard let colon = bytes[offset...].firstIndex(of: 0x3A),
                let length = Int(String(decoding: bytes[offset..<colon], as: UTF8.self)),
                length >= 0,
                length <= bytes.count - colon - 1
            else { return nil }
            let valueStart = colon + 1
            let valueEnd = valueStart + length
            guard let value = String(bytes: bytes[valueStart..<valueEnd], encoding: .utf8)
            else { return nil }
            components.append(value)
            offset = valueEnd
            if offset < bytes.count {
                guard bytes[offset] == 0x7C else { return nil }
                offset += 1
            }
        }
        guard let versionText = components.first,
            let version = Int(versionText), components.count > 1
        else { return nil }
        func encode(_ component: String) -> String { "\(component.utf8.count):\(component)" }
        return Self(
            policyVersion: version,
            specificationID: AutoChartSpecificationID(
                rawValue: components.dropFirst().map(encode).joined(separator: "|")))
    }
}

/// A typed value interpolated into package-authored copy.
public enum AutoChartMessageArgument: Hashable, Codable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case column(AutoChartColumnID)
    case family(AutoChartFamily)
    case aggregation(AutoChartAggregation)
}

/// A stable, localizable package message.
public struct AutoChartMessage: Hashable, Codable, Sendable {
    public enum Category: String, Hashable, Codable, Sendable {
        case diagnostic, rationale, fallback, accessibility, interface
    }

    public enum Code: String, Hashable, Codable, Sendable {
        case recommendationRationale
        case incompleteResult
        case noChartableRows
        case noSafeChart
        case invalidInput
        case validationFailed
        case nonFiniteValueOmitted
        case missingValue
        case unsafeAggregation
        case nonAdditiveSourceSummation
        case duplicateMark
        case invalidTemporalRange
        case chartUnavailable
        case clearSelection
        case resetZoom
        case selectionSummary
        case selectionValue
        case selectionRange
        case selectionDistribution
        case selectionRowCount
        case candidateLimit
        case markAccessibility
        case markAccessibilityDate
        case markAccessibilityRange
    }

    public var category: Category
    public var code: Code
    public var arguments: [String: AutoChartMessageArgument]
    public var defaultText: String

    public init(
        category: Category,
        code: Code,
        arguments: [String: AutoChartMessageArgument] = [:],
        defaultText: String
    ) {
        self.category = category
        self.code = code
        self.arguments = arguments
        self.defaultText = defaultText
    }
}

/// Host override for package-authored text. Return `nil` to use `defaultText`.
public struct AutoChartTextResolver: Sendable {
    private let resolveValue: @Sendable (AutoChartMessage) -> String?

    public init(_ resolve: @escaping @Sendable (AutoChartMessage) -> String?) {
        self.resolveValue = resolve
    }

    public func callAsFunction(_ message: AutoChartMessage) -> String {
        resolveValue(message) ?? message.defaultText
    }

    public static let `default` = AutoChartTextResolver { _ in nil }
}

/// The impact of an analysis or specification diagnostic.
public enum AutoChartValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

/// A stable diagnostic with structured chart context and fallback copy.
public struct AutoChartDiagnostic: Hashable, Codable, Sendable {
    public var severity: AutoChartValidationSeverity
    public var messageValue: AutoChartMessage
    public var family: AutoChartFamily?
    public var columnIDs: [AutoChartColumnID]

    public var message: String { messageValue.defaultText }

    public init(
        severity: AutoChartValidationSeverity,
        code: AutoChartMessage.Code = .validationFailed,
        message: String,
        family: AutoChartFamily? = nil,
        columnIDs: [AutoChartColumnID] = []
    ) {
        self.severity = severity
        self.messageValue = AutoChartMessage(
            category: .diagnostic, code: code, defaultText: message)
        self.family = family
        self.columnIDs = columnIDs
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
    /// Typed reasons the candidate fits the data and task.
    public var rationale: [AutoChartMessage]
    /// Candidate-specific limitations and omissions.
    public var diagnostics: [AutoChartDiagnostic]

    /// Creates a recommendation record.
    ///
    /// - Parameters:
    ///   - specification: A chart specification.
    ///   - score: Its relative policy score.
    ///   - rationale: Reasons for the recommendation.
    ///   - diagnostics: Limitations and cautions associated with the candidate.
    public init(
        specification: AutoChartSpecification,
        score: Double,
        rationale: [AutoChartMessage],
        diagnostics: [AutoChartDiagnostic] = []
    ) {
        self.specification = specification
        self.score = score
        self.rationale = rationale
        self.diagnostics = diagnostics
    }

    /// The deterministic identifier of the enclosed specification.
    public var id: AutoChartRecommendationID {
        AutoChartRecommendationID(
            policyVersion: AutoTableCharts.recommendationPolicyVersion,
            specificationID: specification.id)
    }
}

extension AutoChartRecommendation {
    init(
        specification: AutoChartSpecification,
        score: Double,
        rationale: [String],
        warnings: [String] = []
    ) {
        self.init(
            specification: specification,
            score: score,
            rationale: rationale.map {
                AutoChartMessage(
                    category: .rationale,
                    code: .recommendationRationale,
                    defaultText: $0)
            },
            diagnostics: warnings.map {
                AutoChartDiagnostic(
                    severity: .warning,
                    code: .incompleteResult,
                    message: $0,
                    family: specification.family)
            })
    }
}

struct AutoChartCandidateResults: Sendable {
    public var recommendations: [AutoChartRecommendation]
    public var fallbackReason: String?
    var decisions: [AutoChartCandidateDecision]

    /// Creates a recommendation result.
    ///
    /// - Parameters:
    ///   - recommendations: Ranked chart or fallback recommendations.
    ///   - fallbackReason: The reason only a table can safely represent the data.
    public init(
        recommendations: [AutoChartRecommendation],
        fallbackReason: String? = nil,
        decisions: [AutoChartCandidateDecision] = []
    ) {
        self.recommendations = recommendations
        self.fallbackReason = fallbackReason
        self.decisions = decisions
    }

    public var chartRecommendations: [AutoChartRecommendation] {
        recommendations
    }
}

/// A typed reason charting fell back to the host's table presentation.
public struct AutoChartFallback: Hashable, Codable, Sendable {
    public var message: AutoChartMessage
    public var diagnostics: [AutoChartDiagnostic]

    public init(
        message: AutoChartMessage,
        diagnostics: [AutoChartDiagnostic] = []
    ) {
        self.message = message
        self.diagnostics = diagnostics
    }
}

/// Coherent result of automatic recommendation.
public enum AutoChartRecommendationOutcome: Hashable, Codable, Sendable {
    case charts([AutoChartRecommendation])
    case tableFallback(AutoChartFallback)
}

/// Result of resolving a persisted recommendation preference.
public enum AutoChartRecommendationResolution: Sendable {
    public enum DefaultReason: Hashable, Codable, Sendable {
        case noPersistedPreference
        case policyVersionChanged(previous: Int, current: Int)
        case specificationUnavailable
    }

    case exact(AutoChartRecommendation)
    case defaulted(AutoChartRecommendation, reason: DefaultReason)
    case unavailable(AutoChartFallback)
}

/// Inspectable disposition of one generated chart candidate.
public struct AutoChartCandidateDecision: Hashable, Codable, Sendable {
    public enum Disposition: Hashable, Codable, Sendable {
        case recommended(rank: Int, score: Double)
        case rejected([AutoChartMessage.Code])
        case pruned(AutoChartMessage.Code)
    }

    public var specificationID: AutoChartSpecificationID
    public var family: AutoChartFamily
    public var disposition: Disposition

    public init(
        specificationID: AutoChartSpecificationID,
        family: AutoChartFamily,
        disposition: Disposition
    ) {
        self.specificationID = specificationID
        self.family = family
        self.disposition = disposition
    }
}

/// Inferred public semantics retained without raw column values.
public struct AutoChartInferredColumnSemantics: Hashable, Codable, Sendable {
    public var columnID: AutoChartColumnID
    public var semanticType: AutoChartSemanticType
    public var role: AutoChartAnalyticRole?
    public var measureSemantics: AutoChartMeasureSemantics?

    public init(
        columnID: AutoChartColumnID,
        semanticType: AutoChartSemanticType,
        role: AutoChartAnalyticRole?,
        measureSemantics: AutoChartMeasureSemantics?
    ) {
        self.columnID = columnID
        self.semanticType = semanticType
        self.role = role
        self.measureSemantics = measureSemantics
    }
}

/// Optional development trace retained by an analysis.
public struct AutoChartDecisionTrace: Hashable, Codable, Sendable {
    public var inferredSemantics: [AutoChartInferredColumnSemantics]
    public var candidates: [AutoChartCandidateDecision]

    public init(
        inferredSemantics: [AutoChartInferredColumnSemantics] = [],
        candidates: [AutoChartCandidateDecision]
    ) {
        self.inferredSemantics = inferredSemantics
        self.candidates = candidates
    }
}

public struct AutoChartSelectedDimension: Hashable, Codable, Sendable {
    public var columnID: AutoChartColumnID
    public var value: AutoChartValue

    public init(columnID: AutoChartColumnID, value: AutoChartValue) {
        self.columnID = columnID
        self.value = value
    }
}

/// A typed interval used by a selected dimension whose mark represents a range
/// rather than one source value, such as a histogram bin.
public enum AutoChartSelectedRangeValue: Hashable, Codable, Sendable {
    case numeric(lower: Double, upper: Double)
    case temporal(start: Date, end: Date)
}

/// The source column and exact interval represented by a selected range dimension.
public struct AutoChartSelectedRangeDimension: Hashable, Codable, Sendable {
    public var columnID: AutoChartColumnID
    public var value: AutoChartSelectedRangeValue

    public init(columnID: AutoChartColumnID, value: AutoChartSelectedRangeValue) {
        self.columnID = columnID
        self.value = value
    }
}

public enum AutoChartMarkValue: Hashable, Codable, Sendable {
    case scalar(AutoChartValue)
    case numericRange(lower: Double, upper: Double)
    case temporalRange(start: Date, end: Date)
    case distribution(lower: Double, quartile1: Double, median: Double, quartile3: Double, upper: Double)
}

public struct AutoChartSelectedMeasure: Hashable, Codable, Sendable {
    /// The source measure column, or `nil` for a structural row count that is
    /// not derived from a measure column.
    public var columnID: AutoChartColumnID?
    /// The source column for the start of a temporal range, when the selected
    /// value is backed by separate interval columns.
    public var rangeStartColumnID: AutoChartColumnID?
    /// The source column for the end of a temporal range, when the selected
    /// value is backed by separate interval columns.
    public var rangeEndColumnID: AutoChartColumnID?
    public var aggregation: AutoChartAggregation
    public var value: AutoChartMarkValue

    public init(
        columnID: AutoChartColumnID?,
        rangeStartColumnID: AutoChartColumnID? = nil,
        rangeEndColumnID: AutoChartColumnID? = nil,
        aggregation: AutoChartAggregation,
        value: AutoChartMarkValue
    ) {
        self.columnID = columnID
        self.rangeStartColumnID = rangeStartColumnID
        self.rangeEndColumnID = rangeEndColumnID
        self.aggregation = aggregation
        self.value = value
    }
}

/// Exact typed lineage and semantic values represented by a selected mark.
public struct AutoChartSelection<RowID: Hashable & Sendable>: Hashable, Sendable {
    public var sourceRowIDs: Set<RowID>
    public var dimensions: [AutoChartSelectedDimension]
    public var rangeDimensions: [AutoChartSelectedRangeDimension]
    public var measure: AutoChartSelectedMeasure?
    public var family: AutoChartFamily
    public var specificationID: AutoChartSpecificationID
    public var markID: String

    public init(
        sourceRowIDs: Set<RowID>,
        dimensions: [AutoChartSelectedDimension] = [],
        rangeDimensions: [AutoChartSelectedRangeDimension] = [],
        measure: AutoChartSelectedMeasure? = nil,
        family: AutoChartFamily,
        specificationID: AutoChartSpecificationID,
        markID: String
    ) {
        self.sourceRowIDs = sourceRowIDs
        self.dimensions = dimensions
        self.rangeDimensions = rangeDimensions
        self.measure = measure
        self.family = family
        self.specificationID = specificationID
        self.markID = markID
    }
}

extension AutoChartSelection: Codable where RowID: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceRowIDs, dimensions, rangeDimensions, measure, family, specificationID, markID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceRowIDs: try container.decode(Set<RowID>.self, forKey: .sourceRowIDs),
            dimensions: try container.decode(
                [AutoChartSelectedDimension].self, forKey: .dimensions),
            rangeDimensions: try container.decodeIfPresent(
                [AutoChartSelectedRangeDimension].self, forKey: .rangeDimensions) ?? [],
            measure: try container.decodeIfPresent(
                AutoChartSelectedMeasure.self, forKey: .measure),
            family: try container.decode(AutoChartFamily.self, forKey: .family),
            specificationID: try container.decode(
                AutoChartSpecificationID.self, forKey: .specificationID),
            markID: try container.decode(String.self, forKey: .markID))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceRowIDs, forKey: .sourceRowIDs)
        try container.encode(dimensions, forKey: .dimensions)
        if !rangeDimensions.isEmpty {
            try container.encode(rangeDimensions, forKey: .rangeDimensions)
        }
        try container.encodeIfPresent(measure, forKey: .measure)
        try container.encode(family, forKey: .family)
        try container.encode(specificationID, forKey: .specificationID)
        try container.encode(markID, forKey: .markID)
    }
}

public struct AutoChartSelectionPresentation: Hashable, Codable, Sendable {
    public var label: String
    public var valueDescription: String
    public var accessibilityDescription: String

    public init(label: String, valueDescription: String, accessibilityDescription: String) {
        self.label = label
        self.valueDescription = valueDescription
        self.accessibilityDescription = accessibilityDescription
    }
}

/// The complete diagnostics produced for a chart specification and table.
public struct AutoChartValidationResult: Hashable, Codable, Sendable {
    /// Validation diagnostics in discovery order.
    public var issues: [AutoChartDiagnostic]
    /// Whether the result contains no error-severity issues.
    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    /// Creates a validation result from diagnostics.
    public init(issues: [AutoChartDiagnostic] = []) {
        self.issues = issues
    }
}
