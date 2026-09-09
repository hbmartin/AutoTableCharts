import Foundation

private struct AutoChartSelectionProvenance: Hashable {
    var analysisID: AutoChartAnalysisID
    var preparedChartID: AutoChartPreparedChartID
}

/// An ordered, provenance-safe collection of selections from one prepared chart.
public struct AutoChartSelectionSet<RowID: Hashable & Sendable>: Hashable, Sendable,
    RandomAccessCollection
{
    public typealias Index = Int
    public typealias Element = AutoChartSelection<RowID>

    private var storage: [AutoChartSelection<RowID>]

    public init() { storage = [] }

    /// Creates a set from the largest compatible provenance cohort.
    ///
    /// Selections from another analysis or prepared chart are ignored rather
    /// than trapping a host process that is reconciling stale external state.
    /// The earliest cohort wins when multiple cohorts contain the same number
    /// of selections.
    public init(_ selections: [AutoChartSelection<RowID>]) {
        var selectedProvenance: AutoChartSelectionProvenance?
        var selectedCount = 0
        var markIDsByProvenance: [AutoChartSelectionProvenance: Set<String>] = [:]
        var provenanceOrder: [AutoChartSelectionProvenance] = []
        for selection in selections {
            let provenance = AutoChartSelectionProvenance(
                analysisID: selection.analysisID,
                preparedChartID: selection.preparedChartID)
            if markIDsByProvenance[provenance] == nil {
                provenanceOrder.append(provenance)
            }
            markIDsByProvenance[provenance, default: []].insert(selection.markID)
        }
        for provenance in provenanceOrder {
            let count = markIDsByProvenance[provenance, default: []].count
            if count > selectedCount {
                selectedProvenance = provenance
                selectedCount = count
            }
        }
        let compatibleSelections = selections.filter {
            AutoChartSelectionProvenance(
                analysisID: $0.analysisID,
                preparedChartID: $0.preparedChartID) == selectedProvenance
        }
        var seen: Set<String> = []
        storage = compatibleSelections.filter { seen.insert($0.markID).inserted }
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

    /// Replaces the set, or toggles a group as one interaction target.
    package mutating func select(
        _ selections: [AutoChartSelection<RowID>],
        togglingAsGroup: Bool
    ) {
        let group = Self(selections)
        guard !group.isEmpty else { return }
        guard togglingAsGroup else {
            storage = group.storage
            return
        }
        guard storage.isEmpty
            || (analysisID == group.analysisID && preparedChartID == group.preparedChartID)
        else {
            storage = group.storage
            return
        }
        let groupMarkIDs = Set(group.map(\.markID))
        if groupMarkIDs.allSatisfy({ contains(markID: $0) }) {
            storage.removeAll { groupMarkIDs.contains($0.markID) }
        } else {
            for selection in group where !contains(markID: selection.markID) {
                storage.append(selection)
            }
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
                    sourceRowIDs: matchingRows,
                    family: recommendation.specification.family,
                    specificationID: recommendation.specification.id,
                    markID: mark.identity)
            })
    }
}
