import Foundation

/// The canonical bits of a date's reference interval.
///
/// Signed zeros collapse so equal dates agree, and non-finite intervals keep
/// their own pattern so hashing and equality can't disagree about them.
private func dateBits(_ date: Date) -> UInt64 {
    let interval = date.timeIntervalSinceReferenceDate
    return (interval == 0 ? 0.0 : interval).bitPattern
}

struct AutoChartErasedRowID: @unchecked Sendable, Hashable, CustomStringConvertible {
    private let value: AnyHashable

    init<RowID: Hashable & Sendable>(_ value: RowID) {
        self.value = AnyHashable(value)
    }

    var description: String { String(describing: value.base) }

    var estimatedRetainedCost: Int {
        let payloadCost = switch value.base {
        case let value as String: value.utf8.count
        case let value as Data: value.count
        default: 0
        }
        let (cost, overflow) = MemoryLayout<AnyHashable>.stride.addingReportingOverflow(
            payloadCost)
        return overflow ? Int.max : cost
    }
}

struct AutoChartSnapshot: Sendable {
    struct RowValues: Sendable {
        let storage: AutoChartMatrixStorage
        let rowIndex: Int

        subscript(columnID: AutoChartColumnID) -> AutoChartValue? {
            storage.value(row: rowIndex, columnID: columnID)
        }

        subscript(columnIndex: Int) -> AutoChartValue {
            storage.value(row: rowIndex, columnIndex: columnIndex)
        }
    }

    struct Row: Sendable {
        /// Internal source offset. Public typed IDs are retained by `AutoChartAnalysis`.
        let id: Int
        let values: RowValues
    }

    let storage: AutoChartMatrixStorage
    let rowIdentities: [AutoChartErasedRowID]
    let rows: [Row]
    let validationIdentity: UUID

    var columns: [AutoChartColumn] { storage.columns }
    var metadata: AutoChartTableMetadata { storage.metadata }

    init<Table: AutoChartTable>(_ table: Table) {
        do {
            try self.init(validating: table, checkingCancellation: false)
        } catch {
            preconditionFailure("Invalid chart table: \(error)")
        }
    }

    init<Table: AutoChartTable>(
        validating table: Table,
        checkingCancellation: Bool = true
    ) throws {
        try self.init(
            validating: table,
            chartRows: Array(table.chartRows),
            checkingCancellation: checkingCancellation)
    }

    init<Table: AutoChartTable>(
        validating table: Table,
        chartRows: [Table.ChartRows.Element],
        checkingCancellation: Bool = true
    ) throws {
        validationIdentity = UUID()
        // `chartColumns` is a protocol requirement a conformance may compute,
        // so read it once: reading it per row rebuilt the array inside the
        // ingestion loop, and a conformance returning a fresh array each time
        // could otherwise desynchronize the flat matrix from its column list.
        let columns = table.chartColumns
        var seenColumnIDs: Set<AutoChartColumnID> = []
        for column in columns where !seenColumnIDs.insert(column.id).inserted {
            throw AutoChartDatasetError(
                code: .duplicateColumnID,
                identifier: column.id.rawValue)
        }

        if let dataset = table as? any AutoChartDatasetStorageProviding {
            storage = dataset._autoChartMatrixStorage
            rowIdentities = dataset._autoChartErasedRowIDs
        } else {
            var seenRows: Set<Table.RowID> = []
            for (index, row) in chartRows.enumerated() {
                if checkingCancellation, index.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                guard seenRows.insert(row.chartRowID).inserted else {
                    throw AutoChartDatasetError(
                        code: .duplicateRowID,
                        identifier: String(describing: row.chartRowID))
                }
            }
            var flat: [AutoChartValue] = []
            flat.reserveCapacity(chartRows.count * columns.count)
            for (index, row) in chartRows.enumerated() {
                if checkingCancellation, index.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                for column in columns {
                    flat.append(row.chartValue(for: column.id))
                }
            }
            storage = AutoChartMatrixStorage(
                columns: columns,
                values: flat,
                rowCount: chartRows.count,
                metadata: table.chartMetadata)
            rowIdentities = chartRows.map { AutoChartErasedRowID($0.chartRowID) }
        }
        guard rowIdentities.count == storage.rowCount else {
            throw AutoChartDatasetError(
                code: .rowIDCountMismatch,
                expectedCount: storage.rowCount,
                actualCount: rowIdentities.count)
        }
        let matrixStorage = storage
        rows = (0..<matrixStorage.rowCount).map {
            Row(id: $0, values: RowValues(storage: matrixStorage, rowIndex: $0))
        }
    }

    var contentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(columns)
        hasher.combine(metadata)
        hasher.combine(rows.count)
        for row in rows {
            hasher.combine(rowIdentities[row.id])
            for columnIndex in columns.indices {
                Self.combineContent(
                    row.values[columnIndex],
                    into: &hasher)
            }
        }
        return hasher.finalize()
    }

    func contentFingerprintCheckingCancellation() throws -> Int {
        var hasher = Hasher()
        hasher.combine(columns)
        hasher.combine(metadata)
        hasher.combine(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            hasher.combine(rowIdentities[row.id])
            for columnIndex in columns.indices {
                Self.combineContent(
                    row.values[columnIndex],
                    into: &hasher)
            }
        }
        return hasher.finalize()
    }

    var estimatedStorageCost: Int {
        var storageCost = 256
        for column in columns {
            Self.addStorageCost(256, to: &storageCost)
            Self.addStorageCost(column.id.rawValue.utf8.count, to: &storageCost)
            Self.addStorageCost(column.name.utf8.count, to: &storageCost)
            Self.addStorageCost(column.displayName?.utf8.count ?? 0, to: &storageCost)
            Self.addStorageCost(column.hints.grain?.utf8.count ?? 0, to: &storageCost)
            Self.addStorageCost(Self.unitStringCost(column.hints.unit), to: &storageCost)
        }
        for row in rows {
            Self.addStorageCost(128, to: &storageCost)
            Self.addStorageCost(rowIdentities[row.id].estimatedRetainedCost, to: &storageCost)
            for columnIndex in columns.indices {
                let value = row.values[columnIndex]
                Self.addStorageCost(96, to: &storageCost)
                Self.addStorageCost(Self.payloadCost(value), to: &storageCost)
            }
        }
        return storageCost
    }

    func column(_ id: AutoChartColumnID?) -> AutoChartColumn? {
        guard let id else { return nil }
        return columns.first { $0.id == id }
    }

    func hasSameContent(as other: AutoChartSnapshot) -> Bool {
        guard columns == other.columns,
            metadata == other.metadata,
            rowIdentities == other.rowIdentities,
            rows.count == other.rows.count
        else { return false }
        return zip(rows, other.rows).allSatisfy { left, right in
            guard left.id == right.id else { return false }
            return columns.indices.allSatisfy { columnIndex in
                Self.valuesMatch(
                    left.values[columnIndex],
                    right.values[columnIndex])
            }
        }
    }

    func hasSameContentCheckingCancellation(as other: AutoChartSnapshot) throws -> Bool {
        guard columns == other.columns,
            metadata == other.metadata,
            rowIdentities == other.rowIdentities,
            rows.count == other.rows.count
        else { return false }
        for (index, pair) in zip(rows, other.rows).enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let (left, right) = pair
            guard left.id == right.id else { return false }
            for columnIndex in columns.indices where !Self.valuesMatch(
                left.values[columnIndex],
                right.values[columnIndex])
            {
                return false
            }
        }
        return true
    }

    private static func valuesMatch(_ left: AutoChartValue, _ right: AutoChartValue) -> Bool {
        switch (left, right) {
        case (.null, .null): true
        case (.boolean(let left), .boolean(let right)): left == right
        case (.integer(let left), .integer(let right)): left == right
        case (.double(let left), .double(let right)): left.bitPattern == right.bitPattern
        case (.decimal(let left), .decimal(let right)): left == right
        case (.text(let left), .text(let right)): left == right
        case (.date(let left), .date(let right)): dateBits(left) == dateBits(right)
        case (.binary(let left), .binary(let right)): left == right
        default: false
        }
    }

    private static func combineContent(_ value: AutoChartValue, into hasher: inout Hasher) {
        switch value {
        case .null:
            hasher.combine(0 as UInt8)
        case .boolean(let value):
            hasher.combine(1 as UInt8)
            hasher.combine(value)
        case .integer(let value):
            hasher.combine(2 as UInt8)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(3 as UInt8)
            hasher.combine(value.bitPattern)
        case .decimal(let value):
            hasher.combine(4 as UInt8)
            hasher.combine(value)
        case .text(let value):
            hasher.combine(5 as UInt8)
            hasher.combine(value)
        case .date(let value):
            hasher.combine(6 as UInt8)
            hasher.combine(dateBits(value))
        case .binary(let value):
            hasher.combine(7 as UInt8)
            hasher.combine(value)
        }
    }

    private static func addStorageCost(_ amount: Int, to cost: inout Int) {
        guard cost != Int.max else { return }
        let (result, overflow) = cost.addingReportingOverflow(amount)
        cost = overflow ? Int.max : result
    }

    private static func payloadCost(_ value: AutoChartValue) -> Int {
        switch value {
        case .text(let value): value.utf8.count
        case .binary(let value): value.count
        default: 0
        }
    }

    private static func unitStringCost(_ unit: AutoChartUnit?) -> Int {
        switch unit {
        case .currency(let code): code.utf8.count
        case .duration(let unit), .area(let unit), .custom(let unit): unit.utf8.count
        case .number, .percent, nil: 0
        }
    }
}

public struct AutoChartColumnProfile: Sendable {
    public var column: AutoChartColumn
    public var semanticType: AutoChartSemanticType
    public var nonNullCount: Int
    public var numericTypeCount: Int
    public var numericValueCount: Int
    public var renderableValueCount: Int
    /// Unique values after applying the column's inferred semantic identity.
    public var renderableDistinctCount: Int
    /// Unique raw typed values used while inferring the column's semantic type.
    public var distinctCount: Int
    public var numericMinimum: Double?
    public var numericMaximum: Double?
    /// Whether every value is a positive number, counting a missing or non-finite
    /// value as disqualifying. Recommendation uses this to avoid proposing a
    /// composition that could only ever render part of a whole.
    public var allNumericValuesPositive: Bool
    public var averageTextLength: Double
    /// Typed dates that can position a mark on a finite axis.
    ///
    /// A profile is a summary: it keeps this count rather than the dates
    /// themselves, so profiling a long temporal column costs nothing to retain
    /// and the analyzer's flat per-profile cost charge stays accurate.
    public var temporalValueCount: Int
    public var temporalMinimum: Date?
    public var temporalMaximum: Date?
    /// Typed dates whose interval cannot be positioned on a finite chart axis.
    public var nonFiniteDateCount: Int

    /// The bytes this profile keeps alive, charged against the analyzer's
    /// retention budget.
    ///
    /// Flat, and it stays flat only because every stored property is a scalar
    /// summary. Anything row-proportional added here has to be charged for, or
    /// the cache will admit more than the host asked for.
    var estimatedRetainedCost: Int { 192 }

    /// Creates a column profile.
    ///
    /// Profiles are ordinarily produced by analysis. This initializer exists so
    /// a host can build one directly — a test double, or a profile computed
    /// elsewhere. The counts are not cross-checked against each other or
    /// against `column`, so a profile is only as coherent as its arguments.
    public init(
        column: AutoChartColumn,
        semanticType: AutoChartSemanticType,
        nonNullCount: Int,
        numericTypeCount: Int = 0,
        numericValueCount: Int = 0,
        renderableValueCount: Int,
        renderableDistinctCount: Int,
        distinctCount: Int,
        numericMinimum: Double? = nil,
        numericMaximum: Double? = nil,
        allNumericValuesPositive: Bool = false,
        averageTextLength: Double = 0,
        temporalValueCount: Int = 0,
        temporalMinimum: Date? = nil,
        temporalMaximum: Date? = nil,
        nonFiniteDateCount: Int = 0
    ) {
        self.column = column
        self.semanticType = semanticType
        self.nonNullCount = nonNullCount
        self.numericTypeCount = numericTypeCount
        self.numericValueCount = numericValueCount
        self.renderableValueCount = renderableValueCount
        self.renderableDistinctCount = renderableDistinctCount
        self.distinctCount = distinctCount
        self.numericMinimum = numericMinimum
        self.numericMaximum = numericMaximum
        self.allNumericValuesPositive = allNumericValuesPositive
        self.averageTextLength = averageTextLength
        self.temporalValueCount = temporalValueCount
        self.temporalMinimum = temporalMinimum
        self.temporalMaximum = temporalMaximum
        self.nonFiniteDateCount = nonFiniteDateCount
    }

    public var isQuantitative: Bool { semanticType == .quantitative }
    public var isTemporal: Bool { semanticType == .temporal }
    public var hasNonFiniteNumericValues: Bool { numericValueCount != numericTypeCount }
    public var hasNonFiniteDateValues: Bool { nonFiniteDateCount > 0 }
    public var hasFiniteNumericSpan: Bool {
        guard let numericMinimum, let numericMaximum else { return true }
        return (numericMaximum - numericMinimum).isFinite
    }
    public var hasFiniteTemporalSpan: Bool {
        guard let temporalMinimum, let temporalMaximum else {
            return true
        }
        return temporalMaximum.timeIntervalSince(temporalMinimum).isFinite
    }
    /// Whether every renderable value is distinct, so marks keyed by this column
    /// alone can't collide. Recommendation and validation share this rule so they
    /// can't disagree about whether an aggregation is required.
    public var isUniqueAtRowGrain: Bool { renderableDistinctCount == renderableValueCount }
    public var isCategorical: Bool {
        semanticType == .nominal || semanticType == .ordinal
            || semanticType == .boolean
    }
}

enum AutoChartProfiler {
    static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func profiles(_ snapshot: AutoChartSnapshot) -> [AutoChartColumnProfile] {
        snapshot.columns.enumerated().map { columnIndex, column in
            profile(column, columnIndex: columnIndex, rows: snapshot.rows)
        }
    }

    static func profileIndex(
        _ profiles: [AutoChartColumnProfile]
    ) -> [AutoChartColumnID: AutoChartColumnProfile] {
        Dictionary(
            profiles.map { ($0.column.id, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    static func profileIndex(
        _ snapshot: AutoChartSnapshot
    ) -> [AutoChartColumnID: AutoChartColumnProfile] {
        profileIndex(profiles(snapshot))
    }

    static func profileIndexCheckingCancellation(
        _ snapshot: AutoChartSnapshot
    ) throws -> [AutoChartColumnID: AutoChartColumnProfile] {
        var profiles: [AutoChartColumnProfile] = []
        profiles.reserveCapacity(snapshot.columns.count)
        for (columnIndex, column) in snapshot.columns.enumerated() {
            try Task.checkCancellation()
            profiles.append(
                try profile(
                    column,
                    columnIndex: columnIndex,
                    rows: snapshot.rows,
                    checkingCancellation: true))
        }
        return profileIndex(profiles)
    }

    static func profile(
        _ column: AutoChartColumn,
        columnIndex: Int,
        rows: [AutoChartSnapshot.Row]
    ) -> AutoChartColumnProfile {
        // The nonthrowing entry point is retained for synchronous validation
        // helpers and tests. Analyzer work uses the cancellable variant below.
        let values = rows.map { $0.values[columnIndex] }
        return makeProfile(column, values: values) { values, semanticType in
            identitySummary(values, semanticType: semanticType)
        }
    }

    private static func profile(
        _ column: AutoChartColumn,
        columnIndex: Int,
        rows: [AutoChartSnapshot.Row],
        checkingCancellation: Bool
    ) throws -> AutoChartColumnProfile {
        var values: [AutoChartValue] = []
        values.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if checkingCancellation, index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            values.append(row.values[columnIndex])
        }
        try Task.checkCancellation()
        return try makeProfile(column, values: values) { values, semanticType in
            try identitySummaryCheckingCancellation(
                values,
                semanticType: semanticType)
        }
    }

    private static func makeProfile(
        _ column: AutoChartColumn,
        values: [AutoChartValue],
        summarize: ([AutoChartValue], AutoChartSemanticType?) throws -> IdentitySummary
    ) rethrows -> AutoChartColumnProfile {
        let nonNull = values.filter {
            if case .null = $0 { return false }
            return true
        }
        let numericTyped = nonNull.filter { value in
            switch value {
            case .integer, .double, .decimal:
                true
            default:
                false
            }
        }
        let numeric = nonNull.compactMap(\.numericValue)
        var temporalValueCount = 0
        var temporalMinimum: Date?
        var temporalMaximum: Date?
        var nonFiniteDateCount = 0
        for value in nonNull {
            if case .date(let date) = value,
                !date.timeIntervalSinceReferenceDate.isFinite
            {
                nonFiniteDateCount += 1
                continue
            }
            guard let date = dateValue(value) else { continue }
            temporalValueCount += 1
            temporalMinimum = min(temporalMinimum ?? date, date)
            temporalMaximum = max(temporalMaximum ?? date, date)
        }
        let textLengths = nonNull.compactMap { value -> Int? in
            if case .text(let text) = value { return text.count }
            return nil
        }
        let raw = try summarize(values, nil)
        let type = inferredSemanticType(
            column: column,
            values: nonNull,
            numericTypeCount: numericTyped.count,
            numericCount: numeric.count,
            temporalTypeCount: temporalValueCount + nonFiniteDateCount,
            distinctCount: raw.distinct.count)
        let renderable =
            resolvesToRawIdentity(type)
            ? raw
            : try summarize(values, type)
        return AutoChartColumnProfile(
            column: column,
            semanticType: type,
            nonNullCount: nonNull.count,
            numericTypeCount: numericTyped.count,
            numericValueCount: numeric.count,
            renderableValueCount: renderable.valueCount,
            renderableDistinctCount: renderable.distinct.count,
            distinctCount: raw.distinct.count,
            numericMinimum: numeric.min(),
            numericMaximum: numeric.max(),
            allNumericValuesPositive: !numeric.isEmpty
                && numeric.count == nonNull.count
                && numeric.allSatisfy { $0 > 0 },
            averageTextLength: textLengths.isEmpty
                ? 0 : Double(textLengths.reduce(0, +)) / Double(textLengths.count),
            temporalValueCount: temporalValueCount,
            temporalMinimum: temporalMinimum,
            temporalMaximum: temporalMaximum,
            nonFiniteDateCount: nonFiniteDateCount)
    }

    /// The renderable values of a column, counted and deduplicated in one pass.
    private struct IdentitySummary {
        var valueCount = 0
        var distinct: Set<AutoChartValueIdentity> = []
    }

    private static func identitySummary(
        _ values: [AutoChartValue],
        semanticType: AutoChartSemanticType?
    ) -> IdentitySummary {
        var summary = IdentitySummary()
        for value in values {
            let identity = identity(value, semanticType: semanticType)
            guard identity != .missing else { continue }
            summary.valueCount += 1
            summary.distinct.insert(identity)
        }
        return summary
    }

    private static func identitySummaryCheckingCancellation(
        _ values: [AutoChartValue],
        semanticType: AutoChartSemanticType?
    ) throws -> IdentitySummary {
        var summary = IdentitySummary()
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let identity = identity(value, semanticType: semanticType)
            guard identity != .missing else { continue }
            summary.valueCount += 1
            summary.distinct.insert(identity)
        }
        return summary
    }

    /// Whether ``identity(_:semanticType:)`` ignores this semantic type, so the
    /// identities gathered while inferring it can stand in for the renderable ones.
    private static func resolvesToRawIdentity(_ type: AutoChartSemanticType) -> Bool {
        switch type {
        case .quantitative, .temporal, .ordinal, .boolean: false
        case .nominal, .identifier, .unsupported: true
        }
    }

    private static func inferredSemanticType(
        column: AutoChartColumn,
        values: [AutoChartValue],
        numericTypeCount: Int,
        numericCount: Int,
        temporalTypeCount: Int,
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
        if temporalTypeCount == values.count {
            return .temporal
        }
        if numericTypeCount == values.count {
            if numericCount == values.count,
                nameTokens.contains("year"), distinctCount <= 100,
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
        case .date(let date):
            date.timeIntervalSinceReferenceDate.isFinite ? date : nil
        case .text(let text): parseISODate(text)
        default: nil
        }
    }

    static func parseISODate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let year = decimalInteger(parts[0], digitCount: 4),
            (1...9_999).contains(year),
            let month = decimalInteger(parts[1], digitCount: 2),
            let day = decimalInteger(parts[2], digitCount: 2),
            (1...12).contains(month),
            (1...31).contains(day)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func decimalInteger(_ component: Substring, digitCount: Int) -> Int? {
        guard component.utf8.count == digitCount,
            component.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return Int(component)
    }

    static func identity(
        _ value: AutoChartValue?,
        semanticType: AutoChartSemanticType?
    ) -> AutoChartValueIdentity {
        guard let value else { return .missing }
        switch semanticType {
        case .temporal:
            guard let date = dateValue(value) else { return .missing }
            return dateIdentity(date)
        case .quantitative:
            guard let number = value.numericValue else { return .missing }
            return numberIdentity(number)
        case .ordinal, .boolean:
            // Categorical numeric identities must remain exact. Passing an
            // Int64 or Decimal through Double would merge distinct values once
            // they exceed binary floating-point precision.
            if let identity = exactNumberIdentity(value) { return identity }
        case .nominal, .identifier, .unsupported, nil:
            break
        }
        switch value {
        case .null, .binary:
            return .missing
        case .boolean(let value):
            return .boolean(value)
        case .integer(let value):
            return .integer(value)
        case .double(let value):
            guard value.isFinite else { return .missing }
            let normalized = value == 0 ? 0.0 : value
            return .double(normalized.bitPattern)
        case .decimal(let value):
            guard let canonical = decimalString(value) else { return .missing }
            return .decimal(canonical)
        case .text(let value):
            return .text(value)
        case .date(let value):
            return dateIdentity(value)
        }
    }

    /// The identity of a date, or `.missing` when its interval isn't finite and
    /// so can't position a mark or bound an axis.
    private static func dateIdentity(_ date: Date) -> AutoChartValueIdentity {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return .missing }
        return .date(dateBits(date))
    }

    private static func numberIdentity(_ number: Double) -> AutoChartValueIdentity {
        .number((number == 0 ? 0.0 : number).bitPattern)
    }

    /// A lossless semantic identity for one finite numeric source value.
    ///
    /// Equal values represented as `Int64`, `Double`, or `Decimal` share an
    /// identity when their exact decimal values agree. A finite `Double` that
    /// Foundation `Decimal` cannot preserve falls back to its normalized bit
    /// pattern instead of disappearing from a distinct-value aggregation.
    static func exactNumericIdentity(
        _ value: AutoChartValue?
    ) -> AutoChartValueIdentity? {
        guard let value, value.numericValue != nil else { return nil }
        return identity(value, semanticType: .ordinal)
    }

    /// A canonical, lossless identity for a numeric category.
    ///
    /// Finite Doubles use their exact decimal value when Foundation's Decimal can
    /// preserve it. Other Doubles retain their normalized bit pattern instead of
    /// being merged with a nearby integer or decimal that rounds to the same Double.
    private static func exactNumberIdentity(
        _ value: AutoChartValue
    ) -> AutoChartValueIdentity? {
        switch value {
        case .integer(let value):
            return canonicalDecimalIdentity(String(value)).map(
                AutoChartValueIdentity.exactNumber)
        case .double(let value):
            guard value.isFinite else { return nil }
            let normalized = value == 0 ? 0.0 : value
            return exactDecimalIdentity(normalized).map(AutoChartValueIdentity.exactNumber)
        case .decimal(let value):
            guard let text = decimalString(value) else { return nil }
            return canonicalDecimalIdentity(text).map(AutoChartValueIdentity.exactNumber)
        default:
            return nil
        }
    }

    /// Returns an exact, normalized decimal identity for a Double when it fits
    /// Foundation Decimal's 38 significant digits.
    private static func exactDecimalIdentity(_ value: Double) -> String? {
        if value == 0 { return "0e0" }
        if let integer = Int64(exactly: value) {
            return canonicalDecimalIdentity(String(integer))
        }

        let bits = value.bitPattern
        let isNegative = bits >> 63 == 1
        let exponentBits = Int((bits >> 52) & 0x7ff)
        let fraction = bits & ((UInt64(1) << 52) - 1)
        var significand: UInt64
        var binaryExponent: Int
        if exponentBits == 0 {
            significand = fraction
            binaryExponent = -1_074
        } else {
            significand = (UInt64(1) << 52) | fraction
            binaryExponent = exponentBits - 1_023 - 52
        }
        while significand.isMultiple(of: 2) {
            significand /= 2
            binaryExponent += 1
        }

        var coefficient: String
        var decimalExponent: Int
        if binaryExponent >= 0 {
            var decimalZeroCount = 0
            while decimalZeroCount < binaryExponent, significand.isMultiple(of: 5) {
                significand /= 5
                decimalZeroCount += 1
            }
            let remainingPower = binaryExponent - decimalZeroCount
            guard let product = decimalProduct(
                String(significand), multiplier: 2, power: remainingPower)
            else { return nil }
            coefficient = product
            decimalExponent = decimalZeroCount
        } else {
            let denominatorPower = -binaryExponent
            guard let product = decimalProduct(
                String(significand), multiplier: 5, power: denominatorPower)
            else { return nil }
            coefficient = product
            decimalExponent = -denominatorPower
        }
        if isNegative { coefficient.insert("-", at: coefficient.startIndex) }

        let identity = "\(coefficient)e\(decimalExponent)"
        guard let decimal = Decimal(string: identity, locale: posixLocale),
            canonicalDecimalIdentity(NSDecimalNumber(decimal: decimal).stringValue) == identity
        else { return nil }
        return identity
    }

    private static func decimalProduct(
        _ value: String,
        multiplier: Int,
        power: Int
    ) -> String? {
        var digits = value.utf8.map { Int($0 - 48) }
        for _ in 0..<power {
            var carry = 0
            for index in digits.indices.reversed() {
                let product = digits[index] * multiplier + carry
                digits[index] = product % 10
                carry = product / 10
            }
            while carry > 0 {
                digits.insert(carry % 10, at: 0)
                carry /= 10
            }
            guard digits.count <= 38 else { return nil }
        }
        return String(digits.map { Character(String($0)) })
    }

    private static func decimalString(_ value: Decimal) -> String? {
        let number = NSDecimalNumber(decimal: value)
        guard number.doubleValue.isFinite else { return nil }
        return number.stringValue
    }

    private static func canonicalDecimalIdentity(_ text: String) -> String? {
        let components = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "e" || $0 == "E" })
        guard components.count <= 2,
            let explicitExponent = components.count == 2 ? Int(components[1]) : 0
        else { return nil }

        var mantissa = String(components[0])
        let isNegative = mantissa.first == "-"
        if isNegative { mantissa.removeFirst() }
        let decimalParts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimalParts.count <= 2 else { return nil }
        let fractionalCount = decimalParts.count == 2 ? decimalParts[1].utf8.count : 0
        var digits = decimalParts.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        while digits.first == "0" { digits.removeFirst() }
        guard !digits.isEmpty else { return "0e0" }

        var exponent = explicitExponent - fractionalCount
        while digits.last == "0" {
            digits.removeLast()
            exponent += 1
        }
        return "\(isNegative ? "-" : "")\(digits)e\(exponent)"
    }

    static func identityString(
        _ value: AutoChartValue?,
        semanticType: AutoChartSemanticType?
    ) -> String? {
        identity(value, semanticType: semanticType).stringValue
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
                if lower == "id" {
                    return lower.uppercased()
                }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    static func displayName(_ column: AutoChartColumn) -> String {
        if let override = column.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return override
        }
        return humanized(column.name)
    }
}

enum AutoChartValueIdentity: Hashable, Sendable {
    case missing
    case boolean(Bool)
    case integer(Int64)
    case number(UInt64)
    case exactNumber(String)
    case double(UInt64)
    case decimal(String)
    case text(String)
    case date(UInt64)

    var stringValue: String? {
        switch self {
        case .missing:
            nil
        case .boolean(let value):
            value ? "boolean:1" : "boolean:0"
        case .integer(let value):
            "integer:\(value)"
        case .number(let value):
            "number:\(value)"
        case .exactNumber(let value):
            "exact-number:\(value.utf8.count):\(value)"
        case .double(let value):
            "double:\(value)"
        case .decimal(let value):
            "decimal:\(value)"
        case .text(let value):
            "text:\(value.utf8.count):\(value)"
        case .date(let value):
            "date:\(value)"
        }
    }

    /// The normalized value represented by a renderable category identity.
    /// Canonical decimal parsing is an internal invariant; retain the canonical
    /// digits as text in release builds rather than mislabeling a real category
    /// with the missing-value placeholder.
    var categoryValue: AutoChartValue? {
        switch self {
        case .missing:
            return nil
        case .boolean(let value):
            return .boolean(value)
        case .integer(let value):
            return .integer(value)
        case .number(let bits), .double(let bits):
            return .double(Double(bitPattern: bits))
        case .exactNumber(let canonical), .decimal(let canonical):
            guard let value = Decimal(
                string: canonical,
                locale: AutoChartProfiler.posixLocale)
            else {
                assertionFailure("A numeric identity must contain a canonical decimal.")
                return .text(canonical)
            }
            return .decimal(value)
        case .text(let value):
            return .text(value)
        case .date(let bits):
            return .date(
                Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)))
        }
    }
}

extension AutoChartValue {
    private static func conciseCategoryNumber(
        _ value: Double,
        locale: Locale
    ) -> String {
        guard value.isFinite else { return unrepresentableValuePlaceholder }
        let standard = value.formatted(
            .number.locale(locale).grouping(.never)
                .precision(.significantDigits(1...17)))
        return AutoChartCategoryNumberPolicy.concise(
            standard: standard,
            scientific: value.formatted(
                .number.locale(locale).notation(.scientific)
                    .precision(.significantDigits(1...17))))
    }

    private static func conciseCategoryNumber(
        _ value: Decimal,
        locale: Locale
    ) -> String {
        guard !value.isNaN else { return unrepresentableValuePlaceholder }
        let standard = value.formatted(
            .number.locale(locale).grouping(.never)
                .precision(.significantDigits(1...38)))
        return AutoChartCategoryNumberPolicy.concise(
            standard: standard,
            scientific: value.formatted(
                .number.locale(locale).notation(.scientific)
                    .precision(.significantDigits(1...38))))
    }

    /// A deterministic category label. Presentation code supplies the chart's
    /// locale and time zone; preparation uses POSIX/GMT defaults so cached data
    /// does not depend on the process locale.
    func categoryString(
        locale: Locale = AutoChartProfiler.posixLocale,
        timeZone: TimeZone = .gmt,
        datePrecision: AutoChartDateLabelPrecision? = nil,
        calendar: Calendar? = nil
    ) -> String? {
        switch self {
        case .null, .binary:
            return nil
        case .integer(let value):
            return value.formatted(.number.locale(locale).grouping(.never))
        case .double(let value):
            return Self.conciseCategoryNumber(value, locale: locale)
        case .decimal(let value):
            return Self.conciseCategoryNumber(value, locale: locale)
        case .date(let value):
            return AutoChartDateFormatting.string(
                value,
                locale: locale,
                timeZone: timeZone,
                precision: datePrecision,
                calendar: calendar)
        default:
            return displayString
        }
    }
}
