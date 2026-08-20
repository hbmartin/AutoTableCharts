import Foundation

public enum AutoChartFormattingContext: String, Hashable, Codable, Sendable {
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
        if let formatted = override?(column, value, context, locale, timeZone) {
            return formatted
        }
        return defaultFormat(column: column, value: value)
    }

    private func defaultFormat(
        column: AutoChartColumn?,
        value: AutoChartValue
    ) -> String {
        if case .date(let date) = value {
            return date.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: .omitted,
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
            uniqueKeysWithValues: columns.map { ($0.id, $0) })
        let label = dimensions.map { dimension in
            formatters.format(
                column: columnIndex[dimension.columnID],
                value: dimension.value,
                context: .selectionSummary)
        }.joined(separator: ", ")
        let valueDescription: String
        if let measure {
            let column = measure.columnID.flatMap { columnIndex[$0] }
            switch measure.value {
            case .scalar(let value):
                valueDescription = formatters.format(
                    column: column,
                    value: value,
                    context: .selectionSummary)
            case .numericRange(let lower, let upper):
                valueDescription = "\(formatters.format(column: column, value: .double(lower), context: .selectionSummary))–\(formatters.format(column: column, value: .double(upper), context: .selectionSummary))"
            case .temporalRange(let start, let end):
                valueDescription = "\(formatters.format(column: column, value: .date(start), context: .selectionSummary))–\(formatters.format(column: column, value: .date(end), context: .selectionSummary))"
            case .distribution(let lower, _, let median, _, let upper):
                valueDescription = "Median \(formatters.format(column: column, value: .double(median), context: .selectionSummary)); range \(formatters.format(column: column, value: .double(lower), context: .selectionSummary))–\(formatters.format(column: column, value: .double(upper), context: .selectionSummary))"
            }
        } else {
            valueDescription = "\(sourceRowIDs.count) source \(sourceRowIDs.count == 1 ? "row" : "rows")"
        }
        let resolvedLabel = label.isEmpty ? family.displayName : label
        let summary = textResolver(
            AutoChartMessage(
                category: .accessibility,
                code: .selectionSummary,
                arguments: ["rows": .integer(sourceRowIDs.count)],
                defaultText: "\(resolvedLabel), \(valueDescription)"))
        return AutoChartSelectionPresentation(
            label: resolvedLabel,
            valueDescription: valueDescription,
            accessibilityDescription: summary)
    }
}
