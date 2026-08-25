import Foundation

public enum AutoChartFormattingContext: String, CaseIterable, Hashable, Codable, Sendable {
    case axisTick
    case markAccessibility
    case selectionSummary
    case kpi
    case detail
}

/// Host formatting hooks applied at presentation time.
public struct AutoChartFormatters: Sendable {
    public typealias ValueFormatter = @Sendable (
        AutoChartColumn?, AutoChartValue, AutoChartFormattingContext, Locale, TimeZone
    ) -> String?

    public var locale: Locale
    public var timeZone: TimeZone
    private let override: ValueFormatter?

    public init(
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        value: ValueFormatter? = nil
    ) {
        self.locale = locale
        self.timeZone = timeZone
        self.override = value
    }

    public func format(
        column: AutoChartColumn?,
        value: AutoChartValue,
        context: AutoChartFormattingContext
    ) -> String {
        format(
            column: column,
            value: value,
            context: context,
            defaultColumn: column)
    }

    func format(
        column: AutoChartColumn?,
        value: AutoChartValue,
        context: AutoChartFormattingContext,
        defaultColumn: AutoChartColumn?
    ) -> String {
        if let formatted = override?(column, value, context, locale, timeZone) {
            return formatted
        }
        return defaultFormat(column: defaultColumn, value: value)
    }

    func formatMeasure(
        column: AutoChartColumn?,
        aggregation: AutoChartAggregation,
        value: AutoChartValue,
        context: AutoChartFormattingContext
    ) -> String {
        format(
            column: column,
            value: value,
            context: context,
            defaultColumn: aggregation.usesCountFormatting ? nil : column)
    }

    func formatNormalizedFraction(
        _ value: Double,
        context: AutoChartFormattingContext
    ) -> String {
        if let formatted = override?(nil, .double(value), context, locale, timeZone) {
            return formatted
        }
        return value.formatted(
            .percent.locale(locale).precision(.fractionLength(0...2)))
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
            func formatted(_ value: AutoChartValue) -> String {
                formatters.formatMeasure(
                    column: column,
                    aggregation: measure.aggregation,
                    value: value,
                    context: .selectionSummary)
            }
            switch measure.value {
            case .scalar(let value):
                let formattedValue = formatted(value)
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionValue,
                    arguments: ["value": .string(formattedValue)],
                    defaultText: formattedValue)
            case .numericRange(let lower, let upper):
                let lower = formatted(.double(lower))
                let upper = formatted(.double(upper))
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionRange,
                    arguments: ["lower": .string(lower), "upper": .string(upper)],
                    defaultText: "\(lower)–\(upper)")
            case .temporalRange(let start, let end):
                let start = formatted(.date(start))
                let end = formatted(.date(end))
                valueMessage = AutoChartMessage(
                    category: .interface,
                    code: .selectionRange,
                    arguments: ["lower": .string(start), "upper": .string(end)],
                    defaultText: "\(start)–\(end)")
            case .distribution(let lower, _, let median, _, let upper):
                let median = formatted(.double(median))
                let lower = formatted(.double(lower))
                let upper = formatted(.double(upper))
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
