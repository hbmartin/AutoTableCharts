import Foundation

public enum AutoChartFormattingContext: String, CaseIterable, Hashable, Codable, Sendable {
    case axisTick
    case markAccessibility
    case selectionSummary
    case kpi
    case detail

    /// Series labels historically used the axis-tick formatting context.
    /// Retain source compatibility for callers that briefly adopted the
    /// dedicated spelling without adding another exhaustive enum case.
    @available(*, deprecated, message: "Legend values use the axisTick context.")
    public static var legend: Self { .axisTick }

    /// Facet labels historically used the axis-tick formatting context.
    /// Retain source compatibility for callers that briefly adopted the
    /// dedicated spelling without adding another exhaustive enum case.
    @available(*, deprecated, message: "Facet-header values use the axisTick context.")
    public static var facetHeader: Self { .axisTick }
}

enum AutoChartDateLabelPrecision: Int, Comparable, Sendable {
    case date = 0
    case minute = 1
    case second = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AutoChartDateFormatting {
    static func precision(
        for date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> AutoChartDateLabelPrecision {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return .date }
        return precision(
            for: date,
            calendar: localeCalendar(locale: locale, timeZone: timeZone))
    }

    static func precision(
        for date: Date,
        calendar: Calendar
    ) -> AutoChartDateLabelPrecision {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return .date }
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        if (components.second ?? 0) != 0 {
            return .second
        }
        if (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0 {
            return .minute
        }
        return .date
    }

    static func string(
        _ date: Date,
        locale: Locale,
        timeZone: TimeZone,
        precision: AutoChartDateLabelPrecision? = nil,
        calendar suppliedCalendar: Calendar? = nil
    ) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return AutoChartValue.unrepresentableValuePlaceholder
        }
        let calendar = suppliedCalendar
            ?? localeCalendar(locale: locale, timeZone: timeZone)
        let precision = precision
            ?? self.precision(for: date, calendar: calendar)
        let time: Date.FormatStyle.TimeStyle = switch precision {
        case .date: .omitted
        case .minute: .shortened
        case .second: .standard
        }
        return date.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: time,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone))
    }

    static func gregorianCalendar(
        locale: Locale,
        timeZone: TimeZone
    ) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    private static func localeCalendar(
        locale: Locale,
        timeZone: TimeZone
    ) -> Calendar {
        var calendar = locale.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}

/// An aggregation that transforms source values into a rendered measure.
///
/// Unlike ``AutoChartAggregation``, this type has no `none` case: an
/// untransformed source value uses ``AutoChartFormattingPurpose/value``.
public enum AutoChartAppliedAggregation: String, CaseIterable, Hashable, Codable, Sendable {
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

    /// Creates an applied aggregation from a general aggregation, returning
    /// `nil` only for the untransformed `.none` case.
    public init?(_ aggregation: AutoChartAggregation) {
        switch aggregation {
        case .none: return nil
        case .sum: self = .sum
        case .mean: self = .mean
        case .minimum: self = .minimum
        case .maximum: self = .maximum
        case .count: self = .count
        case .countDistinct: self = .countDistinct
        }
    }

    /// The corresponding general aggregation.
    public var aggregation: AutoChartAggregation {
        switch self {
        case .sum: .sum
        case .mean: .mean
        case .minimum: .minimum
        case .maximum: .maximum
        case .count: .count
        case .countDistinct: .countDistinct
        }
    }

    var usesCountFormatting: Bool {
        aggregation.usesCountFormatting
    }
}

/// The semantic role of a value being formatted for chart presentation.
public enum AutoChartFormattingPurpose: Hashable, Sendable {
    /// A source value that has not been aggregated by the chart.
    case value
    /// A source measure after applying the associated aggregation.
    case aggregatedMeasure(AutoChartAppliedAggregation)
    /// A zero-through-one contribution displayed by normalized stacking.
    case normalizedFraction(AutoChartAggregation)
}

extension AutoChartFormattingPurpose {
    /// The presentation purpose for a measure produced by the preparation plan.
    /// `.none` represents an untransformed source value rather than an aggregate.
    static func renderedMeasure(_ aggregation: AutoChartAggregation) -> Self {
        guard aggregation != .none else { return .value }
        guard let applied = AutoChartAppliedAggregation(aggregation) else {
            preconditionFailure("Every non-none aggregation must have an applied representation.")
        }
        return .aggregatedMeasure(applied)
    }
}

/// Complete presentation-time context for a chart value.
public struct AutoChartFormattingRequest: Hashable, Sendable {
    /// The source column, when the value has column lineage.
    public var column: AutoChartColumn?
    /// The value to format.
    public var value: AutoChartValue
    /// The presentation surface requesting the formatted value.
    public var context: AutoChartFormattingContext
    /// Whether the value is raw, aggregated, or a normalized fraction.
    public var purpose: AutoChartFormattingPurpose

    public init(
        column: AutoChartColumn?,
        value: AutoChartValue,
        context: AutoChartFormattingContext,
        purpose: AutoChartFormattingPurpose = .value
    ) {
        self.column = column
        self.value = value
        self.context = context
        self.purpose = purpose
    }
}

/// Host formatting hooks applied at presentation time.
public struct AutoChartFormatters: Sendable {
    /// A compatibility formatter for source values.
    ///
    /// Count, distinct-count, and normalized-fraction requests receive a `nil`
    /// column because this callback cannot distinguish them from ordinary source
    /// values. Use ``RequestFormatter`` when formatting depends on those semantics.
    public typealias ValueFormatter = @Sendable (
        AutoChartColumn?, AutoChartValue, AutoChartFormattingContext, Locale, TimeZone
    ) -> String?
    /// A formatter that receives the complete semantic formatting request.
    public typealias RequestFormatter = @Sendable (
        AutoChartFormattingRequest, Locale, TimeZone
    ) -> String?

    public var locale: Locale
    public var timeZone: TimeZone
    private let override: RequestFormatter?

    public init(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        value: ValueFormatter? = nil
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.override = value.map { valueFormatter -> RequestFormatter in
            { request, locale, timeZone in
                valueFormatter(
                    Self.legacyColumn(for: request),
                    request.value,
                    request.context,
                    locale,
                    timeZone)
            }
        }
    }

    /// Creates formatters with an aggregation-aware host override.
    public init(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        request: @escaping RequestFormatter
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.override = request
    }

    public func format(
        column: AutoChartColumn?,
        value: AutoChartValue,
        context: AutoChartFormattingContext
    ) -> String {
        format(
            AutoChartFormattingRequest(
                column: column,
                value: value,
                context: context))
    }

    /// Formats a complete semantic request.
    public func format(_ request: AutoChartFormattingRequest) -> String {
        if let formatted = formatOverride(request) {
            return formatted
        }
        return formatDefault(request)
    }

    /// Formats one normalized category at presentation time. Host overrides
    /// receive a value request carrying that normalized category; the default
    /// keeps enough numeric precision to distinguish categories.
    func formatCategory(
        column: AutoChartColumn?,
        value: AutoChartValue,
        context: AutoChartFormattingContext,
        datePrecision: AutoChartDateLabelPrecision? = nil,
        numberNotation: AutoChartCategoryNumberNotation = .automatic,
        calendar: Calendar? = nil
    ) -> String {
        let request = AutoChartFormattingRequest(
            column: column,
            value: value,
            context: context)
        if let formatted = overridden(request) {
            return formatted
        }
        return value.categoryString(
            locale: locale,
            timeZone: timeZone,
            datePrecision: datePrecision,
            numberNotation: numberNotation,
            calendar: calendar)
            ?? AutoChartValue.unrepresentableValuePlaceholder
    }

    /// Formats a measure while preserving its source column for request overrides.
    ///
    /// Count and distinct-count results remain unitless under the default
    /// formatter even when the source column carries currency, percent, or other
    /// unit metadata. Compatibility value overrides receive `nil` for those
    /// results because their callback cannot distinguish counts from ordinary
    /// source values. Use ``RequestFormatter`` to retain count lineage.
    ///
    /// Passing `.none` formats an untransformed source value with purpose
    /// ``AutoChartFormattingPurpose/value``.
    public func format(
        column: AutoChartColumn?,
        aggregation: AutoChartAggregation,
        value: AutoChartValue,
        context: AutoChartFormattingContext
    ) -> String {
        format(
            AutoChartFormattingRequest(
                column: column,
                value: value,
                context: context,
                purpose: .renderedMeasure(aggregation)))
    }

    /// Formats a zero-through-one contribution as a percentage by default.
    ///
    /// Aggregation-aware request overrides receive the supplied source column.
    /// Compatibility value overrides receive `nil` because their callback cannot
    /// distinguish a normalized fraction from an ordinary source value.
    public func formatNormalizedFraction(
        _ value: Double,
        column: AutoChartColumn? = nil,
        aggregation: AutoChartAggregation = .none,
        context: AutoChartFormattingContext
    ) -> String {
        format(
            AutoChartFormattingRequest(
                column: column,
                value: .double(value),
                context: context,
                purpose: .normalizedFraction(aggregation)))
    }

    private static func legacyColumn(
        for request: AutoChartFormattingRequest
    ) -> AutoChartColumn? {
        switch request.purpose {
        case .value:
            request.column
        case .aggregatedMeasure(let aggregation):
            aggregation.usesCountFormatting ? nil : request.column
        case .normalizedFraction:
            nil
        }
    }

    private func defaultFormat(_ request: AutoChartFormattingRequest) -> String {
        switch request.purpose {
        case .value:
            return defaultFormat(column: request.column, value: request.value)
        case .aggregatedMeasure(let aggregation):
            return defaultFormat(
                column: aggregation.usesCountFormatting ? nil : request.column,
                value: request.value)
        case .normalizedFraction:
            guard let value = request.value.numericValue else {
                return request.value.displayString
            }
            return value.formatted(
                .percent.locale(locale).precision(.fractionLength(0...2)))
        }
    }

    private func overridden(_ request: AutoChartFormattingRequest) -> String? {
        override?(request, locale, timeZone)
    }

    func formatOverride(_ request: AutoChartFormattingRequest) -> String? {
        overridden(request)
    }

    func formatDefault(_ request: AutoChartFormattingRequest) -> String {
        defaultFormat(request)
    }

    private func defaultFormat(
        column: AutoChartColumn?,
        value: AutoChartValue
    ) -> String {
        if case .date(let date) = value {
            return AutoChartDateFormatting.string(
                date,
                locale: locale,
                timeZone: timeZone)
        }
        guard let number = value.numericValue else { return value.displayString }
        switch column?.hints.unit {
        case .currency(let code):
            return number.formatted(
                .currency(code: code).locale(locale).precision(.fractionLength(0...2)))
        case .percent(let fractional):
            let value = fractional ? number : number / 100
            return value.formatted(
                .percent.locale(locale).precision(.fractionLength(0...2)))
        case .area(let unit), .duration(let unit), .custom(let unit):
            let formatted = number.formatted(
                .number.locale(locale).grouping(.automatic).precision(.fractionLength(0...3)))
            return "\(formatted) \(unit)"
        case .number, nil:
            return number.formatted(
                .number.locale(locale).grouping(.automatic).precision(.fractionLength(0...3)))
        }
    }
}

enum AutoChartFormattingLineage {
    static func rangeColumns(
        columnID: AutoChartColumnID?,
        startColumnID: AutoChartColumnID?,
        endColumnID: AutoChartColumnID?,
        resolve: (AutoChartColumnID) -> AutoChartColumn?
    ) -> (start: AutoChartColumn?, end: AutoChartColumn?) {
        let fallback = columnID.flatMap(resolve)
        return (
            startColumnID.flatMap(resolve) ?? fallback,
            endColumnID.flatMap(resolve) ?? fallback)
    }
}

extension AutoChartSelection {
    public func presentation(
        columns: [AutoChartColumn],
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartSelectionPresentation {
        presentation(
            columns: columns,
            formatters: formatters,
            textResolver: textResolver,
            resolvedDimensionLabel: { _ in nil })
    }

    func presentation(
        columns: [AutoChartColumn],
        formatters: AutoChartFormatters,
        textResolver: AutoChartTextResolver,
        resolvedDimensionLabel: (AutoChartSelectedDimension) -> String?
    ) -> AutoChartSelectionPresentation {
        let columnIndex = Dictionary(
            columns.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let scalarLabels = dimensions.map { dimension in
            let request = AutoChartFormattingRequest(
                column: columnIndex[dimension.columnID],
                value: dimension.value,
                context: .selectionSummary)
            return formatters.formatOverride(request)
                ?? resolvedDimensionLabel(dimension)
                ?? formatters.formatDefault(request)
        }
        let rangeLabels = rangeDimensions.map { dimension in
            let column = columnIndex[dimension.columnID]
            switch dimension.value {
            case .numeric(let lower, let upper):
                let lower = formatters.format(
                    column: column, value: .double(lower), context: .selectionSummary)
                let upper = formatters.format(
                    column: column, value: .double(upper), context: .selectionSummary)
                return "\(lower)–\(upper)"
            case .temporal(let start, let end):
                let start = formatters.format(
                    column: column, value: .date(start), context: .selectionSummary)
                let end = formatters.format(
                    column: column, value: .date(end), context: .selectionSummary)
                return "\(start)–\(end)"
            }
        }
        let label = (scalarLabels + rangeLabels).joined(separator: ", ")
        let valueMessage: AutoChartMessage
        if let measure {
            let column = measure.columnID.flatMap { columnIndex[$0] }
            func formatted(_ value: AutoChartValue, column: AutoChartColumn?) -> String {
                formatters.format(
                    AutoChartFormattingRequest(
                        column: column,
                        value: value,
                        context: .selectionSummary,
                        purpose: .renderedMeasure(measure.aggregation)))
            }
            func formattedMeasure(_ value: AutoChartValue) -> String {
                formatted(value, column: column)
            }
            switch measure.value {
            case .scalar(let value):
                let formattedValue = formattedMeasure(value)
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionValue,
                    arguments: ["value": .string(formattedValue)],
                    defaultText: formattedValue)
            case .numericRange(let lower, let upper):
                let lower = formattedMeasure(.double(lower))
                let upper = formattedMeasure(.double(upper))
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionRange,
                    arguments: ["lower": .string(lower), "upper": .string(upper)],
                    defaultText: "\(lower)–\(upper)")
            case .temporalRange(let start, let end):
                let rangeColumns = AutoChartFormattingLineage.rangeColumns(
                    columnID: measure.columnID,
                    startColumnID: measure.rangeStartColumnID,
                    endColumnID: measure.rangeEndColumnID,
                    resolve: { columnIndex[$0] })
                let start = formatted(.date(start), column: rangeColumns.start)
                let end = formatted(.date(end), column: rangeColumns.end)
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionRange,
                    arguments: ["lower": .string(start), "upper": .string(end)],
                    defaultText: "\(start)–\(end)")
            case .distribution(let lower, _, let median, _, let upper):
                let median = formattedMeasure(.double(median))
                let lower = formattedMeasure(.double(lower))
                let upper = formattedMeasure(.double(upper))
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionDistribution,
                    arguments: [
                        "median": .string(median),
                        "lower": .string(lower),
                        "upper": .string(upper),
                    ],
                    defaultText: "Median \(median); range \(lower)–\(upper)")
            }
        } else {
            valueMessage = AutoChartMessage(
                category: .interface,
                code: .selectionRowCount,
                arguments: ["rows": .integer(sourceRowIDs.count)],
                defaultText:
                    "\(sourceRowIDs.count) source \(sourceRowIDs.count == 1 ? "row" : "rows")")
        }
        let resolvedLabel = label.isEmpty ? family.displayName : label
        let valueDescription = textResolver(valueMessage)
        let summary = textResolver(
            AutoChartMessage(
                category: .accessibility,
                code: .selectionSummary,
                arguments: [
                    "label": .string(resolvedLabel),
                    "value": .string(valueDescription),
                    "rows": .integer(sourceRowIDs.count),
                ],
                defaultText: "\(resolvedLabel), \(valueDescription)"))
        return AutoChartSelectionPresentation(
            label: resolvedLabel,
            valueDescription: valueDescription,
            accessibilityDescription: summary)
    }
}
