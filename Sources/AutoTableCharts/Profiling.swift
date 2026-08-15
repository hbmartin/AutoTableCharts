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
        var seenColumnIDs: Set<AutoChartColumnID> = []
        let columns = table.chartColumns.filter { column in
            seenColumnIDs.insert(column.id).inserted
        }
        self.columns = columns
        metadata = table.chartMetadata
        rows = table.chartRows.map { row in
            Row(
                id: row.chartRowID,
                values: Dictionary(
                    uniqueKeysWithValues: columns.map { column in
                        (column.id, row.chartValue(for: column.id))
                    }))
        }
    }

    func column(_ id: AutoChartColumnID?) -> AutoChartColumn? {
        guard let id else { return nil }
        return columns.first { $0.id == id }
    }

    var contentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(columns)
        hasher.combine(metadata)
        hasher.combine(rows.count)
        for row in rows {
            hasher.combine(row.id)
            for column in columns {
                hasher.combine(row.values[column.id] ?? .null)
            }
        }
        return hasher.finalize()
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

        let nameTokens = nameTokens(column.name)
        if nameTokens.last == "id" {
            return .identifier
        }
        if values.allSatisfy({ if case .boolean = $0 { true } else { false } }) {
            return .boolean
        }
        if dateCount == values.count {
            return .temporal
        }
        if numericCount == values.count {
            if nameTokens.contains("year"), distinctCount <= 100,
                values.allSatisfy({ value in
                    guard let number = value.numericValue, number.rounded() == number else {
                        return false
                    }
                    return number >= 1_000 && number <= 3_000
                })
            {
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
        calendar.timeZone = TimeZone.gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    static func identityString(
        _ value: AutoChartValue?,
        semanticType: AutoChartSemanticType?
    ) -> String? {
        guard let value else { return nil }
        if semanticType == .temporal {
            guard let date = dateValue(value) else { return nil }
            return "date:\(date.timeIntervalSinceReferenceDate.bitPattern)"
        }
        if semanticType == .quantitative {
            guard let number = value.numericValue else { return nil }
            let normalized = number == 0 ? 0.0 : number
            return "number:\(normalized.bitPattern)"
        }
        switch value {
        case .null, .binary:
            return nil
        case .boolean(let value):
            return value ? "boolean:1" : "boolean:0"
        case .integer(let value):
            return "integer:\(value)"
        case .double(let value):
            guard value.isFinite else { return nil }
            return "double:\(value.bitPattern)"
        case .decimal(let value):
            let number = NSDecimalNumber(decimal: value)
            guard number.doubleValue.isFinite else { return nil }
            return "decimal:\(number.stringValue)"
        case .text(let value):
            return "text:\(value.utf8.count):\(value)"
        case .date(let value):
            return "date:\(value.timeIntervalSinceReferenceDate.bitPattern)"
        }
    }

    private static func nameTokens(_ name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasLowercaseOrDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current.lowercased())
            current.removeAll(keepingCapacity: true)
        }
        for character in name {
            guard character.isLetter || character.isNumber else {
                flush()
                previousWasLowercaseOrDigit = false
                continue
            }
            if character.isUppercase && previousWasLowercaseOrDigit {
                flush()
            }
            current.append(character)
            previousWasLowercaseOrDigit = character.isLowercase || character.isNumber
        }
        flush()
        return tokens
    }

    static func humanized(_ name: String) -> String {
        nameTokens(name)
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
    func categoryString() -> String? {
        switch self {
        case .null, .binary: nil
        case .integer(let value): String(value)
        default: displayString
        }
    }
}
