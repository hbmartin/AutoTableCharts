import Foundation

/// An ordered, provenance-safe collection of selections from one prepared chart.
public struct AutoChartSelectionSet<RowID: Hashable & Sendable>: Hashable, Sendable,
    RandomAccessCollection
{
    public typealias Index = Int
    public typealias Element = AutoChartSelection<RowID>

    private var storage: [AutoChartSelection<RowID>]

    public init() { storage = [] }

    public init(_ selections: [AutoChartSelection<RowID>]) {
        if let first = selections.first {
            precondition(
                selections.allSatisfy {
                    $0.analysisID == first.analysisID
                        && $0.preparedChartID == first.preparedChartID
                },
                "A selection set can contain selections from only one prepared chart.")
        }
        var seen: Set<String> = []
        storage = selections.filter { seen.insert($0.markID).inserted }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public subscript(position: Int) -> AutoChartSelection<RowID> { storage[position] }

    public var analysisID: AutoChartAnalysisID? { storage.first?.analysisID }
    public var preparedChartID: AutoChartPreparedChartID? { storage.first?.preparedChartID }
    public var unionedSourceRows: Set<RowID> {
        storage.reduce(into: []) { $0.formUnion($1.sourceRowIDs) }
    }

    public func contains(markID: String) -> Bool {
        storage.contains { $0.markID == markID }
    }

    public func contains(_ selection: AutoChartSelection<RowID>) -> Bool {
        storage.contains(selection)
    }

    public func belongs(to analysis: AutoChartAnalysis<RowID>) -> Bool {
        isEmpty || analysisID == analysis.id
    }

    public func belongs(to preparedChart: AutoChartPreparedChart<RowID>) -> Bool {
        isEmpty || preparedChartID == preparedChart.id
    }

    public func sourceRows(
        in preparedChart: AutoChartPreparedChart<RowID>
    ) -> Set<RowID> {
        belongs(to: preparedChart) ? unionedSourceRows : []
    }

    /// Replaces the set, or toggles a mark for Command-click behavior.
    public mutating func select(
        _ selection: AutoChartSelection<RowID>,
        toggling: Bool = false
    ) {
        guard toggling else {
            storage = [selection]
            return
        }
        guard storage.isEmpty
            || (storage[0].analysisID == selection.analysisID
                && storage[0].preparedChartID == selection.preparedChartID)
        else {
            storage = [selection]
            return
        }
        if let index = storage.firstIndex(where: { $0.markID == selection.markID }) {
            storage.remove(at: index)
        } else {
            storage.append(selection)
        }
    }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: false) }
}

extension AutoChartPreparedChart {
    /// Derives chart-mark selections from caller-owned source row identifiers.
    public func selections(
        for sourceRows: Set<RowID>,
        analysisID: AutoChartAnalysisID
    ) -> AutoChartSelectionSet<RowID> {
        AutoChartSelectionSet(
            marks.compactMap { mark in
                let matchingRows = mark.sourceRowIDs.intersection(sourceRows)
                guard !matchingRows.isEmpty else { return nil }
                return AutoChartSelection(
                    analysisID: analysisID,
                    preparedChartID: id,
                    sourceRowIDs: mark.sourceRowIDs,
                    family: recommendation.specification.family,
                    specificationID: recommendation.specification.id,
                    markID: mark.identity)
            })
    }
}
