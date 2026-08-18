import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

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
        let valueDescription =
            valueDescription ?? yNumber?.formatted(.number.precision(.fractionLength(0...3)))
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

enum AutoChartAccessibility {
    static func markLabel(
        for datum: AutoChartDatum,
        family: AutoChartFamily,
        xSemanticType: AutoChartSemanticType?,
        xCategoryName: @autoclosure () -> String,
        seriesName: String? = nil,
        facetDescription: String? = nil
    ) -> String {
        let name: String = {
            switch family {
            case .histogram:
                return datum.xLabel ?? "Value"
            case .bar, .groupedBar, .stackedBar, .normalizedBar, .rankedDot,
                .boxPlot, .donut, .range:
                return xCategoryName()
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
                    return xCategoryName()
                }
            }
        }()
        return datum.accessibilityLabel(
            name: name,
            series: seriesName,
            facet: facetDescription,
            valueDescription: family == .range
                ? datum.intervalAccessibilityDescription : nil)
    }

    static func heatmapLabel(
        for datum: AutoChartDatum,
        xCategoryName: String,
        yCategoryName: String
    ) -> String {
        datum.accessibilityLabel(
            name: xCategoryName,
            context: [yCategoryName])
    }
}

enum AutoChartSelectionPreparation {
    static func selection(
        for matches: [AutoChartDatum],
        label: String,
        aggregation: AutoChartAggregation
    ) -> AutoChartSelection? {
        guard !matches.isEmpty else { return nil }
        let rowIDs = matches.reduce(into: Set<AutoChartRowID>()) {
            $0.formUnion($1.sourceRowIDs)
        }
        guard !rowIDs.isEmpty else { return nil }
        return AutoChartSelection(
            sourceRowIDs: rowIDs,
            label: label,
            valueDescription: valueDescription(
                for: matches,
                aggregation: aggregation))
    }

    static func angleMatch(
        to selectedAngle: Double,
        in candidates: [AutoChartDatum]
    ) -> AutoChartDatum? {
        guard selectedAngle.isFinite, selectedAngle >= 0 else { return nil }
        var cumulative = 0.0
        for datum in candidates {
            cumulative += datum.yNumber ?? 0
            if selectedAngle <= cumulative {
                return datum.sourceRowIDs.isEmpty ? nil : datum
            }
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
        let profiles = AutoChartProfiler.profileIndex(snapshot)
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
            let xIdentity = encoding.x.flatMap { id in
                AutoChartProfiler.identityString(
                    xValue, semanticType: profiles[id]?.semanticType)
            }
            let startDate = start.flatMap(AutoChartProfiler.dateValue)
            let endDate = end.flatMap(AutoChartProfiler.dateValue)
            if specification.family == .range {
                guard startDate != nil, endDate != nil else { return nil }
            } else if specification.family != .table,
                specification.family != .kpi,
                encoding.x != nil
            {
                guard xIdentity != nil else { return nil }
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
                xIdentity: xIdentity,
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
                startDate: startDate,
                endDate: endDate)
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
            data.enumerated().sorted { lhs, rhs in
                let leftValue = lhs.element.yNumber ?? 0
                let rightValue = rhs.element.yNumber ?? 0
                if leftValue != rightValue { return leftValue < rightValue }
                return breaksTie(lhs, rhs)
            }.map(\.element)
        case .descending:
            data.enumerated().sorted { lhs, rhs in
                let leftValue = lhs.element.yNumber ?? 0
                let rightValue = rhs.element.yNumber ?? 0
                if leftValue != rightValue { return leftValue > rightValue }
                return breaksTie(lhs, rhs)
            }.map(\.element)
        }
    }

    /// Orders categories that measure the same by their visible label, falling
    /// back to identity and then source order so the result stays deterministic
    /// when two distinct categories share a label.
    private static func breaksTie(
        _ lhs: (offset: Int, element: AutoChartDatum),
        _ rhs: (offset: Int, element: AutoChartDatum)
    ) -> Bool {
        let leftLabel = lhs.element.xLabel ?? ""
        let rightLabel = rhs.element.xLabel ?? ""
        if leftLabel != rightLabel { return leftLabel < rightLabel }
        let leftIdentity = lhs.element.xIdentity ?? ""
        let rightIdentity = rhs.element.xIdentity ?? ""
        if leftIdentity != rightIdentity { return leftIdentity < rightIdentity }
        return lhs.offset < rhs.offset
    }
}

func disambiguatedCategoryLabels(
    _ pairs: [(identity: String, label: String)]
) -> [String: String] {
    let groups = Dictionary(grouping: pairs, by: \.label)
        .map { label, pairs in
            (label: label, identities: Array(Set(pairs.map(\.identity))).sorted())
        }
        .sorted { $0.label < $1.label }
    var labels: [String: String] = [:]
    for (label, identities) in groups {
        if identities.count == 1, let identity = identities.first {
            labels[identity] = label
        }
    }
    var usedLabels = Set(labels.values)
    for (label, identities) in groups {
        guard identities.count > 1 else { continue }
        let kinds = identities.map { identity -> String in
            switch identity.split(separator: ":", maxSplits: 1).first {
            case "boolean": "Boolean"
            case "integer": "Integer"
            case "number": "Number"
            case "exact-number": "Exact Number"
            case "double": "Double"
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

private struct AutoChartRenderPresentation {
    var sizeBounds: (minimum: Double, maximum: Double)?
    var sharedYDomain: ClosedRange<Double>?
    var sharedXDateDomain: ClosedRange<Date>?
    var sharedXNumberDomain: ClosedRange<Double>?
    var sharedXCategoryDomain: [String]
    var facetBaseFamily: AutoChartFamily?
    var xTitle: String
    var yTitle: String
    var seriesTitle: String
    var facetTitle: String
    var xSemanticType: AutoChartSemanticType?
    var xDisplayLabels: [String: String]
    var yDisplayLabels: [String: String]
    var seriesDisplayLabels: [String: String]
    var facetDisplayLabels: [String: String]
    var uniqueXCount: Int
    var timeZoomValueCount: Int
    var timeZoomSpan: TimeInterval
    var numberZoomValueCount: Int
    var numberZoomSpan: Double

    init(
        snapshot: AutoChartSnapshot,
        specification: AutoChartSpecification,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        data: [AutoChartDatum]
    ) {
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
        func numericDomain(
            _ values: [Double],
            includingZero: Bool
        ) -> ClosedRange<Double>? {
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let lower = includingZero ? min(0, minimum) : minimum
            let upper = includingZero ? max(0, maximum) : maximum
            if lower == upper {
                let padding = max(1, abs(lower) * 0.05)
                return expandedFiniteRange(lower...upper, padding: padding)
            }
            if includingZero {
                return expandedFiniteRange(lower...upper, padding: 0)
            }
            let padding = max(abs(lower), abs(upper)) * 0.05
            return expandedFiniteRange(lower...upper, padding: padding)
        }
        func xNumberDomain(_ values: [Double]) -> ClosedRange<Double>? {
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            if minimum == maximum {
                let padding = max(1, abs(minimum) * 0.05)
                return expandedFiniteRange(minimum...maximum, padding: padding)
            }
            let span = maximum - minimum
            let padding = span.isFinite ? span * 0.05 : 0
            return expandedFiniteRange(minimum...maximum, padding: padding)
        }
        func dateDomain(_ values: [Date]) -> ClosedRange<Date>? {
            // A non-finite date can't bound an axis — it collapses the whole
            // domain to NaN — so drop it the way the numeric domains drop theirs.
            let values = values.filter { $0.timeIntervalSinceReferenceDate.isFinite }
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let lowerInterval = minimum.timeIntervalSinceReferenceDate
            let upperInterval = maximum.timeIntervalSinceReferenceDate
            let intervalRange: ClosedRange<Double>
            if minimum == maximum {
                guard let expanded = expandedFiniteRange(
                    lowerInterval...upperInterval,
                    padding: 43_200)
                else { return nil }
                intervalRange = expanded
            } else {
                let span = upperInterval - lowerInterval
                let padding = span.isFinite ? span * 0.05 : 0
                guard let expanded = expandedFiniteRange(
                    lowerInterval...upperInterval,
                    padding: padding)
                else { return nil }
                intervalRange = expanded
            }
            let lower = Date(timeIntervalSinceReferenceDate: intervalRange.lowerBound)
            let upper = Date(timeIntervalSinceReferenceDate: intervalRange.upperBound)
            return lower...upper
        }
        func expandedFiniteRange(
            _ range: ClosedRange<Double>,
            padding: Double
        ) -> ClosedRange<Double>? {
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                padding.isFinite, padding >= 0
            else { return nil }
            let paddedLower = range.lowerBound - padding
            let paddedUpper = range.upperBound + padding
            let lower = paddedLower.isFinite ? paddedLower : range.lowerBound
            let upper = paddedUpper.isFinite ? paddedUpper : range.upperBound
            if lower < upper {
                if (upper - lower).isFinite { return lower...upper }
                // Padding near a finite limit can make an otherwise usable span
                // overflow. Prefer the unpadded range in that case.
                if range.lowerBound < range.upperBound,
                    (range.upperBound - range.lowerBound).isFinite
                {
                    return range
                }
                return nil
            }

            // A zero or underflowed padding can leave a singleton. Move by one
            // representable value where possible without creating infinity.
            let previous = range.lowerBound.nextDown
            let next = range.upperBound.nextUp
            let finiteLower = previous.isFinite ? previous : range.lowerBound
            let finiteUpper = next.isFinite ? next : range.upperBound
            guard finiteLower < finiteUpper,
                (finiteUpper - finiteLower).isFinite
            else { return nil }
            return finiteLower...finiteUpper
        }

        let xSemanticType = specification.encoding.x.flatMap { profiles[$0]?.semanticType }
        let xIsCategorical =
            specification.encoding.x.flatMap {
                profiles[$0]?.isCategorical
            } ?? false
        let xUsesIdentityLabels =
            xIsCategorical
            || (specification.family == .boxPlot && specification.encoding.x == nil)
        let xDisplayLabels =
            xUsesIdentityLabels
            ? categoryLabels(identity: \.xIdentity, label: \.xLabel) : [:]
        let yDisplayLabels =
            specification.family == .heatmap
            ? categoryLabels(identity: \.yIdentity, label: \.yLabel) : [:]
        let seriesDisplayLabels =
            specification.encoding.series != nil
            ? categoryLabels(identity: \.seriesIdentity, label: \.series) : [:]
        let facetDisplayLabels =
            specification.encoding.facet != nil
            ? categoryLabels(identity: \.facetIdentity, label: \.facet) : [:]
        let facetBaseFamily = AutoChartEngine.resolvedFacetBaseFamily(
            specification: specification,
            profiles: profiles)

        if specification.family == .bubble {
            let sizes = data.compactMap(\.size).filter(\.isFinite)
            if let minimum = sizes.min(), let maximum = sizes.max() {
                sizeBounds = (minimum, maximum)
            } else {
                sizeBounds = nil
            }
        } else {
            sizeBounds = nil
        }

        if specification.family == .faceted {
            sharedYDomain = numericDomain(
                data.compactMap(\.yNumber).filter(\.isFinite),
                includingZero: xIsCategorical)
            sharedXDateDomain =
                xSemanticType == .temporal
                ? dateDomain(data.compactMap(\.xDate)) : nil
            sharedXNumberDomain =
                xSemanticType == .quantitative
                ? xNumberDomain(data.compactMap(\.xNumber).filter(\.isFinite)) : nil
        } else {
            sharedYDomain = nil
            sharedXDateDomain = nil
            sharedXNumberDomain = nil
        }

        if specification.family == .faceted, xIsCategorical {
            var seen: Set<String> = []
            sharedXCategoryDomain = data.compactMap { datum in
                let category = disambiguatedCategoryValue(
                    identity: datum.xIdentity,
                    label: datum.xLabel,
                    labels: xDisplayLabels)
                return seen.insert(category).inserted ? category : nil
            }
        } else {
            sharedXCategoryDomain = []
        }

        self.facetBaseFamily = facetBaseFamily
        self.xSemanticType = xSemanticType
        self.xDisplayLabels = xDisplayLabels
        self.yDisplayLabels = yDisplayLabels
        self.seriesDisplayLabels = seriesDisplayLabels
        self.facetDisplayLabels = facetDisplayLabels
        uniqueXCount = Set(data.compactMap { $0.xIdentity ?? $0.xLabel }).count
        let zoomSource = specification.family.zoomSource(for: xSemanticType)
        var minimumZoomDate: Date?
        var maximumZoomDate: Date?
        var zoomDateCount = 0
        var minimumZoomNumber: Double?
        var maximumZoomNumber: Double?
        var zoomNumberCount = 0
        func includeZoomDate(_ date: Date?) {
            guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return }
            zoomDateCount += 1
            minimumZoomDate = min(minimumZoomDate ?? date, date)
            maximumZoomDate = max(maximumZoomDate ?? date, date)
        }
        if zoomSource != .none {
            for datum in data {
                switch zoomSource {
                case .intervalDates:
                    includeZoomDate(datum.startDate)
                    includeZoomDate(datum.endDate)
                case .temporalX:
                    includeZoomDate(datum.xDate)
                case .numericX:
                    if let number = datum.xNumber, number.isFinite {
                        zoomNumberCount += 1
                        minimumZoomNumber = min(minimumZoomNumber ?? number, number)
                        maximumZoomNumber = max(maximumZoomNumber ?? number, number)
                    }
                case .none:
                    break
                }
            }
        }
        if let minimumZoomDate, let maximumZoomDate {
            let span = maximumZoomDate.timeIntervalSince(minimumZoomDate)
            timeZoomValueCount = span.isFinite ? zoomDateCount : 0
            timeZoomSpan = span.isFinite ? max(86_400, span) : 86_400
        } else {
            timeZoomValueCount = 0
            timeZoomSpan = 86_400
        }
        if let minimumZoomNumber, let maximumZoomNumber {
            let span = maximumZoomNumber - minimumZoomNumber
            numberZoomValueCount = span.isFinite ? zoomNumberCount : 0
            numberZoomSpan = span.isFinite ? max(1, span) : 1
        } else {
            numberZoomValueCount = 0
            numberZoomSpan = 1
        }
        xTitle =
            specification.encoding.x.flatMap { snapshot.column($0) }
            .map(AutoChartProfiler.displayName) ?? "Category"
        let usesStructuralCountTitle =
            specification.aggregation == .count
            && ![.histogram, .heatmap].contains(specification.family)
        yTitle =
            usesStructuralCountTitle
            ? "Count"
            : specification.encoding.y.flatMap { snapshot.column($0) }
                .map(AutoChartProfiler.displayName) ?? "Value"
        seriesTitle =
            specification.encoding.series.flatMap { snapshot.column($0) }
            .map(AutoChartProfiler.displayName) ?? "Series"
        facetTitle =
            specification.encoding.facet.flatMap { snapshot.column($0) }
            .map(AutoChartProfiler.displayName) ?? "Facet"
    }
}

private enum AutoChartZoomSource: Equatable {
    case none
    case temporalX
    case numericX
    case intervalDates
}

private extension AutoChartFamily {
    func zoomSource(for semanticType: AutoChartSemanticType?) -> AutoChartZoomSource {
        switch self {
        case .range:
            return .intervalDates
        case .histogram:
            return .numericX
        case .line, .pointLine, .area, .scatter, .bubble:
            if semanticType == .temporal { return .temporalX }
            if semanticType == .quantitative { return .numericX }
            return .none
        default:
            return .none
        }
    }
}

private final class AutoChartPreparedTable: Sendable {
    let snapshot: AutoChartSnapshot
    let profiles: [AutoChartColumnID: AutoChartColumnProfile]
    let fingerprint: Int
    let estimatedCost: Int?
    let cacheConfigurationRevision: UInt64

    init(
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        fingerprint: Int,
        estimatedCost: Int?,
        cacheConfigurationRevision: UInt64
    ) {
        self.snapshot = snapshot
        self.profiles = profiles
        self.fingerprint = fingerprint
        self.estimatedCost = estimatedCost
        self.cacheConfigurationRevision = cacheConfigurationRevision
    }
}

private struct AutoChartRenderCore {
    let table: AutoChartPreparedTable
    let data: [AutoChartDatum]
    let validation: AutoChartValidationResult
    let presentation: AutoChartRenderPresentation

    var snapshot: AutoChartSnapshot { table.snapshot }
    var fingerprint: Int { table.fingerprint }
}

/// Process-wide retention limits for prepared rendering data.
///
/// The table and render costs are approximate retained-byte budgets rather than
/// exact allocation limits. Set either entry count or cost to zero to disable
/// that cache layer. Initializer inputs below zero are clamped to zero.
public struct AutoChartRenderCacheConfiguration: Equatable, Sendable {
    /// The standard cache limits used until a host supplies another configuration.
    public static let standard = AutoChartRenderCacheConfiguration()

    /// The maximum number of snapshots and profile sets retained. Defaults to eight.
    public let maximumTableEntries: Int
    /// The approximate retained-byte budget for snapshots and profiles. Defaults to 32 MiB.
    public let maximumTableCost: Int
    /// The maximum number of prepared recommendation results retained. Defaults to sixteen.
    public let maximumRenderEntries: Int
    /// The approximate retained-byte budget for prepared recommendation results.
    /// Defaults to 32 MiB. A table snapshot shared through the table cache is
    /// excluded; a snapshot retained only through render entries counts against
    /// this budget once, however many render entries share it.
    public let maximumRenderCost: Int

    /// Creates process-wide rendering cache limits.
    ///
    /// - Parameters:
    ///   - maximumTableEntries: Maximum retained snapshots and profile sets.
    ///   - maximumTableCost: Approximate retained-byte budget for snapshots and profiles.
    ///   - maximumRenderEntries: Maximum retained prepared recommendation results.
    ///   - maximumRenderCost: Approximate retained-byte budget for prepared results.
    ///     Table-cache snapshots are excluded, while a snapshot retained only through
    ///     render entries is counted once no matter how many share it.
    public init(
        maximumTableEntries: Int = 8,
        maximumTableCost: Int = 32 * 1_024 * 1_024,
        maximumRenderEntries: Int = 16,
        maximumRenderCost: Int = 32 * 1_024 * 1_024
    ) {
        self.maximumTableEntries = max(0, maximumTableEntries)
        self.maximumTableCost = max(0, maximumTableCost)
        self.maximumRenderEntries = max(0, maximumRenderEntries)
        self.maximumRenderCost = max(0, maximumRenderCost)
    }
}

private extension AutoChartRenderCacheConfiguration {
    var isTableCachingEnabled: Bool {
        maximumTableEntries > 0 && maximumTableCost > 0
    }

    var isRenderCachingEnabled: Bool {
        maximumRenderEntries > 0 && maximumRenderCost > 0
    }
}

/// Controls the process-wide cache used by ``AutoChartView``.
public enum AutoChartRenderCache {
    /// The currently active process-wide limits.
    public static var configuration: AutoChartRenderCacheConfiguration {
        AutoChartRenderPreparationCache.shared.configuration
    }

    /// Applies new process-wide limits and immediately evicts entries that exceed them.
    ///
    /// Configuration and rendering may safely occur from different threads. Configure
    /// the cache during application or extension startup when possible so its behavior
    /// remains predictable for every chart in the process.
    public static func configure(_ configuration: AutoChartRenderCacheConfiguration) {
        AutoChartRenderPreparationCache.shared.configure(configuration)
    }

    /// Releases every retained table and prepared rendering result.
    public static func removeAll() {
        AutoChartRenderPreparationCache.shared.removeAll()
    }

    static func handleMemoryPressure() {
        AutoChartRenderPreparationCache.shared.removeAll()
    }

    static var retainedTableCount: Int {
        AutoChartRenderPreparationCache.shared.tableEntryCount
    }

    static var retainedRenderCount: Int {
        AutoChartRenderPreparationCache.shared.renderEntryCount
    }

    /// The bytes currently charged against the render budget, counting a shared
    /// render-owned snapshot once.
    static var retainedRenderCost: Int {
        AutoChartRenderPreparationCache.shared.renderCost
    }
}

private struct AutoChartRenderTableCacheKey: Hashable {
    var tableType: String
    var tableIdentity: String?
    var contentIdentity: String
}

private struct AutoChartRenderCacheKey: Hashable {
    var table: AutoChartRenderTableCacheKey
    var specification: AutoChartSpecification
}

private final class AutoChartRenderPreparationCache: @unchecked Sendable {
    static let shared = AutoChartRenderPreparationCache()

    private let lock = NSLock()
    private var activeConfiguration = AutoChartRenderCacheConfiguration.standard
    private var configurationRevision: UInt64 = 0
    private var tableEntries: [AutoChartRenderTableCacheKey: AutoChartPreparedTable] = [:]
    private var tableRecency: [AutoChartRenderTableCacheKey] = []
    private var tableTotalCost = 0
    private var entries: [AutoChartRenderCacheKey: AutoChartRenderCore] = [:]
    private var costs: [AutoChartRenderCacheKey: Int] = [:]
    private var recency: [AutoChartRenderCacheKey] = []
    private var totalCost = 0
    /// Byte cost of each render-owned prepared table, charged to the budget once
    /// however many render entries share it.
    private var renderTableCosts: [ObjectIdentifier: Int] = [:]
    /// Render entries retaining each render-owned prepared table. A table is
    /// charged while this is non-empty and released when the last entry goes.
    private var renderTableRetainers: [ObjectIdentifier: Set<AutoChartRenderCacheKey>] = [:]
    /// Reverse index from a render entry to the render-owned table it retains.
    private var renderEntryTables: [AutoChartRenderCacheKey: ObjectIdentifier] = [:]
    // Retains the UIKit registration for the process lifetime of the shared cache.
    private var memoryWarningObserver: NSObjectProtocol?

    private struct ConfigurationSnapshot {
        let value: AutoChartRenderCacheConfiguration
        let revision: UInt64
    }

    private init() {
        #if canImport(UIKit) && !os(watchOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            AutoChartRenderCache.handleMemoryPressure()
        }
        #endif
    }

    func core<Table: AutoChartTable>(
        table: Table,
        recommendation: AutoChartRecommendation
    ) -> AutoChartRenderCore {
        let tableType = String(reflecting: Table.self)
        if let tableIdentity = table.chartDataIdentity,
            let version = table.chartDataVersion
        {
            let tableKey = AutoChartRenderTableCacheKey(
                tableType: tableType,
                tableIdentity: tableIdentity,
                contentIdentity: "version:\(version)")
            let renderKey = AutoChartRenderCacheKey(
                table: tableKey,
                specification: recommendation.specification)
            // Identity and version are the caller's content-stability contract, so
            // the render layer can hit independently of the table layer.
            if let cached = value(for: renderKey) { return cached }
            if let prepared = tableValue(for: tableKey) {
                return core(
                    table: prepared,
                    tableKey: tableKey,
                    recommendation: recommendation)
            }
            if let prepared = renderOwnedTableValue(for: tableKey) {
                return core(
                    table: prepared,
                    tableKey: tableKey,
                    recommendation: recommendation)
            }
            var hasher = Hasher()
            hasher.combine(tableType)
            hasher.combine(tableIdentity)
            hasher.combine(version)
            return core(
                snapshot: AutoChartSnapshot(table),
                tableKey: tableKey,
                recommendation: recommendation,
                fingerprint: hasher.finalize())
        }

        let snapshot = AutoChartSnapshot(table)
        let fingerprint = snapshot.contentFingerprint
        let tableKey = AutoChartRenderTableCacheKey(
            tableType: tableType,
            tableIdentity: nil,
            contentIdentity: "fingerprint:\(fingerprint)")
        if let prepared = tableValue(for: tableKey, matching: snapshot) {
            return core(
                table: prepared,
                tableKey: tableKey,
                recommendation: recommendation)
        }
        if let prepared = renderOwnedTableValue(for: tableKey, matching: snapshot) {
            return core(
                table: prepared,
                tableKey: tableKey,
                recommendation: recommendation)
        }
        return core(
            snapshot: snapshot,
            tableKey: tableKey,
            recommendation: recommendation,
            fingerprint: fingerprint)
    }

    private func core(
        snapshot: AutoChartSnapshot,
        tableKey: AutoChartRenderTableCacheKey,
        recommendation: AutoChartRecommendation,
        fingerprint: Int
    ) -> AutoChartRenderCore {
        let cacheConfiguration = configurationSnapshot()
        let profiles = AutoChartProfiler.profileIndex(snapshot)
        let tableCostLimit = max(
            cacheConfiguration.value.isTableCachingEnabled
                ? cacheConfiguration.value.maximumTableCost : 0,
            cacheConfiguration.value.isRenderCachingEnabled
                ? cacheConfiguration.value.maximumRenderCost : 0)
        let prepared = AutoChartPreparedTable(
            snapshot: snapshot,
            profiles: profiles,
            fingerprint: fingerprint,
            estimatedCost:
                tableCostLimit > 0
                ? estimatedTableCost(
                    snapshot: snapshot,
                    profiles: profiles,
                    key: tableKey,
                    limit: tableCostLimit)
                : nil,
            cacheConfigurationRevision: cacheConfiguration.revision)
        return core(
            table: cacheTable(prepared, for: tableKey) ?? prepared,
            tableKey: tableKey,
            recommendation: recommendation)
    }

    private func core(
        table: AutoChartPreparedTable,
        tableKey: AutoChartRenderTableCacheKey,
        recommendation: AutoChartRecommendation
    ) -> AutoChartRenderCore {
        let key = AutoChartRenderCacheKey(
            table: tableKey,
            specification: recommendation.specification)
        if let cached = value(for: key, matching: table) { return cached }
        let specification = recommendation.specification
        let data = AutoChartDataPreparation.data(
            snapshot: table.snapshot,
            specification: specification,
            profiles: table.profiles)
        let core = AutoChartRenderCore(
            table: table,
            data: data,
            validation: AutoChartEngine.validate(
                specification: specification,
                snapshot: table.snapshot,
                profiles: table.profiles,
                preparedData: data),
            presentation: AutoChartRenderPresentation(
                snapshot: table.snapshot,
                specification: specification,
                profiles: table.profiles,
                data: data))
        insert(core, for: key, specification: specification)
        return core
    }

    private func tableValue(
        for key: AutoChartRenderTableCacheKey
    ) -> AutoChartPreparedTable? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = tableEntries[key] else { return nil }
        tableRecency.removeAll { $0 == key }
        tableRecency.append(key)
        return value
    }

    private func tableValue(
        for key: AutoChartRenderTableCacheKey,
        matching snapshot: AutoChartSnapshot
    ) -> AutoChartPreparedTable? {
        lock.lock()
        guard let value = tableEntries[key] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let matches = value.snapshot.hasSameContent(as: snapshot)
        lock.lock()
        defer { lock.unlock() }
        guard let current = tableEntries[key], current === value
        else { return nil }
        guard matches else {
            // Content no longer matches this key, so every render entry under
            // it, render-owned snapshots included, was built from stale data.
            removeTable(for: key, invalidatingRenderEntries: true)
            return nil
        }
        tableRecency.removeAll { $0 == key }
        tableRecency.append(key)
        return value
    }

    /// Reuses a snapshot already retained and budgeted by the render layer.
    /// Identity and version are the caller's content-stability contract.
    private func renderOwnedTableValue(
        for key: AutoChartRenderTableCacheKey
    ) -> AutoChartPreparedTable? {
        lock.lock()
        defer { lock.unlock() }
        guard !activeConfiguration.isTableCachingEnabled else { return nil }
        let shared = tableEntries[key]
        // Most recent first, and past the newest entry when that one happens to
        // hold the shared table rather than a render-owned snapshot.
        for renderKey in recency.reversed() {
            guard renderKey.table == key, let value = entries[renderKey],
                value.table !== shared
            else { continue }
            return value.table
        }
        return nil
    }

    /// Reuses render-owned storage after fingerprint lookup confirms the key and
    /// a full comparison confirms the snapshot content.
    private func renderOwnedTableValue(
        for key: AutoChartRenderTableCacheKey,
        matching snapshot: AutoChartSnapshot
    ) -> AutoChartPreparedTable? {
        lock.lock()
        guard !activeConfiguration.isTableCachingEnabled else {
            lock.unlock()
            return nil
        }
        var seen: Set<ObjectIdentifier> = []
        let candidates = recency.reversed().compactMap { renderKey -> AutoChartPreparedTable? in
            guard renderKey.table == key,
                let table = entries[renderKey]?.table,
                tableEntries[key] !== table,
                seen.insert(ObjectIdentifier(table)).inserted
            else { return nil }
            return table
        }
        lock.unlock()

        for candidate in candidates where candidate.snapshot.hasSameContent(as: snapshot) {
            lock.lock()
            let isRetained = !activeConfiguration.isTableCachingEnabled
                && entries.contains { renderKey, value in
                    renderKey.table == key && value.table === candidate
                }
            lock.unlock()
            if isRetained { return candidate }
        }
        return nil
    }

    private func value(
        for key: AutoChartRenderCacheKey
    ) -> AutoChartRenderCore? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        touchRender(for: key, table: value.table)
        return value
    }

    private func value(
        for key: AutoChartRenderCacheKey,
        matching table: AutoChartPreparedTable
    ) -> AutoChartRenderCore? {
        lock.lock()
        guard let value = entries[key] else {
            lock.unlock()
            return nil
        }
        if value.table === table {
            touchRender(for: key, table: table)
            lock.unlock()
            return value
        }
        lock.unlock()

        let matches = value.table.snapshot.hasSameContent(as: table.snapshot)
        lock.lock()
        defer { lock.unlock() }
        guard let current = entries[key], current.table === value.table else {
            return nil
        }
        guard matches else {
            removeRender(for: key)
            return nil
        }
        touchRender(for: key, table: current.table)
        return current
    }

    /// Updates render recency and, when applicable, its shared table entry.
    ///
    /// - Precondition: The caller already holds `lock`.
    private func touchRender(
        for key: AutoChartRenderCacheKey,
        table: AutoChartPreparedTable
    ) {
        recency.removeAll { $0 == key }
        recency.append(key)
        if tableEntries[key.table] === table {
            tableRecency.removeAll { $0 == key.table }
            tableRecency.append(key.table)
        }
    }

    private func insert(
        _ value: AutoChartRenderCore,
        for key: AutoChartRenderCacheKey,
        specification: AutoChartSpecification
    ) {
        let cacheConfiguration = configurationSnapshot()
        guard cacheConfiguration.value.isRenderCachingEnabled,
            let renderCost = estimatedCost(
            data: value.data,
            presentation: value.presentation,
            validation: value.validation,
            specification: specification,
            limit: cacheConfiguration.value.maximumRenderCost)
        else { return }
        if cacheConfiguration.value.isTableCachingEnabled {
            _ = cacheTable(
                value.table,
                for: key.table,
                expectedConfigurationRevision: cacheConfiguration.revision)
        }
        lock.lock()
        defer { lock.unlock() }
        guard cacheConfiguration.revision == configurationRevision else { return }
        var ownedTable: (table: AutoChartPreparedTable, cost: Int)?
        if tableEntries[key.table] !== value.table {
            guard let tableCost = value.table.estimatedCost else { return }
            // Only a table this entry would newly introduce has to fit the
            // budget; joining an already-charged snapshot costs the entry alone.
            if renderTableRetainers[ObjectIdentifier(value.table)] == nil {
                var projected = renderCost
                guard
                    add(
                        tableCost,
                        to: &projected,
                        limit: activeConfiguration.maximumRenderCost)
                else { return }
            }
            ownedTable = (value.table, tableCost)
        }
        releaseRenderTable(for: key)
        if let previousCost = costs[key] { totalCost -= previousCost }
        entries[key] = value
        costs[key] = renderCost
        totalCost += renderCost
        if let ownedTable {
            retainRenderTable(ownedTable.table, cost: ownedTable.cost, for: key)
        }
        recency.removeAll { $0 == key }
        recency.append(key)
        trimRenderLocked()
    }

    private func cacheTable(
        _ value: AutoChartPreparedTable,
        for key: AutoChartRenderTableCacheKey,
        expectedConfigurationRevision: UInt64? = nil
    ) -> AutoChartPreparedTable? {
        let maximumAttempts = 3
        var attempts = 0
        while attempts < maximumAttempts {
            lock.lock()
            if let expectedConfigurationRevision,
                expectedConfigurationRevision != configurationRevision
            {
                lock.unlock()
                return nil
            }
            if let existing = tableEntries[key] {
                // Storing a render entry commonly reuses the same prepared table.
                if existing === value {
                    tableRecency.removeAll { $0 == key }
                    tableRecency.append(key)
                    lock.unlock()
                    return existing
                }
                lock.unlock()

                let matches = existing.snapshot.hasSameContent(as: value.snapshot)
                lock.lock()
                guard expectedConfigurationRevision == nil
                        || expectedConfigurationRevision == configurationRevision,
                    let current = tableEntries[key], current === existing
                else {
                    lock.unlock()
                    attempts += 1
                    continue
                }
                if matches {
                    tableRecency.removeAll { $0 == key }
                    tableRecency.append(key)
                    lock.unlock()
                    return existing
                }
                // Content no longer matches this key, so every render entry under
                // it, render-owned snapshots included, was built from stale data.
                removeTable(for: key, invalidatingRenderEntries: true)
            }
            guard activeConfiguration.isTableCachingEnabled,
                value.cacheConfigurationRevision == configurationRevision,
                let estimatedCost = value.estimatedCost,
                estimatedCost <= activeConfiguration.maximumTableCost
            else {
                lock.unlock()
                return nil
            }
            tableEntries[key] = value
            tableTotalCost += estimatedCost
            tableRecency.removeAll { $0 == key }
            tableRecency.append(key)
            while tableRecency.count > activeConfiguration.maximumTableEntries
                || tableTotalCost > activeConfiguration.maximumTableCost
            {
                removeTable(for: tableRecency.removeFirst())
            }
            let result = tableEntries[key]
            lock.unlock()
            return result
        }
        return nil
    }

    /// Removes the shared table entry for `key`.
    ///
    /// - Parameter invalidatingRenderEntries: Pass `true` when `key` has been
    ///   found to no longer describe the data behind it, so every render entry
    ///   under that key is stale — including render-owned snapshots this cache
    ///   would otherwise keep. Plain eviction passes `false` and preserves
    ///   independently owned renders.
    private func removeTable(
        for key: AutoChartRenderTableCacheKey,
        invalidatingRenderEntries: Bool = false
    ) {
        let removed = tableEntries.removeValue(forKey: key)
        if let removed {
            tableTotalCost -= removed.estimatedCost ?? 0
        }
        if removed != nil || invalidatingRenderEntries {
            let related = recency.filter { renderKey in
                guard renderKey.table == key else { return false }
                return invalidatingRenderEntries || entries[renderKey]?.table === removed
            }
            for renderKey in related {
                removeRender(for: renderKey)
            }
        }
        tableRecency.removeAll { $0 == key }
    }

    /// Removes one render entry and its accounted cost.
    ///
    /// - Precondition: The caller already holds `lock`.
    private func removeRender(for key: AutoChartRenderCacheKey) {
        entries.removeValue(forKey: key)
        totalCost -= costs.removeValue(forKey: key) ?? 0
        releaseRenderTable(for: key)
        recency.removeAll { $0 == key }
    }

    /// Charges `table` to the render budget on first retention only.
    ///
    /// - Precondition: The caller already holds `lock`.
    private func retainRenderTable(
        _ table: AutoChartPreparedTable,
        cost: Int,
        for key: AutoChartRenderCacheKey
    ) {
        let id = ObjectIdentifier(table)
        renderEntryTables[key] = id
        if renderTableRetainers[id] == nil {
            renderTableRetainers[id] = []
            renderTableCosts[id] = cost
            totalCost += cost
        }
        renderTableRetainers[id]?.insert(key)
    }

    /// Drops `key` from its render-owned table, refunding the table once the
    /// last retaining entry is gone.
    ///
    /// - Precondition: The caller already holds `lock`.
    private func releaseRenderTable(for key: AutoChartRenderCacheKey) {
        guard let id = renderEntryTables.removeValue(forKey: key),
            var retainers = renderTableRetainers[id]
        else { return }
        retainers.remove(key)
        if retainers.isEmpty {
            renderTableRetainers.removeValue(forKey: id)
            totalCost -= renderTableCosts.removeValue(forKey: id) ?? 0
        } else {
            renderTableRetainers[id] = retainers
        }
    }

    private func estimatedTableCost(
        snapshot: AutoChartSnapshot,
        profiles: [AutoChartColumnID: AutoChartColumnProfile],
        key: AutoChartRenderTableCacheKey,
        limit: Int
    ) -> Int? {
        let storageCost = snapshot.estimatedStorageCost
        guard storageCost <= limit else { return nil }
        var cost = storageCost
        guard add(128, to: &cost, limit: limit),
            add(key.tableType.utf8.count, to: &cost, limit: limit),
            add(key.tableIdentity?.utf8.count ?? 0, to: &cost, limit: limit),
            add(key.contentIdentity.utf8.count, to: &cost, limit: limit)
        else { return nil }
        for profile in profiles.values {
            guard add(160, to: &cost, limit: limit),
                add(
                    profile.temporalValues.count,
                    multipliedBy: MemoryLayout<Date>.stride,
                    to: &cost,
                    limit: limit)
            else { return nil }
        }
        return cost
    }

    private func estimatedCost(
        data: [AutoChartDatum],
        presentation: AutoChartRenderPresentation,
        validation: AutoChartValidationResult,
        specification: AutoChartSpecification,
        limit: Int
    ) -> Int? {
        var cost = 256
        guard
            add(
                specification.title.utf8.count,
                to: &cost,
                limit: limit)
        else { return nil }
        let presentationTitles = [
            presentation.xTitle, presentation.yTitle,
            presentation.seriesTitle, presentation.facetTitle,
        ]
        for title in presentationTitles {
            guard add(title.utf8.count, to: &cost, limit: limit) else { return nil }
        }
        for id in specification.encoding.columnIDs {
            guard add(id.rawValue.utf8.count, to: &cost, limit: limit) else {
                return nil
            }
        }
        for datum in data {
            guard add(256, to: &cost, limit: limit) else {
                return nil
            }
            let strings: [String?] = [
                datum.id, datum.xIdentity, datum.xLabel, datum.yIdentity,
                datum.yLabel, datum.seriesIdentity, datum.series,
                datum.facetIdentity, datum.facet,
            ]
            for string in strings.compactMap({ $0 }) {
                guard add(string.utf8.count, to: &cost, limit: limit) else {
                    return nil
                }
            }
            for rowID in datum.sourceRowIDs {
                guard add(32, to: &cost, limit: limit),
                    add(rowID.rawValue.utf8.count, to: &cost, limit: limit)
                else { return nil }
            }
        }
        let labelDictionaries = [
            presentation.xDisplayLabels, presentation.yDisplayLabels,
            presentation.seriesDisplayLabels, presentation.facetDisplayLabels,
        ]
        for labels in labelDictionaries {
            for (identity, label) in labels {
                guard add(64, to: &cost, limit: limit),
                    add(identity.utf8.count, to: &cost, limit: limit),
                    add(label.utf8.count, to: &cost, limit: limit)
                else { return nil }
            }
        }
        for category in presentation.sharedXCategoryDomain {
            guard add(32, to: &cost, limit: limit),
                add(category.utf8.count, to: &cost, limit: limit)
            else { return nil }
        }
        for issue in validation.issues {
            guard add(64, to: &cost, limit: limit),
                add(issue.message.utf8.count, to: &cost, limit: limit)
            else { return nil }
        }
        return cost
    }

}

private extension AutoChartRenderPreparationCache {
    func add(_ amount: Int, to cost: inout Int, limit: Int) -> Bool {
        guard amount >= 0, amount <= limit - cost else { return false }
        cost += amount
        return true
    }

    func add(
        _ count: Int,
        multipliedBy unitCost: Int,
        to cost: inout Int,
        limit: Int
    ) -> Bool {
        guard count >= 0, unitCost >= 0,
            count <= (limit - cost) / max(1, unitCost)
        else { return false }
        cost += count * unitCost
        return true
    }

    var configuration: AutoChartRenderCacheConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return activeConfiguration
    }

    var tableEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tableEntries.count
    }

    var renderEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var renderCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    func configure(_ configuration: AutoChartRenderCacheConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard configuration != activeConfiguration else { return }
        activeConfiguration = configuration
        configurationRevision &+= 1
        trimLocked()
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        // Prevent preparation already in flight from repopulating the cache after
        // an explicit purge or memory-pressure notification.
        configurationRevision &+= 1
        tableEntries.removeAll(keepingCapacity: false)
        tableRecency.removeAll(keepingCapacity: false)
        tableTotalCost = 0
        entries.removeAll(keepingCapacity: false)
        costs.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        renderTableCosts.removeAll(keepingCapacity: false)
        renderTableRetainers.removeAll(keepingCapacity: false)
        renderEntryTables.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    private func configurationSnapshot() -> ConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConfigurationSnapshot(
            value: activeConfiguration,
            revision: configurationRevision)
    }

    /// Evicts table and render entries that exceed the active limits.
    ///
    /// - Precondition: The caller already holds `lock`, which is not recursive.
    func trimLocked() {
        while tableRecency.count > activeConfiguration.maximumTableEntries
            || tableTotalCost > activeConfiguration.maximumTableCost
        {
            removeTable(for: tableRecency.removeFirst())
        }
        trimRenderLocked()
    }

    /// Evicts render entries beyond the active limits.
    ///
    /// - Precondition: The caller already holds `lock`.
    private func trimRenderLocked() {
        while !recency.isEmpty,
            recency.count > activeConfiguration.maximumRenderEntries
                || totalCost > activeConfiguration.maximumRenderCost
        {
            removeRender(for: recency[0])
        }
    }
}

#if canImport(Charts) && canImport(SwiftUI)

private enum AutoChartFacetSelectionAxis {
    case x
    case y
}

/// A native Swift Charts view for an AutoTableCharts recommendation or specification.
///
/// The view reuses cached snapshot, profiling, validation, and mark preparation
/// when table identity permits. Preparation never mutates source storage, and
/// bound selection state preserves contributing ``AutoChartRowID`` values.
public struct AutoChartView: View {
    private let snapshot: AutoChartSnapshot
    private let recommendation: AutoChartRecommendation
    private let validation: AutoChartValidationResult
    private let data: [AutoChartDatum]
    private let sizeBounds: (minimum: Double, maximum: Double)?
    private let sharedYDomain: ClosedRange<Double>?
    private let sharedXDateDomain: ClosedRange<Date>?
    private let sharedXNumberDomain: ClosedRange<Double>?
    private let sharedXCategoryDomain: [String]
    private let facetBaseFamily: AutoChartFamily?
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
    private let timeZoomValueCount: Int
    private let timeZoomSpan: TimeInterval
    private let numberZoomValueCount: Int
    private let numberZoomSpan: Double
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
        let core = AutoChartRenderPreparationCache.shared.core(
            table: table,
            recommendation: recommendation)
        let presentation = core.presentation
        self.snapshot = core.snapshot
        self.recommendation = recommendation
        validation = core.validation
        data = core.data
        sizeBounds = presentation.sizeBounds
        sharedYDomain = presentation.sharedYDomain
        sharedXDateDomain = presentation.sharedXDateDomain
        sharedXNumberDomain = presentation.sharedXNumberDomain
        sharedXCategoryDomain = presentation.sharedXCategoryDomain
        facetBaseFamily = presentation.facetBaseFamily
        self._selection = selection
        self.interaction = interaction
        chartHeight = height
        snapshotFingerprint = core.fingerprint
        xTitle = presentation.xTitle
        yTitle = presentation.yTitle
        seriesTitle = presentation.seriesTitle
        facetTitle = presentation.facetTitle
        xSemanticType = presentation.xSemanticType
        xDisplayLabels = presentation.xDisplayLabels
        yDisplayLabels = presentation.yDisplayLabels
        seriesDisplayLabels = presentation.seriesDisplayLabels
        facetDisplayLabels = presentation.facetDisplayLabels
        uniqueXCount = presentation.uniqueXCount
        timeZoomValueCount = presentation.timeZoomValueCount
        timeZoomSpan = presentation.timeZoomSpan
        numberZoomValueCount = presentation.numberZoomValueCount
        numberZoomSpan = presentation.numberZoomSpan
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
                specification.encoding.y.flatMap { snapshot.column($0) }
                    .map(AutoChartProfiler.displayName) ?? "Value"
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
                horizontalBarMark(
                    for: datum,
                    groupsSeries: specification.family == .groupedBar,
                    stacking: stackingMethod)
            }
            .chartXAxisLabel(yTitle)
            .chartYAxisLabel(xTitle)
            selectableCategoryY(verticalZoom(chart, categoryCount: uniqueXCount))
        } else {
            let chart = Chart(data) { datum in
                verticalBarMark(
                    for: datum,
                    groupsSeries: specification.family == .groupedBar,
                    stacking: stackingMethod)
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
                lineMarks(
                    for: datum,
                    x: datum.xDate ?? .distantPast,
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else if xSemanticType == .quantitative {
            let chart = Chart(data) { datum in
                lineMarks(
                    for: datum,
                    x: datum.xNumber ?? 0,
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            selectableNumberX(numberZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                lineMarks(
                    for: datum,
                    x: xCategoryValue(for: datum),
                    includesArea: specification.family == .area,
                    includesPoint: specification.family == .pointLine)
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
                scatterMark(
                    for: datum,
                    x: datum.xDate ?? .distantPast,
                    symbolSize: symbolSize(for: datum.size))
            }
            .chartXAxisLabel(xTitle)
            .chartYAxisLabel(yTitle)
            .environment(\.timeZone, .gmt)
            selectableDateX(timeZoom(chart))
        } else {
            let chart = Chart(data) { datum in
                scatterMark(
                    for: datum,
                    x: datum.xNumber ?? 0,
                    symbolSize: symbolSize(for: datum.size))
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
                AutoChartAccessibility.heatmapLabel(
                    for: datum,
                    xCategoryName: disambiguatedCategoryValue(
                        identity: datum.xIdentity,
                        label: datum.xLabel,
                        labels: xLabels),
                    yCategoryName: disambiguatedCategoryValue(
                        identity: datum.yIdentity,
                        label: datum.yLabel,
                        labels: yLabels))
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

    @ChartContentBuilder
    private func horizontalBarMark(
        for datum: AutoChartDatum,
        groupsSeries: Bool,
        stacking: MarkStackingMethod
    ) -> some ChartContent {
        styledBarMark(
            BarMark(
                x: .value(yTitle, datum.yNumber ?? 0),
                y: .value(xTitle, xCategoryValue(for: datum)),
                stacking: groupsSeries ? .unstacked : stacking),
            for: datum,
            groupsSeries: groupsSeries)
    }

    @ChartContentBuilder
    private func verticalBarMark(
        for datum: AutoChartDatum,
        groupsSeries: Bool,
        stacking: MarkStackingMethod
    ) -> some ChartContent {
        styledBarMark(
            BarMark(
                x: .value(xTitle, xCategoryValue(for: datum)),
                y: .value(yTitle, datum.yNumber ?? 0),
                stacking: groupsSeries ? .unstacked : stacking),
            for: datum,
            groupsSeries: groupsSeries)
    }

    @ChartContentBuilder
    private func styledBarMark(
        _ mark: BarMark,
        for datum: AutoChartDatum,
        groupsSeries: Bool
    ) -> some ChartContent {
        if groupsSeries {
            mark
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .position(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else if specification.encoding.series != nil {
            mark
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else {
            mark
                .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
    }

    @ChartContentBuilder
    private func lineMarks<X: Plottable>(
        for datum: AutoChartDatum,
        x: X,
        includesArea: Bool,
        includesPoint: Bool
    ) -> some ChartContent {
        if specification.encoding.series != nil {
            if includesArea {
                AreaMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .opacity(0.45)
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            LineMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0),
                series: .value(seriesTitle, seriesValue(for: datum))
            )
            .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
            .lineStyle(by: .value(seriesTitle, seriesValue(for: datum)))
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if includesPoint {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        } else {
            if includesArea {
                AreaMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0),
                    stacking: .unstacked
                )
                .opacity(0.45)
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
            LineMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .accessibilityLabel(markAccessibilityLabel(for: datum))
            if includesPoint {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        }
    }

    @ChartContentBuilder
    private func scatterMark<X: Plottable>(
        for datum: AutoChartDatum,
        x: X,
        symbolSize: Double? = nil
    ) -> some ChartContent {
        if specification.encoding.series != nil {
            if let symbolSize {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .symbolSize(symbolSize)
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            } else {
                PointMark(
                    x: .value(xTitle, x),
                    y: .value(yTitle, datum.yNumber ?? 0)
                )
                .foregroundStyle(by: .value(seriesTitle, seriesValue(for: datum)))
                .symbol(by: .value(seriesTitle, seriesValue(for: datum)))
                .accessibilityLabel(markAccessibilityLabel(for: datum))
            }
        } else if let symbolSize {
            PointMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .symbolSize(symbolSize)
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        } else {
            PointMark(
                x: .value(xTitle, x),
                y: .value(yTitle, datum.yNumber ?? 0)
            )
            .accessibilityLabel(markAccessibilityLabel(for: datum))
        }
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
        let dateDomain =
            sharedXDateDomain
            ?? Date.distantPast...Date.distantFuture
        let numberDomain = sharedXNumberDomain ?? 0...1
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(facetKeys, id: \.self) { facetKey in
                    let facetData = facets[facetKey] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Text(facetKey.flatMap { facetDisplayLabels[$0] } ?? "Missing value")
                            .font(.caption.weight(.semibold))
                        if facetBaseFamily == .line, xSemanticType == .temporal {
                            let chart = Chart(facetData) { datum in
                                lineMarks(
                                    for: datum,
                                    x: datum.xDate ?? .distantPast,
                                    includesArea: false,
                                    includesPoint: true)
                            }
                            .chartXScale(domain: dateDomain)
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, .gmt)
                            selectableFacet(chart, axis: .x, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                        } else if facetBaseFamily == .line {
                            let chart = Chart(facetData) { datum in
                                lineMarks(
                                    for: datum,
                                    x: xCategoryValue(for: datum),
                                    includesArea: false,
                                    includesPoint: true)
                            }
                            .chartXScale(domain: sharedXCategoryDomain)
                            .chartYScale(domain: yDomain)
                            selectableFacet(chart, axis: .x, as: String.self) { value in
                                select(category: value, in: facetData)
                            }
                        } else if facetBaseFamily == .scatter,
                            xSemanticType == .temporal
                        {
                            let chart = Chart(facetData) { datum in
                                scatterMark(
                                    for: datum,
                                    x: datum.xDate ?? .distantPast)
                            }
                            .chartXScale(domain: dateDomain)
                            .chartYScale(domain: yDomain)
                            .environment(\.timeZone, .gmt)
                            selectableFacet(chart, axis: .x, as: Date.self) { value in
                                select(date: value, in: facetData)
                            }
                        } else if facetBaseFamily == .scatter {
                            let chart = Chart(facetData) { datum in
                                scatterMark(
                                    for: datum,
                                    x: datum.xNumber ?? 0)
                            }
                            .chartXScale(domain: numberDomain)
                            .chartYScale(domain: yDomain)
                            selectableFacet(chart, axis: .x, as: Double.self) { value in
                                select(number: value, in: facetData)
                            }
                        } else {
                            if specification.orientation == .horizontal {
                                let chart = Chart(facetData) { datum in
                                    horizontalBarMark(
                                        for: datum,
                                        groupsSeries: specification.encoding.series != nil,
                                        stacking: .standard)
                                }
                                .chartXScale(domain: yDomain)
                                .chartYScale(domain: sharedXCategoryDomain)
                                selectableFacet(chart, axis: .y, as: String.self) { value in
                                    select(category: value, in: facetData)
                                }
                            } else {
                                let chart = Chart(facetData) { datum in
                                    verticalBarMark(
                                        for: datum,
                                        groupsSeries: specification.encoding.series != nil,
                                        stacking: .standard)
                                }
                                .chartXScale(domain: sharedXCategoryDomain)
                                .chartYScale(domain: yDomain)
                                selectableFacet(chart, axis: .x, as: String.self) { value in
                                    select(category: value, in: facetData)
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private func xCategoryValue(for datum: AutoChartDatum) -> String {
        disambiguatedCategoryValue(
            identity: datum.xIdentity,
            label: datum.xLabel,
            labels: xDisplayLabels)
    }

    private func seriesValue(for datum: AutoChartDatum) -> String {
        guard specification.encoding.series != nil else { return seriesTitle }
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
        AutoChartAccessibility.markLabel(
            for: datum,
            family: specification.family,
            xSemanticType: xSemanticType,
            xCategoryName: xCategoryValue(for: datum),
            seriesName: specification.encoding.series == nil
                ? nil : seriesValue(for: datum),
            facetDescription: specification.encoding.facet == nil
                ? nil : "\(facetTitle): \(facetValue(for: datum))")
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
    private func selectableFacet<Content: View, Value: Plottable>(
        _ content: Content,
        axis: AutoChartFacetSelectionAxis,
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
                                let location = CGPoint(
                                    x: value.location.x - frame.origin.x,
                                    y: value.location.y - frame.origin.y)
                                guard location.x >= 0, location.x <= frame.width,
                                    location.y >= 0, location.y <= frame.height
                                else { return }
                                let selected: Value? =
                                    switch axis {
                                    case .x: proxy.value(atX: location.x)
                                    case .y: proxy.value(atY: location.y)
                                    }
                                guard let selected else { return }
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
        if interaction == .explore, timeZoomValueCount > 12 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: max(86_400, timeZoomSpan / zoomScale))
                .simultaneousGesture(zoomGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private func numberZoom<Content: View>(_ content: Content) -> some View {
        if interaction == .explore, numberZoomValueCount > 30 {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: numberZoomSpan / zoomScale)
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
        guard let nearestDate = matches.first?.xDate else {
            selection = nil
            return
        }
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
        guard let nearestNumber = matches.first?.xNumber else {
            selection = nil
            return
        }
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
        selection = AutoChartSelectionPreparation.selection(
            for: matches,
            label: label,
            aggregation: specification.aggregation)
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
