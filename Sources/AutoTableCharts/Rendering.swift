import Foundation

#if canImport(Charts) && canImport(SwiftUI)
import Charts
import SwiftUI
#endif

struct AutoChartDatum: Identifiable, Sendable {
    var id: String
    var sourceRowIDs: Set<AutoChartRowID>
    var xIdentity: String? = nil
    var xLabel: String?
    var xNumber: Double?
    var xDate: Date?
    var yIdentity: String? = nil
    var yLabel: String?
    var yNumber: Double?
    var seriesIdentity: String? = nil
    var series: String?
    var size: Double?
    var facetIdentity: String? = nil
    var facet: String?
    var startDate: Date?
    var endDate: Date?
    var lower: Double?
    var quartile1: Double?
    var median: Double?
    var quartile3: Double?
    var upper: Double?

    var accessibilityLabel: String {
        let name =
            xDate?.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: .shortened,
                    timeZone: TimeZone.gmt)) ?? xLabel
            ?? xNumber?.formatted() ?? yLabel ?? "Value"
        return accessibilityLabel(name: name, series: series)
    }

    var intervalAccessibilityDescription: String? {
        guard let startDate else { return nil }
        let style = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            timeZone: TimeZone.gmt)
        let start = startDate.formatted(style)
        guard let endDate, endDate != startDate else { return "Date: \(start)" }
        return "From \(start) to \(endDate.formatted(style))"
    }

    func accessibilityLabel(
        name: String,
        context: [String?],
        valueDescription: String? = nil
    ) -> String {
        let valueDescription = valueDescription ??
            yNumber?.formatted(.number.precision(.fractionLength(0...3)))
            ?? median?.formatted(.number.precision(.fractionLength(0...3)))
        return ([name] + context + [valueDescription])
            .compactMap { component in
                guard let component, !component.isEmpty else { return nil }
                return component
            }
            .joined(separator: ", ")
    }

    func accessibilityLabel(
        name: String,
        series: String?,
        facet: String? = nil,
        valueDescription: String? = nil
    ) -> String {
        accessibilityLabel(
            name: name,
            context: [series, facet],
            valueDescription: valueDescription)
    }
}

enum AutoChartSelectionPreparation {
    static func angleMatch(
        to selectedAngle: Double,
        in candidates: [AutoChartDatum]
    ) -> AutoChartDatum? {
        guard selectedAngle.isFinite, selectedAngle >= 0 else { return nil }
        var cumulative = 0.0
        for datum in candidates {
            cumulative += datum.yNumber ?? 0
            if selectedAngle <= cumulative { return datum }
        }
        return nil
    }

    static func numberSelectionLabel(
        for matches: [AutoChartDatum],
        selectedNumber: Double,
        family: AutoChartFamily
    ) -> String {
        if family == .histogram,
            let range = matches.first?.xLabel,
            !range.isEmpty
        {
            return range
        }
        return selectedNumber.formatted()
    }

    static func nearestDateMatches(
        to selectedDate: Date,
        in candidates: [AutoChartDatum]
    ) -> [AutoChartDatum] {
        let eligible = candidates.compactMap { datum -> (AutoChartDatum, Date)? in
            guard !datum.sourceRowIDs.isEmpty, let xDate = datum.xDate else { return nil }
            return (datum, xDate)
        }
        guard
            let nearestDate = eligible.min(by: {
                abs($0.1.timeIntervalSince(selectedDate))
                    < abs($1.1.timeIntervalSince(selectedDate))
            })?.1
        else { return [] }
        return eligible.filter { $0.1 == nearestDate }.map(\.0)
    }

    static func nearestNumberMatches(
        to selectedNumber: Double,
        in candidates: [AutoChartDatum]
    ) -> [AutoChartDatum] {
        let eligible = candidates.compactMap { datum -> (AutoChartDatum, Double)? in
            guard !datum.sourceRowIDs.isEmpty, let xNumber = datum.xNumber else { return nil }
            return (datum, xNumber)
        }
        guard
            let nearestNumber = eligible.min(by: {
                abs($0.1 - selectedNumber) < abs($1.1 - selectedNumber)
            })?.1
        else { return [] }
        return eligible.filter { $0.1 == nearestNumber }.map(\.0)
    }

    static func valueDescription(
        for matches: [AutoChartDatum],
        aggregation: AutoChartAggregation
    ) -> String {
        let rowIDs = matches.reduce(into: Set<AutoChartRowID>()) {
            $0.formUnion($1.sourceRowIDs)
        }
        let numericMatches = matches.compactMap { datum -> (value: Double, weight: Int)? in
            guard let value = datum.yNumber else { return nil }
            return (value, datum.sourceRowIDs.count)
        }
        let combinedValue: Double? = {
            guard !numericMatches.isEmpty else { return nil }
            if numericMatches.count == 1 { return numericMatches[0].value }
            switch aggregation {
            case .sum, .count:
                return numericMatches.reduce(0) { $0 + $1.value }
            case .mean:
                let totalWeight = numericMatches.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else { return nil }
                return numericMatches.reduce(0) {
                    $0 + $1.value * Double($1.weight)
                } / Double(totalWeight)
            case .minimum:
                return numericMatches.map(\.value).min()
            case .maximum:
                return numericMatches.map(\.value).max()
            case .none, .countDistinct:
                return nil
            }
        }()
        let rowDescription =
            "\(rowIDs.count) source row\(rowIDs.count == 1 ? "" : "s")"
        if let combinedValue {
            return
                "\(combinedValue.formatted(.number.precision(.fractionLength(0...3)))) · \(rowDescription)"
        }
        if numericMatches.count > 1 {
            return "\(numericMatches.count) marks · \(rowDescription)"
        }
        return rowDescription
    }
}

enum AutoChartDataPreparation {
    static func data(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        let profiles = Dictionary(
            AutoChartProfiler.profiles(snapshot).map { ($0.column.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return data(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
    }

    static func data(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        switch specification.family {
        case .histogram:
            return histogram(snapshot: snapshot, specification: specification)
        case .boxPlot:
            return boxPlot(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        case .heatmap:
            return heatmap(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        case .donut:
            return grouped(
                snapshot: snapshot,
                specification: specification,
                profiles: profiles)
        default:
            if specification.aggregation != .none {
                return grouped(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles)
            }
            return sorted(
                raw(
                    snapshot: snapshot,
                    specification: specification,
                    profiles: profiles),
                specification: specification,
                profiles: profiles)
        }
    }

    private static func raw(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        let encoding = specification.encoding
        return snapshot.rows.enumerated().compactMap { index, row in
            let xValue = encoding.x.flatMap { row.values[$0] }
            let yValue = encoding.y.flatMap { row.values[$0] }
            let start = encoding.start.flatMap { row.values[$0] }
            let end = encoding.end.flatMap { row.values[$0] }
            if specification.family == .range {
                guard start.flatMap(AutoChartProfiler.dateValue) != nil,
                    end.flatMap(AutoChartProfiler.dateValue) != nil
                else { return nil }
            } else if specification.family != .table,
                specification.family != .kpi,
                let x = encoding.x
            {
                let isRenderable: Bool =
                    switch profiles[x]?.semanticType {
                    case .temporal:
                        xValue.flatMap(AutoChartProfiler.dateValue) != nil
                    case .quantitative:
                        xValue?.numericValue != nil
                    default: xValue?.categoryString() != nil
                    }
                guard isRenderable else { return nil }
            }
            if specification.family != .table,
                specification.family != .kpi,
                encoding.y != nil,
                yValue?.numericValue == nil
            {
                return nil
            }
            return AutoChartDatum(
                id: "row-\(index)-\(row.id.rawValue)",
                sourceRowIDs: [row.id],
                xIdentity: AutoChartProfiler.identityString(
                    xValue, semanticType: encoding.x.flatMap { profiles[$0]?.semanticType }),
                xLabel: xValue?.categoryString(),
                xNumber: xValue?.numericValue,
                xDate: xValue.flatMap(AutoChartProfiler.dateValue),
                yLabel: yValue?.categoryString(),
                yNumber: yValue?.numericValue,
                seriesIdentity: encoding.series.flatMap { id in
                    AutoChartProfiler.identityString(
                        row.values[id], semanticType: profiles[id]?.semanticType)
                },
                series: encoding.series.flatMap { row.values[$0]?.categoryString() },
                size: encoding.size.flatMap { row.values[$0]?.numericValue },
                facetIdentity: encoding.facet.flatMap { id in
                    AutoChartProfiler.identityString(
                        row.values[id], semanticType: profiles[id]?.semanticType)
                },
                facet: encoding.facet.flatMap { row.values[$0]?.categoryString() },
                startDate: start.flatMap(AutoChartProfiler.dateValue),
                endDate: end.flatMap(AutoChartProfiler.dateValue))
        }
    }

    private struct GroupKey: Hashable {
        var x: String
        var series: String
        var facet: String
    }

    private static func grouped(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        let rawData = raw(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let groups = Dictionary(grouping: rawData.enumerated()) { indexedDatum in
            let datum = indexedDatum.element
            return GroupKey(
                x: datum.xIdentity ?? "missing",
                series: datum.seriesIdentity ?? "missing",
                facet: datum.facetIdentity ?? "missing")
        }
        let aggregated = groups.sorted {
            $0.value[0].offset < $1.value[0].offset
        }.map { key, indexedGroup -> AutoChartDatum in
            let group = indexedGroup.map { $0.element }
            let values = group.compactMap { $0.yNumber }
            let aggregation = specification.aggregation
            let result: Double =
                switch aggregation {
                case .none, .sum: values.reduce(0, +)
                case .mean: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                case .minimum: values.min() ?? 0
                case .maximum: values.max() ?? 0
                case .count: Double(group.count)
                case .countDistinct: Double(Set(values).count)
                }
            let first = group[0]
            return AutoChartDatum(
                id: "group-\(first.id)",
                sourceRowIDs: group.reduce(into: []) {
                    $0.formUnion($1.sourceRowIDs)
                },
                xIdentity: first.xIdentity,
                xLabel: first.xLabel,
                xNumber: first.xNumber,
                xDate: first.xDate,
                yNumber: result,
                seriesIdentity: first.seriesIdentity,
                series: first.series,
                facetIdentity: first.facetIdentity,
                facet: first.facet)
        }
        return sorted(aggregated, specification: specification, profiles: profiles)
    }

    private static func histogram(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x else { return [] }
        let values = snapshot.rows.compactMap { row -> (Double, AutoChartRowID)? in
            guard let value = row.values[x]?.numericValue, value.isFinite else { return nil }
            return (value, row.id)
        }
        guard let minimum = values.map(\.0).min(), let maximum = values.map(\.0).max() else {
            return []
        }
        let count = min(1_000, max(1, specification.binCount ?? 10))
        let scale = maximum > minimum ? max(abs(minimum), abs(maximum)) : 1
        let scaledMinimum = minimum / scale
        let scaledMaximum = maximum / scale
        let scaledWidth =
            scaledMaximum > scaledMinimum
            ? (scaledMaximum - scaledMinimum) / Double(count) : 1
        var bins: [[(Double, AutoChartRowID)]] = Array(repeating: [], count: count)
        for value in values {
            let scaledValue = value.0 / scale
            let position = (scaledValue - scaledMinimum) / scaledWidth
            let rawIndex = position.isFinite ? Int(position.rounded(.down)) : 0
            bins[min(max(rawIndex, 0), count - 1)].append(value)
        }
        return bins.enumerated().map { index, bin in
            let scaledStart = scaledMinimum + Double(index) * scaledWidth
            let scaledEnd = scaledStart + scaledWidth
            let start = scaledStart * scale
            let end = scaledEnd * scale
            let midpoint = (scaledStart + scaledWidth / 2) * scale
            return AutoChartDatum(
                id: "bin-\(index)",
                sourceRowIDs: Set(bin.map(\.1)),
                xLabel:
                    "\(start.formatted(.number.precision(.fractionLength(0...2))))–\(end.formatted(.number.precision(.fractionLength(0...2))))",
                xNumber: midpoint,
                yNumber: Double(bin.count),
                lower: start,
                upper: end)
        }
    }

    private static func boxPlot(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let y = specification.encoding.y else { return [] }
        let x = specification.encoding.x
        struct BoxGroupKey: Hashable {
            var identity: String
            var label: String
        }
        let semanticType = x.flatMap { profiles[$0]?.semanticType }
        let grouped = Dictionary(grouping: snapshot.rows) { row in
            guard let x else {
                return BoxGroupKey(identity: "all", label: "All")
            }
            let value = row.values[x]
            return BoxGroupKey(
                identity: AutoChartProfiler.identityString(
                    value, semanticType: semanticType) ?? "missing",
                label: value?.categoryString() ?? "Missing value")
        }
        return grouped.compactMap { key, rows in
            let contributingValues = rows.compactMap { row -> (Double, AutoChartRowID)? in
                guard let value = row.values[y]?.numericValue else { return nil }
                return (value, row.id)
            }
            let sortedValues = contributingValues.map(\.0).sorted()
            guard !sortedValues.isEmpty else { return nil }
            func quantile(_ p: Double) -> Double {
                guard sortedValues.count > 1 else { return sortedValues[0] }
                let position = p * Double(sortedValues.count - 1)
                let lower = Int(position.rounded(.down))
                let upper = Int(position.rounded(.up))
                if lower == upper { return sortedValues[lower] }
                let fraction = position - Double(lower)
                return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
            }
            return AutoChartDatum(
                id: "box-\(key.identity)",
                sourceRowIDs: Set(contributingValues.map(\.1)),
                xIdentity: key.identity,
                xLabel: key.label,
                lower: sortedValues.first,
                quartile1: quantile(0.25),
                median: quantile(0.5),
                quartile3: quantile(0.75),
                upper: sortedValues.last)
        }.sorted {
            ($0.xLabel ?? "", $0.xIdentity ?? "")
                < ($1.xLabel ?? "", $1.xIdentity ?? "")
        }
    }

    private static func heatmap(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        guard let x = specification.encoding.x, let y = specification.encoding.y else {
            return []
        }
        struct Key: Hashable {
            var xIdentity: String
            var yIdentity: String
            var xLabel: String
            var yLabel: String
        }
        var groups: [Key: [AutoChartSnapshot.Row]] = [:]
        for row in snapshot.rows {
            guard let xLabel = row.values[x]?.categoryString(),
                let yLabel = row.values[y]?.categoryString(),
                let xIdentity = AutoChartProfiler.identityString(
                    row.values[x], semanticType: profiles[x]?.semanticType),
                let yIdentity = AutoChartProfiler.identityString(
                    row.values[y], semanticType: profiles[y]?.semanticType)
            else { continue }
            groups[
                Key(
                    xIdentity: xIdentity,
                    yIdentity: yIdentity,
                    xLabel: xLabel,
                    yLabel: yLabel),
                default: []
            ].append(row)
        }
        return groups.map { key, rows in
            AutoChartDatum(
                id:
                    "heat-\(key.xIdentity.utf8.count):\(key.xIdentity)\(key.yIdentity.utf8.count):\(key.yIdentity)",
                sourceRowIDs: Set(rows.map(\.id)),
                xIdentity: key.xIdentity,
                xLabel: key.xLabel,
                yIdentity: key.yIdentity,
                yLabel: key.yLabel,
                yNumber: Double(rows.count))
        }.sorted {
            ($0.xLabel ?? "", $0.yLabel ?? "", $0.xIdentity ?? "", $0.yIdentity ?? "")
                < ($1.xLabel ?? "", $1.yLabel ?? "", $1.xIdentity ?? "", $1.yIdentity ?? "")
        }
    }

    private static func sorted(
        _ data: [AutoChartDatum],
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile]
    ) -> [AutoChartDatum] {
        if [.line, .pointLine, .area, .faceted].contains(specification.family) {
            let xSemanticType = specification.encoding.x.flatMap {
                profiles[$0]?.semanticType
            }
            if xSemanticType == .temporal {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xDate ?? .distantPast
                    let right = rhs.element.xDate ?? .distantPast
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
            if xSemanticType == .quantitative {
                return data.enumerated().sorted { lhs, rhs in
                    let left = lhs.element.xNumber ?? -.infinity
                    let right = rhs.element.xNumber ?? -.infinity
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
        }
        return switch specification.sort {
        case .source: data
        case .ascending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") < ($1.yNumber ?? 0, $1.xLabel ?? "") }
        case .descending:
            data.sorted { ($0.yNumber ?? 0, $0.xLabel ?? "") > ($1.yNumber ?? 0, $1.xLabel ?? "") }
        }
    }
}

func disambiguatedCategoryLabels(
    _ pairs: [(identity: String, label: String)]
) -> [String: String] {
    let grouped = Dictionary(grouping: pairs, by: \.label)
    var labels: [String: String] = [:]
    for label in grouped.keys.sorted() {
        let identities = Array(Set(grouped[label, default: []].map(\.identity))).sorted()
        if identities.count == 1, let identity = identities.first {
            labels[identity] = label
        }
    }
    var usedLabels = Set(labels.values)
    for label in grouped.keys.sorted() {
        let identities = Array(Set(grouped[label, default: []].map(\.identity))).sorted()
        guard identities.count > 1 else { continue }
        let kinds = identities.map { identity -> String in
            switch identity.split(separator: ":", maxSplits: 1).first {
            case "boolean": "Boolean"
            case "integer": "Integer"
            case "number": "Number"
            case "double": "Number"
            case "decimal": "Decimal"
            case "text": "Text"
            case "date": "Date"
            default: "Value"
            }
        }
        let kindCounts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        var kindIndexes: [String: Int] = [:]
        for (identity, kind) in zip(identities, kinds) {
            kindIndexes[kind, default: 0] += 1
            let qualifier =
                kindCounts[kind, default: 0] == 1
                ? kind : "\(kind) \(kindIndexes[kind, default: 0])"
            let base = "\(label) (\(qualifier))"
            var candidate = base
            var suffix = 2
            while usedLabels.contains(candidate) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            labels[identity] = candidate
            usedLabels.insert(candidate)
        }
    }
    return labels
}

func disambiguatedCategoryValue(
    identity: String?,
    label: String?,
    labels: [String: String],
    fallback: String = "Missing value"
) -> String {
    guard let identity else { return label ?? fallback }
    return labels[identity] ?? label ?? identity
}

#if canImport(Charts) && canImport(SwiftUI)

/// A native Swift Charts view for an AutoTableCharts recommendation or specification.
///
/// The view snapshots the supplied table, prepares marks without mutating source
/// storage, validates the specification, and preserves contributing
/// ``AutoChartRowID`` values in bound selection state.
public struct AutoChartView: View {
    private let snapshot: AutoChartSnapshot
    private let recommendation: AutoChartRecommendation
    private let validation: AutoChartValidationResult
    private let data: [AutoChartDatum]
    private let sizeBounds: (minimum: Double, maximum: Double)?
    private let sharedYDomain: ClosedRange<Double>?
    private let interaction: AutoChartInteraction
    private let chartHeight: CGFloat
    private let snapshotFingerprint: Int
    private let xTitle: String
    private let yTitle: String
    private let seriesTitle: String
    private let facetTitle: String
    private let xSemanticType: AutoChartSemanticType?
    private let xDisplayLabels: [String: String]
    private let yDisplayLabels: [String: String]
    private let seriesDisplayLabels: [String: String]
    private let facetDisplayLabels: [String: String]
    private let uniqueXCount: Int
    @Binding private var selection: AutoChartSelection?

    @State private var selectedCategory: String?
    @State private var selectedDate: Date?
    @State private var selectedNumber: Double?
    @State private var selectedAngle: Double?
    @State private var zoomScale = 1.0
    @State private var zoomAnchor = 1.0

    /// Creates a chart from an engine-generated recommendation.
    ///
    /// Use this initializer when you want the recommendation's explanation and
    /// warnings to remain attached to the rendered chart.
    ///
    /// - Parameters:
    ///   - table: The same typed table used to generate the recommendation.
    ///   - recommendation: A validated engine result.
    ///   - selection: Optional linked selection state containing source-row IDs.
    ///   - interaction: Compact preview or exploratory interaction behavior.
    ///   - height: The requested chart height in points.
    public init<Table: AutoChartTable>(
        table: Table,
        recommendation: AutoChartRecommendation,
        selection: Binding<AutoChartSelection?> = .constant(nil),
        interaction: AutoChartInteraction = .explore,
        height: CGFloat = 280
    ) {
        let snapshot = AutoChartSnapshot(table)
        let profiles = Dictionary(
            AutoChartProfiler.profiles(snapshot).map { ($0.column.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let specification = recommendation.specification
        let data = AutoChartDataPreparation.data(
            snapshot: snapshot,
            specification: specification,
            profiles: profiles)
        let sizes = data.compactMap(\.size).filter(\.isFinite)
        let yValues = data.compactMap(\.yNumber).filter(\.isFinite)
        func categoryLabels(
            identity: KeyPath<AutoChartDatum, String?>,
            label: KeyPath<AutoChartDatum, String?>
        ) -> [String: String] {
            disambiguatedCategoryLabels(
                data.compactMap { datum -> (identity: String, label: String)? in
                    guard let identity = datum[keyPath: identity],
                        let label = datum[keyPath: label]
                    else { return nil }
                    return (identity, label)
                })
        }
        let xIsCategorical = specification.encoding.x.flatMap {
            profiles[$0]?.isCategorical
        } ?? false
        let usesCategoricalXLabels = xIsCategorical
            && [
                .bar, .rankedDot, .groupedBar, .stackedBar, .normalizedBar,
                .line, .pointLine, .area, .boxPlot, .heatmap, .donut, .range, .faceted,
            ].contains(specification.family)
        let xDisplayLabels = usesCategoricalXLabels
            ? categoryLabels(identity: \.xIdentity, label: \.xLabel) : [:]
        let yDisplayLabels = specification.family == .heatmap
            ? categoryLabels(identity: \.yIdentity, label: \.yLabel) : [:]
        let seriesDisplayLabels = specification.encoding.series != nil
            ? categoryLabels(identity: \.seriesIdentity, label: \.series) : [:]
        let facetDisplayLabels = specification.family == .faceted
            ? categoryLabels(identity: \.facetIdentity, label: \.facet) : [:]
        self.snapshot = snapshot
        self.recommendation = recommendation
        validation = AutoChartEngine.validate(
            specification: specification,
            snapshot: snapshot,
            profiles: profiles)
        self.data = data
        if let minimum = sizes.min(), let maximum = sizes.max() {
            sizeBounds = (minimum, maximum)
        } else {
            sizeBounds = nil
        }
        if let minimum = yValues.min(), let maximum = yValues.max() {
            let includesCategoricalX =
                specification.encoding.x.flatMap {
                    profiles[$0]?.isCategorical
                } ?? false
            let lower = includesCategoricalX ? min(0, minimum) : minimum
            let upper = includesCategoricalX ? max(0, maximum) : maximum
            if lower == upper {
                let padding = max(1, abs(lower) * 0.05)
                sharedYDomain = (lower - padding)...(upper + padding)
            } else if includesCategoricalX {
                sharedYDomain = lower...upper
            } else {
                let padding = max(abs(lower), abs(upper)) * 0.05
                sharedYDomain = (lower - padding)...(upper + padding)
            }
        } else {
            sharedYDomain = nil
        }
        self._selection = selection
        self.interaction = interaction
        chartHeight = height
        snapshotFingerprint = snapshot.contentFingerprint
        xTitle =
            specification.encoding.x.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Category"
        let usesStructuralCountTitle = specification.aggregation == .count
            && ![.histogram, .heatmap].contains(specification.family)
        yTitle = usesStructuralCountTitle
            ? "Count"
            : specification.encoding.y.flatMap { snapshot.column($0)?.name }
                .map(AutoChartProfiler.humanized) ?? "Value"
        seriesTitle =
            specification.encoding.series.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Series"
        facetTitle =
            specification.encoding.facet.flatMap { snapshot.column($0)?.name }
            .map(AutoChartProfiler.humanized) ?? "Facet"
        xSemanticType = specification.encoding.x.flatMap { profiles[$0]?.semanticType }
        self.xDisplayLabels = xDisplayLabels
        self.yDisplayLabels = yDisplayLabels
        self.seriesDisplayLabels = seriesDisplayLabels
        self.facetDisplayLabels = facetDisplayLabels
        uniqueXCount = Set(data.compactMap { $0.xIdentity ?? $0.xLabel }).count
    }

    /// Creates a chart from a caller-provided specification.
    ///
    /// The view validates the specification and displays diagnostics instead of
    /// an invalid chart. Call ``AutoChartEngine/validate(specification:for:)``
    /// first when the surrounding UI needs to react to errors.
    ///
    /// - Parameters:
    ///   - table: The typed table represented by the specification.
    ///   - specification: A caller-authored chart description.
    ///   - selection: Optional linked selection state containing source-row IDs.
    ///   - interaction: Compact preview or exploratory interaction behavior.
    ///   - height: The requested chart height in points.
    public init<Table: AutoChartTable>(
        table: Table,
        specification: AutoChartSpecification,
        selection: Binding<AutoChartSelection?> = .constant(nil),
        interaction: AutoChartInteraction = .explore,
        height: CGFloat = 280
    ) {
        let warnings =
            table.chartMetadata.isTruncated
            ? ["Based on the first returned rows; totals and composition are suppressed."]
            : []
        self.init(
            table: table,
            recommendation: AutoChartRecommendation(
                specification: specification,
                score: 0,
                rationale: ["Caller-provided specification."],
                warnings: warnings),
            selection: selection,
            interaction: interaction,
            height: height)
    }

    private var specification: AutoChartSpecification { recommendation.specification }

    /// The validated chart, warnings, selection summary, and exploration controls.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !specification.title.isEmpty {
                Text(specification.title)
                    .font(interaction == .preview ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(interaction == .preview ? 2 : nil)
            }
            if validation.isValid {
                chartBody
                    .frame(minHeight: interaction == .explore ? chartHeight : 180)
                if interaction == .explore, let selection {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.label).font(.subheadline.weight(.semibold))
                            Text(selection.valueDescription).font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        Button("Clear") { clearSelection() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("auto-chart-clear-selection")
                    }
                    .accessibilityElement(children: .combine)
                }
                if interaction == .explore, zoomScale > 1.01 {
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise") {
                        zoomScale = 1
                        zoomAnchor = 1
                    }
                    .font(.caption)
                    .accessibilityIdentifier("auto-chart-reset-zoom")
                }
            } else {
                ContentUnavailableView(
                    "Chart unavailable",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        validation.issues.map(\.message).joined(separator: " ")))
            }
            ForEach(recommendation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            specification.title.isEmpty ? specification.family.displayName : specification.title
        )
        .accessibilityIdentifier("auto-chart-\(specification.family.rawValue)")
        .onChange(of: recommendation.id) { _, _ in
            resetInteractionState()
        }
        .onChange(of: snapshotFingerprint) { _, _ in
            resetInteractionState()
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch specification.family {
        case .table:
            ContentUnavailableView(
                "Use the table view",
                systemImage: "tablecells",
                description: Text(
                    recommendation.rationale.first ?? "No safe chart is available."))
        case .kpi:
            kpiView
        case .bar, .groupedBar, .stackedBar, .normalizedBar:
            barChart
        case .rankedDot:
            rankedDotChart
        case .line, .pointLine, .area:
            lineChart
        case .scatter, .bubble:
            scatterChart
        case .histogram:
            histogramChart
        case .boxPlot:
            boxPlotChart
        case .heatmap:
            heatmapChart
        case .donut:
            donutChart
        case .range:
            rangeChart
        case .faceted:
            facetedChart
        }
    }

    private var kpiView: some View {
        let value = specification.encoding.y.flatMap { id in
            snapshot.rows.first?.values[id]
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(value.map(formatted) ?? "—")
                .font(
                    .system(
                        size: interaction == .preview ? 34 : 52, weight: .bold, design: .rounded
                    )
                )
                .minimumScaleFactor(0.6)
            Text(
                specification.encoding.y.flatMap { snapshot.column($0)?.name }
                    .map(AutoChartProfiler.humanized) ?? "Value"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var barChart: some View {
        if specification.orientation == .horizontal {
            let chart = Chart(data) { datum in
                if specification.family == .groupedBar {
                    BarMark(
                        x: .value(yTitle, datum.yNumber ?? 0),
                        y: .value(xTitle, xCategoryValue(for: datum)),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .position(by: .value(seriesTitle, seriesValue(for: datum)))
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                } else {
                    BarMark(
                        x: .value(yTitle, datum.yNumber ?? 0),
                        y: .value(xTitle, xCategoryValue(for: datum)),
                        stacking: stackingMethod
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
            }
            .chartXAxisLabel(yTitle)
            .chartYAxisLabel(xTitle)
            selectableCategoryY(verticalZoom(chart, categoryCount: uniqueXCount))
        } else {
            let chart = Chart(data) { datum in
                if specification.family == .groupedBar {
                    BarMark(
                        x: .value(xTitle, xCategoryValue(for: datum)),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .position(by: .value(seriesTitle, seriesValue(for: datum)))
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                } else {
                    BarMark(
                        x: .value(xTitle, xCategoryValue(for: datum)),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: stackingMethod
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
        }
    }

    private var rankedDotChart: some View {
        let chart = Chart(data) { datum in
            RuleMark(
                xStart: .value(yTitle, 0),
                xEnd: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .foregroundStyle(.secondary.opacity(0.45))
            PointMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .symbol(.circle)
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(yTitle)
        .chartYAxisLabel(xTitle)
        return selectableCategoryY(verticalZoom(chart, categoryCount: uniqueXCount))
    }

    @ViewBuilder
    private var lineChart: some View {
        if xSemanticType == .temporal {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, datum.xDate ?? .distantPast),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .opacity(0.45)
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
                LineMark(
                    x: .value(xTitle, datum.xDate ?? .distantPast),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, seriesValue(for: datum))
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .lineStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xDate ?? .distantPast),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else if xSemanticType == .quantitative {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, datum.xNumber ?? 0),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .opacity(0.45)
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
                LineMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, seriesValue(for: datum))
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .lineStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, datum.xNumber ?? 0),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                if specification.family == .area {
                    AreaMark(
                        x: .value(xTitle, xCategoryValue(for: datum)),
                        y: .value(yTitle, datum.yNumber ?? 0),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .opacity(0.45)
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
                LineMark(
                    x: .value(xTitle, xCategoryValue(for: datum)),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    series: .value(seriesTitle, seriesValue(for: datum))
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .lineStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
                if specification.family == .pointLine {
                    PointMark(
                        x: .value(xTitle, xCategoryValue(for: datum)),
                        y: .value(yTitle, datum.yNumber ?? 0)
                    )
                    .foregroundStyle(
                        by: .value(seriesTitle, seriesValue(for: datum))
                    )
                    .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                }
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableCategoryX(horizontalZoom(chart, categoryCount: uniqueXCount))
        }
    }

    @ViewBuilder
    private var scatterChart: some View {
        if xSemanticType == .temporal {
            let chart = Chart(data) { datum in
                PointMark(
                    x: .value(xTitle, datum.xDate ?? .distantPast),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize(for: datum.size))
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                PointMark(
                    x: .value(xTitle, datum.xNumber ?? 0),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize(for: datum.size))
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        }
    }

    private var histogramChart: some View {
        let chart = Chart(data) { datum in
            BarMark(
                xStart: .value(xTitle, datum.lower ?? 0),
                xEnd: .value(xTitle, datum.upper ?? 0),
                y: .value("Count", datum.yNumber ?? 0)
            )
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel("Count")
        return selectableNumberX(numberZoom(chart))
    }

    private var boxPlotChart: some View {
        let labels = xDisplayLabels
        let chart = Chart(data) { datum in
            RuleMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                yStart: .value(yTitle, datum.lower ?? 0),
                yEnd: .value(yTitle, datum.upper ?? 0))
            BarMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                yStart: .value(yTitle, datum.quartile1 ?? 0),
                yEnd: .value(yTitle, datum.quartile3 ?? 0),
                width: .fixed(28))
            PointMark(
                x: .value(xTitle, datum.xIdentity ?? "all"),
                y: .value("Median", datum.median ?? 0)
            )
            .symbol(.square)
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
        .chartXAxisLabel(xTitle)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(labels[identity] ?? identity)
                    }
                }
            }
        }
        .chartYAxisLabel(yTitle)
        return selectableCategoryIdentityX(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var heatmapChart: some View {
        let xLabels = xDisplayLabels
        let yLabels = yDisplayLabels
        let chart = Chart(data) { datum in
            RectangleMark(
                x: .value(xTitle, datum.xIdentity ?? ""),
                y: .value(yTitle, datum.yIdentity ?? "")
            )
            .foregroundStyle(by: .value("Count", datum.yNumber ?? 0))
            .accessibilityLabel(
                datum.accessibilityLabel(
                    name: disambiguatedCategoryValue(
                        identity: datum.xIdentity,
                        label: datum.xLabel,
                        labels: xLabels),
                    context: [
                        disambiguatedCategoryValue(
                            identity: datum.yIdentity,
                            label: datum.yLabel,
                            labels: yLabels)
                    ])
            )
        }
        .chartXAxisLabel(xTitle)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(xLabels[identity] ?? identity)
                    }
                }
            }
        }
        .chartYAxisLabel(yTitle)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let identity = value.as(String.self) {
                        Text(yLabels[identity] ?? identity)
                    }
                }
            }
        }
        return selectableHeatmap(horizontalZoom(chart, categoryCount: uniqueXCount))
    }

    private var donutChart: some View {
        let chart = Chart(data) { datum in
            SectorMark(
                angle: .value(yTitle, datum.yNumber ?? 0),
                innerRadius: .ratio(0.56),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value(xTitle, xCategoryValue(for: datum)))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            .annotation(position: .overlay) {
                Text(xCategoryValue(for: datum))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        return selectableAngle(chart)
    }

    private var rangeChart: some View {
        let chart = Chart(data) { datum in
            BarMark(
                xStart: .value("Start", datum.startDate ?? .distantPast),
                xEnd: .value("End", datum.endDate ?? .distantPast),
                y: .value(xTitle, xCategoryValue(for: datum))
            )
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if datum.startDate == datum.endDate {
                PointMark(
                    x: .value("Date", datum.startDate ?? .distantPast),
                    y: .value(xTitle, xCategoryValue(for: datum))
                )
                .symbol(.diamond)
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        }
        .chartXAxisLabel("Date")
        .chartYAxisLabel(xTitle)
        .environment(\.timeZone, .gmt)
        return selectableCategoryY(timeZoom(chart))
    }

    private var facetedChart: some View {
        let facets = Dictionary(grouping: data) { $0.facetIdentity }
        let facetKeys = facets.keys.sorted {
            let left = facets[$0]?.first?.facet ?? "\u{10FFFF}"
            let right = facets[$1]?.first?.facet ?? "\u{10FFFF}"
            if left != right { return left < right }
            return ($0 ?? "") < ($1 ?? "")
        }
        let yDomain = sharedYDomain ?? 0...1
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(facetKeys, id: \.self) { facetKey in
                    let facetData = facets[facetKey] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Text(facetKey.flatMap { facetDisplayLabels[$0] } ?? "Missing value")
                            .font(.caption.weight(.semibold))
                        if xSemanticType == .temporal {
                            let chart = Chart(facetData) { datum in
                                LineMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0),
                                    series: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .lineStyle(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .accessibilityLabel(markAccessibilityLabel(for: datum))
                                PointMark(
                                    x: .value(xTitle, datum.xDate ?? .distantPast),
                                    y: .value(yTitle, datum.yNumber ?? 0)
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .symbol(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .accessibilityLabel(markAccessibilityLabel(for: datum))
                            }
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, .gmt)
                            selectableFacetX(chart, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                        } else if xSemanticType == .quantitative {
                            let chart = Chart(facetData) { datum in
                                PointMark(
                                    x: .value(xTitle, datum.xNumber ?? 0),
                                    y: .value(yTitle, datum.yNumber ?? 0)
                                )
                                .foregroundStyle(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .symbol(
                                    by: .value(
                                        seriesTitle, seriesValue(for: datum))
                                )
                                .accessibilityLabel(markAccessibilityLabel(for: datum))
                            }
                            .chartYScale(domain: yDomain)
                            selectableFacetX(chart, as: Double.self) { value in
                                select(number: value, in: facetData)
                            }
                        } else {
                            let chart = Chart(facetData) { datum in
                                if specification.encoding.series != nil {
                                    BarMark(
                                        x: .value(xTitle, xCategoryValue(for: datum)),
                                        y: .value(yTitle, datum.yNumber ?? 0),
                                        stacking: .unstacked
                                    )
                                    .foregroundStyle(
                                        by: .value(
                                            seriesTitle, seriesValue(for: datum))
                                    )
                                    .position(
                                        by: .value(
                                            seriesTitle, seriesValue(for: datum))
                                    )
                                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                                } else {
                                    BarMark(
                                        x: .value(xTitle, xCategoryValue(for: datum)),
                                        y: .value(yTitle, datum.yNumber ?? 0)
                                    )
                                    .accessibilityLabel(markAccessibilityLabel(for: datum))
                                }
                            }
                            .chartYScale(domain: yDomain)
                            selectableFacetX(chart, as: String.self) { value in
                                select(category: value, in: facetData)
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private var primarySeriesLabel: String { yTitle }

    private func xCategoryValue(for datum: AutoChartDatum) -> String {
        disambiguatedCategoryValue(
            identity: datum.xIdentity,
            label: datum.xLabel,
            labels: xDisplayLabels)
    }

    private func seriesValue(for datum: AutoChartDatum) -> String {
        guard specification.encoding.series != nil else { return primarySeriesLabel }
        return disambiguatedCategoryValue(
            identity: datum.seriesIdentity,
            label: datum.series,
            labels: seriesDisplayLabels,
            fallback: "Missing series")
    }

    private func facetValue(for datum: AutoChartDatum) -> String {
        disambiguatedCategoryValue(
            identity: datum.facetIdentity,
            label: datum.facet,
            labels: facetDisplayLabels,
            fallback: "Missing facet")
    }

    private func markAccessibilityLabel(for datum: AutoChartDatum) -> String {
        let name: String = {
            switch specification.family {
            case .histogram:
                return datum.xLabel ?? "Value"
            case .bar, .groupedBar, .stackedBar, .normalizedBar, .rankedDot,
                .boxPlot, .donut, .range:
                return xCategoryValue(for: datum)
            default:
                switch xSemanticType {
                case .temporal:
                    return datum.xDate?.formatted(
                        Date.FormatStyle(
                            date: .abbreviated,
                            time: .shortened,
                            timeZone: TimeZone.gmt)) ?? "Value"
                case .quantitative:
                    return datum.xNumber?.formatted() ?? "Value"
                default:
                    return xCategoryValue(for: datum)
                }
            }
        }()
        return datum.accessibilityLabel(
            name: name,
            series: specification.encoding.series == nil ? nil : seriesValue(for: datum),
            facet: specification.encoding.facet == nil
                ? nil : "\(facetTitle): \(facetValue(for: datum))",
            valueDescription: specification.family == .range
                ? datum.intervalAccessibilityDescription : nil)
    }

    private func selectionLabel(
        base: String,
        matches: [AutoChartDatum]
    ) -> String {
        var context: [String] = []
        if specification.encoding.series != nil {
            let series = Array(Set(matches.map { seriesValue(for: $0) })).sorted()
            if !series.isEmpty { context.append(series.joined(separator: ", ")) }
        }
        if specification.encoding.facet != nil {
            let facets = Array(Set(matches.map { facetValue(for: $0) })).sorted()
            if !facets.isEmpty {
                context.append("\(facetTitle): \(facets.joined(separator: ", "))")
            }
        }
        guard !context.isEmpty else { return base }
        return ([base] + context).joined(separator: " · ")
    }

    private func symbolSize(for value: Double?) -> Double {
        guard specification.family == .bubble else { return 45 }
        guard let value, value.isFinite, let sizeBounds else { return 40 }
        guard sizeBounds.maximum > sizeBounds.minimum else { return 132 }
        let normalized = min(
            1,
            max(0, (value - sizeBounds.minimum) / (sizeBounds.maximum - sizeBounds.minimum)))
        return 24 + normalized * 216
    }

    private var stackingMethod: MarkStackingMethod {
        switch specification.stacking {
        case .none: .unstacked
        case .standard: .standard
        case .normalized: .normalized
        }
    }

    private func formatted(_ value: AutoChartValue) -> String {
        guard let id = specification.encoding.y,
            let unit = snapshot.column(id)?.hints.unit,
            let numeric = value.numericValue
        else { return value.displayString }
        switch unit {
        case .currency(let code):
            return numeric.formatted(.currency(code: code))
        case .percent(let fractional):
            return (fractional ? numeric : numeric / 100).formatted(
                .percent.precision(.fractionLength(0...2)))
        default:
            return value.displayString
        }
    }

    @ViewBuilder
    private func selectableCategoryX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in select(category: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableCategoryY<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartYSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in select(category: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableCategoryIdentityX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedCategory)
                .onChange(of: selectedCategory) { _, value in
                    select(categoryIdentity: value)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableHeatmap<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onEnded { value in
                                guard abs(value.translation.width) < 8,
                                    abs(value.translation.height) < 8,
                                    let plotFrame = proxy.plotFrame
                                else { return }
                                let frame = geometry[plotFrame]
                                let location = CGPoint(
                                    x: value.location.x - frame.origin.x,
                                    y: value.location.y - frame.origin.y)
                                guard location.x >= 0, location.y >= 0,
                                    location.x <= frame.width, location.y <= frame.height,
                                    let xIdentity: String = proxy.value(atX: location.x),
                                    let yIdentity: String = proxy.value(atY: location.y)
                                else { return }
                                select(
                                    heatmapXIdentity: xIdentity,
                                    yIdentity: yIdentity)
                            })
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableFacetX<Content: View, Value: Plottable>(
        _ content: Content,
        as _: Value.Type,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        if interaction == .explore {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onEnded { value in
                                guard abs(value.translation.width) < 8,
                                    abs(value.translation.height) < 8,
                                    let plotFrame = proxy.plotFrame
                                else { return }
                                let frame = geometry[plotFrame]
                                let xPosition = value.location.x - frame.origin.x
                                guard xPosition >= 0, xPosition <= frame.width,
                                    let selected: Value = proxy.value(atX: xPosition)
                                else { return }
                                onSelect(selected)
                            })
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableDateX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedDate)
                .onChange(of: selectedDate) { _, value in select(date: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableNumberX<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartXSelection(value: $selectedNumber)
                .onChange(of: selectedNumber) { _, value in select(number: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func selectableAngle<Content: View>(_ content: Content) -> some View {
        if interaction == .explore {
            content
                .chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, value in select(angle: value) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func horizontalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func verticalZoom<Content: View>(
        _ content: Content,
        categoryCount: Int
    ) -> some View {
        if interaction == .explore, categoryCount > 10 {
            content
                .chartScrollableAxes(.vertical)
                .chartYVisibleDomain(
                    length: max(3, Int(Double(min(categoryCount, 10)) / zoomScale))
                )
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func timeZoom<Content: View>(_ content: Content) -> some View {
        let dates = data.flatMap { datum in
            [datum.xDate, datum.startDate, datum.endDate].compactMap { $0 }
        }
        let span = max(86_400, (dates.max() ?? .now).timeIntervalSince(dates.min() ?? .now))
        if interaction == .explore, dates.count > 12 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(86_400, span / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func numberZoom<Content: View>(_ content: Content) -> some View {
        let values = data.compactMap(\.xNumber)
        let span = max(1, (values.max() ?? 1) - (values.min() ?? 0))
        if interaction == .explore, values.count > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: span / zoomScale)
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    #if os(tvOS) || os(watchOS)
    private var zoomGesture: some Gesture {
        TapGesture()
    }
    #else
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomScale = min(12, max(1, zoomAnchor * value.magnification))
            }
            .onEnded { _ in zoomAnchor = zoomScale }
    }
    #endif

    private func select(category: String?) {
        select(category: category, in: data)
    }

    private func select(category: String?, in candidates: [AutoChartDatum]) {
        guard let category else {
            selection = nil
            return
        }
        let matches = candidates.filter { xCategoryValue(for: $0) == category }
        applySelection(
            matches,
            label: selectionLabel(base: category, matches: matches))
    }

    private func select(categoryIdentity: String?) {
        guard let categoryIdentity else {
            selection = nil
            return
        }
        let matches = data.filter { $0.xIdentity == categoryIdentity }
        applySelection(
            matches,
            label: matches.first.map { xCategoryValue(for: $0) } ?? categoryIdentity)
    }

    private func select(heatmapXIdentity: String, yIdentity: String) {
        guard
            let match = data.first(where: {
                $0.xIdentity == heatmapXIdentity && $0.yIdentity == yIdentity
            })
        else { return }
        let label = [
            disambiguatedCategoryValue(
                identity: match.xIdentity,
                label: match.xLabel,
                labels: xDisplayLabels),
            disambiguatedCategoryValue(
                identity: match.yIdentity,
                label: match.yLabel,
                labels: yDisplayLabels),
        ].joined(separator: ", ")
        applySelection([match], label: label)
    }

    private func select(date: Date?) {
        select(date: date, in: data)
    }

    private func select(date: Date?, in candidates: [AutoChartDatum]) {
        guard let date else {
            selection = nil
            return
        }
        let matches = AutoChartSelectionPreparation.nearestDateMatches(
            to: date,
            in: candidates)
        guard let nearestDate = matches.first?.xDate else { return }
        let base = nearestDate.formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                timeZone: TimeZone.gmt))
        applySelection(
            matches,
            label: selectionLabel(base: base, matches: matches))
    }

    private func select(number: Double?) {
        select(number: number, in: data)
    }

    private func select(number: Double?, in candidates: [AutoChartDatum]) {
        guard let number else {
            selection = nil
            return
        }
        let matches = AutoChartSelectionPreparation.nearestNumberMatches(
            to: number,
            in: candidates)
        guard let nearestNumber = matches.first?.xNumber else { return }
        applySelection(
            matches,
            label: selectionLabel(
                base: AutoChartSelectionPreparation.numberSelectionLabel(
                    for: matches,
                    selectedNumber: nearestNumber,
                    family: specification.family),
                matches: matches))
    }

    private func select(angle: Double?) {
        guard let angle else {
            selection = nil
            return
        }
        guard let datum = AutoChartSelectionPreparation.angleMatch(to: angle, in: data) else {
            selection = nil
            return
        }
        applySelection([datum], label: xCategoryValue(for: datum))
    }

    private func applySelection(_ matches: [AutoChartDatum], label: String) {
        let rowIDs = matches.reduce(into: Set<AutoChartRowID>()) {
            $0.formUnion($1.sourceRowIDs)
        }
        selection = AutoChartSelection(
            sourceRowIDs: rowIDs,
            label: label,
            valueDescription: AutoChartSelectionPreparation.valueDescription(
                for: matches,
                aggregation: specification.aggregation))
    }

    private func clearSelection() {
        selectedCategory = nil
        selectedDate = nil
        selectedNumber = nil
        selectedAngle = nil
        selection = nil
    }

    private func resetInteractionState() {
        clearSelection()
        zoomScale = 1
        zoomAnchor = 1
    }
}
#endif
