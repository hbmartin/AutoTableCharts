import Foundation

/// One type-erased domain-record column used by ``AutoChartDatasetBuilder``.
public struct AutoChartDomainColumn<Record: Sendable>: Sendable {
    public let column: AutoChartColumn
    let value: @Sendable (Record) -> AutoChartValue

    public init<Value: AutoChartValueConvertible>(
        id: AutoChartColumnID,
        name: String,
        displayName: String? = nil,
        semantics: AutoChartColumnSemantics,
        value: @escaping @Sendable (Record) -> Value
    ) {
        self.column = AutoChartColumn(
            id: id, name: name, displayName: displayName, semantics: semantics)
        self.value = { value($0).autoChartValue }
    }
}

/// Declares a categorical or temporal dimension from a domain record.
public struct Dimension<Record: Sendable>: Sendable {
    let columns: [AutoChartDomainColumn<Record>]

    public init<Value: AutoChartValueConvertible>(
        _ id: AutoChartColumnID,
        name: String,
        displayName: String? = nil,
        role: AutoChartColumnSemantics.DimensionRole = .dimension,
        semanticType: AutoChartSemanticType? = nil,
        unit: AutoChartUnit? = nil,
        grain: String? = nil,
        value: @escaping @Sendable (Record) -> Value
    ) {
        columns = [
            AutoChartDomainColumn(
                id: id,
                name: name,
                displayName: displayName,
                semantics: .dimension(
                    role: role, semanticType: semanticType, unit: unit, grain: grain),
                value: value)
        ]
    }
}

/// Declares a quantitative measure and its rollup semantics.
public struct Measure<Record: Sendable>: Sendable {
    let columns: [AutoChartDomainColumn<Record>]

    public init<Value: AutoChartValueConvertible>(
        _ id: AutoChartColumnID,
        name: String,
        displayName: String? = nil,
        semanticType: AutoChartSemanticType? = .quantitative,
        unit: AutoChartUnit? = nil,
        semantics: AutoChartMeasureSemantics = .init(),
        grain: String? = nil,
        value: @escaping @Sendable (Record) -> Value
    ) {
        columns = [
            AutoChartDomainColumn(
                id: id,
                name: name,
                displayName: displayName,
                semantics: .measure(
                    semanticType: semanticType,
                    unit: unit,
                    semantics: semantics,
                    grain: grain),
                value: value)
        ]
    }
}

/// Declares a record identifier that recommendation will never treat as a measure.
public struct Identifier<Record: Sendable>: Sendable {
    let columns: [AutoChartDomainColumn<Record>]

    public init<Value: AutoChartValueConvertible>(
        _ id: AutoChartColumnID,
        name: String,
        displayName: String? = nil,
        semanticType: AutoChartSemanticType? = nil,
        value: @escaping @Sendable (Record) -> Value
    ) {
        columns = [
            AutoChartDomainColumn(
                id: id,
                name: name,
                displayName: displayName,
                semantics: .identifier(semanticType: semanticType),
                value: value)
        ]
    }
}

/// Declares paired start and end columns for one temporal interval.
public struct Interval<Record: Sendable>: Sendable {
    let columns: [AutoChartDomainColumn<Record>]

    public init<Start: AutoChartValueConvertible, End: AutoChartValueConvertible>(
        startID: AutoChartColumnID,
        startName: String,
        endID: AutoChartColumnID,
        endName: String,
        startDisplayName: String? = nil,
        endDisplayName: String? = nil,
        grain: String? = nil,
        start: @escaping @Sendable (Record) -> Start,
        end: @escaping @Sendable (Record) -> End
    ) {
        columns = [
            AutoChartDomainColumn(
                id: startID,
                name: startName,
                displayName: startDisplayName,
                semantics: .intervalStart(grain: grain),
                value: start),
            AutoChartDomainColumn(
                id: endID,
                name: endName,
                displayName: endDisplayName,
                semantics: .intervalEnd(grain: grain),
                value: end),
        ]
    }
}

/// Builds a safe column schema from domain-record declarations.
@resultBuilder
public enum AutoChartDatasetBuilder<Record: Sendable> {
    public static func buildExpression(
        _ expression: AutoChartDomainColumn<Record>
    ) -> [AutoChartDomainColumn<Record>] { [expression] }

    public static func buildExpression(
        _ expression: Dimension<Record>
    ) -> [AutoChartDomainColumn<Record>] { expression.columns }

    public static func buildExpression(
        _ expression: Measure<Record>
    ) -> [AutoChartDomainColumn<Record>] { expression.columns }

    public static func buildExpression(
        _ expression: Identifier<Record>
    ) -> [AutoChartDomainColumn<Record>] { expression.columns }

    public static func buildExpression(
        _ expression: Interval<Record>
    ) -> [AutoChartDomainColumn<Record>] { expression.columns }

    public static func buildBlock(
        _ components: [AutoChartDomainColumn<Record>]...
    ) -> [AutoChartDomainColumn<Record>] { components.flatMap { $0 } }

    public static func buildOptional(
        _ component: [AutoChartDomainColumn<Record>]?
    ) -> [AutoChartDomainColumn<Record>] { component ?? [] }

    public static func buildEither(
        first component: [AutoChartDomainColumn<Record>]
    ) -> [AutoChartDomainColumn<Record>] { component }

    public static func buildEither(
        second component: [AutoChartDomainColumn<Record>]
    ) -> [AutoChartDomainColumn<Record>] { component }

    public static func buildArray(
        _ components: [[AutoChartDomainColumn<Record>]]
    ) -> [AutoChartDomainColumn<Record>] { components.flatMap { $0 } }
}

extension AutoChartDataset {
    /// Creates a chart dataset directly from typed domain records.
    public init<Record: Sendable>(
        records: [Record],
        rowID: KeyPath<Record, RowID>,
        metadata: AutoChartTableMetadata = .init(),
        key: AutoChartDataKey = .contentAddressed(),
        @AutoChartDatasetBuilder<Record> columns: () -> [AutoChartDomainColumn<Record>]
    ) throws {
        let declarations = columns()
        try self.init(
            columns: declarations.map(\.column),
            rows: records.map { record in
                declarations.map { $0.value(record) }
            },
            rowIDs: records.map { $0[keyPath: rowID] },
            metadata: metadata,
            key: key)
    }
}
