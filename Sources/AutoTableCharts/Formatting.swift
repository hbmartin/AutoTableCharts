import Foundation

public enum AutoChartFormattingContext: String, CaseIterable, Hashable, Codable, Sendable {
    case axisTick
    case markAccessibility
    case selectionSummary
    case kpi
    case detail
}

/// The semantic role of a value being formatted for chart presentation.
public enum AutoChartFormattingPurpose: Hashable, Sendable {
    /// A source value that has not been aggregated by the chart.
    case value
    /// A source measure after applying the associated aggregation.
    case aggregatedMeasure(AutoChartAggregation)
    /// A zero-through-one contribution displayed by normalized stacking.
    case normalizedFraction(AutoChartAggregation)
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
    /// Count and normalized-fraction requests receive a `nil` column because
    /// this callback cannot distinguish them from ordinary source values. Use
    /// ``RequestFormatter`` when formatting depends on those semantics.
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
        if let formatted = override?(request, locale, timeZone) {
            return formatted
        }
        return defaultFormat(request)
    }

    /// Formats a measure while preserving its source column for request overrides.
    ///
    /// Count results remain unitless under the default formatter even when the
    /// source column carries currency, percent, or other unit metadata.
    /// Compatibility value overrides receive `nil` for count results because
    /// their callback cannot distinguish counts from ordinary source values.
    /// Use ``RequestFormatter`` to retain count lineage.
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
                purpose: .aggregatedMeasure(aggregation)))
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

    private func defaultFormat(
        column: AutoChartColumn?,
        value: AutoChartValue
    ) -> String {
        if case .date(let date) = value {
            // Non-finite dates survive validation as a warning, so they reach
            // ticks, mark labels, and selection summaries. `Date.FormatStyle`
            // renders NaN as an empty string and infinities as year 5828963;
            // neither tells the reader the value is unusable.
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                return AutoChartValue.unrepresentableValuePlaceholder
            }
            // Sub-day values must keep their time component or every tick,
            // mark, and selection within one day formats identically.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            calendar.locale = locale
            let components = calendar.dateComponents([.hour, .minute, .second], from: date)
            let time: Date.FormatStyle.TimeStyle =
                if (components.second ?? 0) != 0 {
                    .standard
                } else if (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0 {
                    .shortened
                } else {
                    .omitted
                }
            return date.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: time,
                    locale: locale,
                    timeZone: timeZone))
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

extension AutoChartSelection {
    public func presentation(
        columns: [AutoChartColumn],
        formatters: AutoChartFormatters = .init(),
        textResolver: AutoChartTextResolver = .default
    ) -> AutoChartSelectionPresentation {
        let columnIndex = Dictionary(
            columns.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let scalarLabels = dimensions.map { dimension in
            formatters.format(
                column: columnIndex[dimension.columnID],
                value: dimension.value,
                context: .selectionSummary)
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
                if measure.aggregation == .none {
                    return formatters.format(
                        column: column,
                        value: value,
                        context: .selectionSummary)
                }
                return formatters.format(
                    column: column,
                    aggregation: measure.aggregation,
                    value: value,
                    context: .selectionSummary)
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
                let startColumn = measure.rangeStartColumnID.flatMap { columnIndex[$0] }
                    ?? column
                let endColumn = measure.rangeEndColumnID.flatMap { columnIndex[$0] }
                    ?? column
                let start = formatted(.date(start), column: startColumn)
                let end = formatted(.date(end), column: endColumn)
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
