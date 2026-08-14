import Foundation

struct AutoChartSnapshot: Sendable {
    struct Row: Sendable {
        var id: AutoChartRowID
        var values: [AutoChartColumnID: AutoChartValue]
    }

    var columns: [AutoChartColumn]
    var rows: [Row]
    var metadata: AutoChartTableMetadata

    init<Table: AutoChartTable>(_ table: Table) {
        columns = table.chartColumns
        metadata = table.chartMetadata
        rows = table.chartRows.map { row in
            Row(
                id: row.chartRowID,
                values: Dictionary(
                    uniqueKeysWithValues: table.chartColumns.map { column in
                        (column.id, row.chartValue(for: column.id))
                    }))
        }
    }

    func column(_ id: AutoChartColumnID?) -> AutoChartColumn? {
        guard let id else { return nil }
        return columns.first { $0.id == id }
    }
}

struct AutoChartColumnProfile: Sendable {
    var column: AutoChartColumn
    var semanticType: AutoChartSemanticType
    var nonNullCount: Int
    var distinctCount: Int
    var nullFraction: Double
    var numericMinimum: Double?
    var numericMaximum: Double?
    var allNumericValuesPositive: Bool
    var averageTextLength: Double
    var temporalValues: [Date]

    var isQuantitative: Bool { semanticType == .quantitative }
    var isTemporal: Bool { semanticType == .temporal }
    var isCategorical: Bool {
        semanticType == .nominal || semanticType == .ordinal
            || semanticType == .boolean
    }
}

enum AutoChartProfiler {
    static func profiles(_ snapshot: AutoChartSnapshot) -> [AutoChartColumnProfile] {
        snapshot.columns.map { column in
            profile(column, rows: snapshot.rows)
        }
    }

    static func profile(
        _ column: AutoChartColumn,
        rows: [AutoChartSnapshot.Row]
    ) -> AutoChartColumnProfile {
        let values = rows.map { $0.values[column.id] ?? .null }
        let nonNull = values.filter {
            if case .null = $0 { return false }
            return true
        }
        let numeric = nonNull.compactMap(\.numericValue)
        let dates = nonNull.compactMap(dateValue)
        let textLengths = nonNull.compactMap { value -> Int? in
            if case .text(let text) = value { return text.count }
            return nil
        }
        let distinct = Set(nonNull)
        let type = inferredSemanticType(
            column: column,
            values: nonNull,
            numericCount: numeric.count,
            dateCount: dates.count,
            distinctCount: distinct.count)
        return AutoChartColumnProfile(
            column: column,
            semanticType: type,
            nonNullCount: nonNull.count,
            distinctCount: distinct.count,
            nullFraction: values.isEmpty
                ? 0 : Double(values.count - nonNull.count) / Double(values.count),
            numericMinimum: numeric.min(),
            numericMaximum: numeric.max(),
            allNumericValuesPositive: !numeric.isEmpty && numeric.allSatisfy { $0 > 0 },
            averageTextLength: textLengths.isEmpty
                ? 0 : Double(textLengths.reduce(0, +)) / Double(textLengths.count),
            temporalValues: dates)
    }

    private static func inferredSemanticType(
        column: AutoChartColumn,
        values: [AutoChartValue],
        numericCount: Int,
        dateCount: Int,
        distinctCount: Int
    ) -> AutoChartSemanticType {
        if let explicit = column.hints.semanticType { return explicit }
        if column.hints.role == .identifier { return .identifier }
        guard !values.isEmpty else { return .unsupported }

        let normalizedName = column.name.lowercased()
        if normalizedName == "id" || normalizedName.hasSuffix("_id")
            || normalizedName.hasSuffix(" id")
        {
            return .identifier
        }
        if values.allSatisfy({ if case .boolean = $0 { true } else { false } }) {
            return .boolean
        }
        if dateCount == values.count
            || (dateCount >= 2 && Double(dateCount) / Double(values.count) >= 0.8)
        {
            return .temporal
        }
        if numericCount == values.count {
            if normalizedName.contains("year") && distinctCount <= 100 {
                return .ordinal
            }
            return .quantitative
        }
        if values.contains(where: { if case .binary = $0 { true } else { false } }) {
            return .unsupported
        }
        return .nominal
    }

    static func dateValue(_ value: AutoChartValue) -> Date? {
        switch value {
        case .date(let date): date
        case .text(let text): parseISODate(text)
        default: nil
        }
    }

    static func parseISODate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            (1...12).contains(month),
            (1...31).contains(day)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func humanized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { token in
                let lower = token.lowercased()
                if ["id", "noi", "ltv", "irr", "dscr"].contains(lower) {
                    return lower.uppercased()
                }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}

extension AutoChartValue {
    func categoryString(semanticType: AutoChartSemanticType? = nil) -> String? {
        switch self {
        case .null, .binary: nil
        case .boolean(let value): value ? "Yes" : "No"
        case .integer(let value): String(value)
        case .double(let value): value.formatted(.number.precision(.fractionLength(0...3)))
        case .decimal(let value): NSDecimalNumber(decimal: value).stringValue
        case .text(let value): value
        case .date(let value): value.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
