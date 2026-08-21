import Foundation

/// A structural problem that prevents a matrix from becoming chart data.
public struct AutoChartDatasetError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Code: String, Hashable, Codable, Sendable {
        case rowWidthMismatch
        case rowIDCountMismatch
        case duplicateColumnID
        case duplicateRowID
    }

    public let code: Code
    public let rowIndex: Int?
    public let expectedCount: Int?
    public let actualCount: Int?
    public let identifier: String?

    public init(
        code: Code,
        rowIndex: Int? = nil,
        expectedCount: Int? = nil,
        actualCount: Int? = nil,
        identifier: String? = nil
    ) {
        self.code = code
        self.rowIndex = rowIndex
        self.expectedCount = expectedCount
        self.actualCount = actualCount
        self.identifier = identifier
    }

    public var description: String {
        switch code {
        case .rowWidthMismatch:
            "Row \(rowIndex ?? 0) has \(actualCount ?? 0) values; expected \(expectedCount ?? 0)."
        case .rowIDCountMismatch:
            "The dataset has \(actualCount ?? 0) row IDs; expected \(expectedCount ?? 0)."
        case .duplicateColumnID:
            "Duplicate column ID \(identifier ?? "<unknown>")."
        case .duplicateRowID:
            "Duplicate row ID \(identifier ?? "<unknown>")."
        }
    }
}

final class AutoChartMatrixStorage: @unchecked Sendable {
    let columns: [AutoChartColumn]
    let values: [AutoChartValue]
    let rowCount: Int
    let metadata: AutoChartTableMetadata
    let columnIndexes: [AutoChartColumnID: Int]

    init(
        columns: [AutoChartColumn],
        values: [AutoChartValue],
        rowCount: Int,
        metadata: AutoChartTableMetadata
    ) {
        self.columns = columns
        self.values = values
        self.rowCount = rowCount
        self.metadata = metadata
        self.columnIndexes = Dictionary(
            uniqueKeysWithValues: columns.enumerated().map { ($0.element.id, $0.offset) })
    }

    func value(row: Int, columnID: AutoChartColumnID) -> AutoChartValue {
        guard let column = columnIndexes[columnID],
            row >= 0, row < rowCount
        else { return .null }
        return values[row * columns.count + column]
    }
}

protocol AutoChartDatasetStorageProviding {
    var _autoChartMatrixStorage: AutoChartMatrixStorage { get }
    var _autoChartErasedRowIDs: [AutoChartErasedRowID] { get }
}

/// An immutable, compact, row-major implementation of ``AutoChartTable``.
public struct AutoChartDataset<RowID: Hashable & Sendable>: AutoChartTable, Sendable {
    public struct Row: AutoChartRow, Sendable {
        public let chartRowID: RowID
        fileprivate let rowIndex: Int
        fileprivate let storage: AutoChartMatrixStorage

        public func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
            storage.value(row: rowIndex, columnID: columnID)
        }
    }

    private let storage: AutoChartMatrixStorage
    private let rows: [Row]
    public let chartDataKey: AutoChartDataKey?

    public var chartColumns: [AutoChartColumn] { storage.columns }
    public var chartRows: [Row] { rows }
    public var chartMetadata: AutoChartTableMetadata { storage.metadata }

    /// Creates a dataset from fully described columns and explicit row IDs.
    public init(
        columns: [AutoChartColumn],
        rows matrix: [[AutoChartValue]],
        rowIDs: [RowID],
        metadata: AutoChartTableMetadata = .init(),
        key: AutoChartDataKey? = nil
    ) throws {
        guard rowIDs.count == matrix.count else {
            throw AutoChartDatasetError(
                code: .rowIDCountMismatch,
                expectedCount: matrix.count,
                actualCount: rowIDs.count)
        }
        var seenColumns: Set<AutoChartColumnID> = []
        for column in columns where !seenColumns.insert(column.id).inserted {
            throw AutoChartDatasetError(
                code: .duplicateColumnID,
                identifier: column.id.rawValue)
        }
        var seenRows: Set<RowID> = []
        for rowID in rowIDs where !seenRows.insert(rowID).inserted {
            throw AutoChartDatasetError(
                code: .duplicateRowID,
                identifier: String(describing: rowID))
        }
        var flat: [AutoChartValue] = []
        flat.reserveCapacity(matrix.count * columns.count)
        for (index, row) in matrix.enumerated() {
            guard row.count == columns.count else {
                throw AutoChartDatasetError(
                    code: .rowWidthMismatch,
                    rowIndex: index,
                    expectedCount: columns.count,
                    actualCount: row.count)
            }
            flat.append(contentsOf: row)
        }
        let storage = AutoChartMatrixStorage(
            columns: columns,
            values: flat,
            rowCount: matrix.count,
            metadata: metadata)
        self.storage = storage
        self.rows = rowIDs.enumerated().map {
            Row(chartRowID: $0.element, rowIndex: $0.offset, storage: storage)
        }
        self.chartDataKey = key
    }

    /// Creates columns from source names while keeping host hint logic outside the package.
    public init(
        columnNames: [String],
        rows: [[AutoChartValue]],
        rowIDs: [RowID],
        metadata: AutoChartTableMetadata = .init(),
        key: AutoChartDataKey? = nil,
        columnID: (Int, String) -> AutoChartColumnID = { index, _ in
            AutoChartColumnID(rawValue: "column-\(index)")
        },
        hints: (Int, String) -> AutoChartColumnHints = { _, _ in .init() }
    ) throws {
        try self.init(
            columns: columnNames.enumerated().map { index, name in
                AutoChartColumn(
                    id: columnID(index, name),
                    name: name,
                    hints: hints(index, name))
            },
            rows: rows,
            rowIDs: rowIDs,
            metadata: metadata,
            key: key)
    }
}

extension AutoChartDataset where RowID == Int {
    /// Creates a dataset whose typed row IDs are the source matrix offsets.
    public init(
        columns: [AutoChartColumn],
        rows: [[AutoChartValue]],
        metadata: AutoChartTableMetadata = .init(),
        key: AutoChartDataKey? = nil
    ) throws {
        try self.init(
            columns: columns,
            rows: rows,
            rowIDs: Array(rows.indices),
            metadata: metadata,
            key: key)
    }

    /// Creates named columns and offset row IDs.
    public init(
        columnNames: [String],
        rows: [[AutoChartValue]],
        metadata: AutoChartTableMetadata = .init(),
        key: AutoChartDataKey? = nil,
        columnID: (Int, String) -> AutoChartColumnID = { index, _ in
            AutoChartColumnID(rawValue: "column-\(index)")
        },
        hints: (Int, String) -> AutoChartColumnHints = { _, _ in .init() }
    ) throws {
        try self.init(
            columnNames: columnNames,
            rows: rows,
            rowIDs: Array(rows.indices),
            metadata: metadata,
            key: key,
            columnID: columnID,
            hints: hints)
    }
}

extension AutoChartDataset: AutoChartDatasetStorageProviding {
    var _autoChartMatrixStorage: AutoChartMatrixStorage { storage }
    var _autoChartErasedRowIDs: [AutoChartErasedRowID] {
        rows.map { AutoChartErasedRowID($0.chartRowID) }
    }
}

extension AutoChartDataset: Codable where RowID: Codable {
    private enum CodingKeys: String, CodingKey {
        case columns, rows, rowIDs, metadata, key
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            columns: values.decode([AutoChartColumn].self, forKey: .columns),
            rows: values.decode([[AutoChartValue]].self, forKey: .rows),
            rowIDs: values.decode([RowID].self, forKey: .rowIDs),
            metadata: values.decode(AutoChartTableMetadata.self, forKey: .metadata),
            key: values.decodeIfPresent(AutoChartDataKey.self, forKey: .key))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let matrix = (0..<storage.rowCount).map { rowIndex in
            storage.columns.map { storage.value(row: rowIndex, columnID: $0.id) }
        }
        try values.encode(storage.columns, forKey: .columns)
        try values.encode(matrix, forKey: .rows)
        try values.encode(rows.map(\.chartRowID), forKey: .rowIDs)
        try values.encode(storage.metadata, forKey: .metadata)
        try values.encodeIfPresent(chartDataKey, forKey: .key)
    }
}
