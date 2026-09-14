import Foundation
import AutoTableCharts

/// Value-only input for an Audio Graph. Keeping UIKit/AppKit objects out of
/// the SwiftUI view state makes descriptor reconstruction deterministic.
struct AutoChartAudioGraphDescriptor: @unchecked Sendable {
    enum XAxis {
        case categorical(title: String, order: [String])
        case numeric(
            title: String,
            range: ClosedRange<Double>,
            valueDescription: (Double) -> String)
    }

    enum XValue {
        case category(String)
        case number(Double)
    }

    struct Point {
        var x: XValue
        var y: Double
        var label: String
        var additionalValue: Double?
    }

    struct Series {
        var name: String
        var isContinuous: Bool
        var points: [Point]
    }

    var title: String?
    var xAxis: XAxis
    var yTitle: String
    var yRange: ClosedRange<Double>
    var yValueDescription: (Double) -> String
    var additionalAxis: (
        title: String,
        range: ClosedRange<Double>,
        valueDescription: (Double) -> String
    )?
    var series: [Series]

}

/// Callback-free evidence computed once with the presentation payload.
struct AutoChartAudioGraphAvailability: Sendable {
    enum XAxis: Sendable {
        case categorical
        case numeric(fallbackRange: ClosedRange<Double>)
        case temporal(fallbackRange: ClosedRange<Double>)
    }

    let xAxis: XAxis
    let fallbackYRange: ClosedRange<Double>
}

/// A single-presentation memo owned by a view, never by a presenter payload.
final class AutoChartAudioGraphDescriptorCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (AutoChartPresentationRequestID, AutoChartAudioGraphDescriptor)?

    func value(
        for requestID: AutoChartPresentationRequestID,
        building: () -> AutoChartAudioGraphDescriptor
    ) -> AutoChartAudioGraphDescriptor {
        if let value = lock.withLock({ cached?.0 == requestID ? cached?.1 : nil }) {
            return value
        }
        // Host callbacks can re-enter presentation; never build under the lock.
        let proposed = building()
        return lock.withLock {
            if let cached, cached.0 == requestID { return cached.1 }
            cached = (requestID, proposed)
            return proposed
        }
    }

    #if canImport(SwiftUI) && canImport(Accessibility)
    private final class AppliedPresentation {
        let requestID: AutoChartPresentationRequestID
        init(_ requestID: AutoChartPresentationRequestID) { self.requestID = requestID }
    }

    // Weak keys do not extend the lifetime of framework-owned AX descriptors.
    private let applied = NSMapTable<AXChartDescriptor, AppliedPresentation>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    func isApplied(_ requestID: AutoChartPresentationRequestID, to target: AXChartDescriptor) -> Bool {
        lock.withLock { applied.object(forKey: target)?.requestID == requestID }
    }

    func record(_ requestID: AutoChartPresentationRequestID, for target: AXChartDescriptor) {
        lock.withLock { applied.setObject(AppliedPresentation(requestID), forKey: target) }
    }
    #endif
}

#if canImport(Combine)
import Combine
extension AutoChartAudioGraphDescriptorCache: ObservableObject {}
#endif

/// Value formatting stays lazy until Accessibility requests the descriptor.
struct AutoChartLazyAudioGraphDescriptor: Sendable {
    let requestID: AutoChartPresentationRequestID
    let cache: AutoChartAudioGraphDescriptorCache?
    let build: @Sendable () -> AutoChartAudioGraphDescriptor

    func cached(in cache: AutoChartAudioGraphDescriptorCache) -> Self {
        Self(requestID: requestID, cache: cache, build: build)
    }

    func descriptor() -> AutoChartAudioGraphDescriptor {
        cache?.value(for: requestID, building: build) ?? build()
    }
}

private struct AutoChartAudioGraphSeriesKey: Hashable {
    var series: String?
    var facet: String?
    var secondaryCategory: String?

    var name: String {
        [series, facet, secondaryCategory]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private enum AutoChartAudioGraphXAxisKind {
    case categorical
    case numeric
    case temporal
}

private func nondegenerateAudioGraphRange(
    _ range: ClosedRange<Double>
) -> ClosedRange<Double> {
    guard range.lowerBound == range.upperBound else { return range }
    let value = range.lowerBound
    let greatest = Double.greatestFiniteMagnitude
    let padding = max(abs(value) * 0.05, 1)
    let lower = max(value - padding, -greatest)
    let upper = min(value + padding, greatest)
    return lower...upper
}

private func audioGraphRange(_ values: [Double]) -> ClosedRange<Double>? {
    guard let minimum = values.min(), let maximum = values.max() else { return nil }
    return nondegenerateAudioGraphRange(minimum...maximum)
}

private func audioGraphMidpoint(_ lower: Double, _ upper: Double) -> Double {
    lower.sign == upper.sign
        ? lower + (upper - lower) / 2
        : lower / 2 + upper / 2
}

private func audioGraphYValue(_ datum: AutoChartDatum) -> Double? {
    guard let value = datum.yNumber ?? datum.median, value.isFinite else { return nil }
    return value
}

private func audioGraphNumericXValue(
    _ datum: AutoChartDatum,
    kind: AutoChartAudioGraphXAxisKind
) -> Double? {
    let value: Double?
    switch kind {
    case .categorical:
        return nil
    case .temporal:
        value = datum.xDate?.timeIntervalSinceReferenceDate
    case .numeric:
        value = datum.xNumber
            ?? datum.lower.flatMap { lower in
                datum.upper.map { audioGraphMidpoint(lower, $0) }
            }
    }
    guard let value, value.isFinite else { return nil }
    return value
}

private func autoChartAudioGraphXAxisKind<RowID: Hashable & Sendable>(
    preparedChart: AutoChartPreparedChart<RowID>,
    specification: AutoChartSpecification
) -> AutoChartAudioGraphXAxisKind {
    let presentation = preparedChart.core.presentation
    if presentation.xSemanticType == .temporal {
        return .temporal
    } else if presentation.xSemanticType == .quantitative
        || specification.family == .histogram
    {
        return .numeric
    } else {
        return .categorical
    }
}

func makeAutoChartAudioGraphAvailability<RowID: Hashable & Sendable>(
    preparedChart: AutoChartPreparedChart<RowID>,
    renderedData: [AutoChartDatum]
) -> AutoChartAudioGraphAvailability? {
    let specification = preparedChart.recommendation.specification
    guard ![.kpi, .range].contains(specification.family) else { return nil }
    let xKind = autoChartAudioGraphXAxisKind(
        preparedChart: preparedChart, specification: specification)
    var xBounds: ClosedRange<Double>?
    var yBounds: ClosedRange<Double>?
    func including(_ value: Double, in bounds: ClosedRange<Double>?) -> ClosedRange<Double> {
        guard let bounds else { return value...value }
        return min(bounds.lowerBound, value)...max(bounds.upperBound, value)
    }
    for datum in renderedData {
        guard let y = audioGraphYValue(datum) else { continue }
        switch xKind {
        case .categorical:
            break
        case .numeric, .temporal:
            guard let x = audioGraphNumericXValue(datum, kind: xKind) else { continue }
            xBounds = including(x, in: xBounds)
        }
        yBounds = including(y, in: yBounds)
    }
    guard let yBounds else { return nil }
    let xAxis: AutoChartAudioGraphAvailability.XAxis
    switch xKind {
    case .categorical:
        xAxis = .categorical
    case .numeric:
        guard let xBounds else { return nil }
        xAxis = .numeric(fallbackRange: nondegenerateAudioGraphRange(xBounds))
    case .temporal:
        guard let xBounds else { return nil }
        xAxis = .temporal(fallbackRange: nondegenerateAudioGraphRange(xBounds))
    }
    return AutoChartAudioGraphAvailability(
        xAxis: xAxis, fallbackYRange: nondegenerateAudioGraphRange(yBounds))
}

func makeAutoChartAudioGraphDescriptor<RowID: Hashable & Sendable>(
    preparedChart: AutoChartPreparedChart<RowID>,
    renderedData: [AutoChartDatum],
    resolved: AutoChartResolvedPresentation,
    displayTitle: String,
    formatters: AutoChartFormatters,
    textResolver: AutoChartTextResolver,
    availability: AutoChartAudioGraphAvailability
) -> AutoChartAudioGraphDescriptor {
    let specification = preparedChart.recommendation.specification
    let core = preparedChart.core
    let profiles = core.table.profiles
    let presentation = core.presentation
    let measureSemantics = core.measureSemantics

    func column(_ id: AutoChartColumnID?) -> AutoChartColumn? {
        id.flatMap { profiles[$0]?.column }
    }
    func category(
        identity: String?,
        value: AutoChartValue?,
        label: String?,
        labels: [String: String],
        fallback: String,
        id: AutoChartColumnID?
    ) -> String {
        categoryValueForSurface(
            identity: identity,
            value: value,
            label: label,
            labels: labels,
            fallback: fallback,
            column: column(id),
            context: .markAccessibility,
            formatters: formatters)
    }
    func xCategory(_ datum: AutoChartDatum) -> String {
        category(
            identity: datum.xIdentity,
            value: datum.xCategoryValue,
            label: datum.xLabel,
            labels: resolved.xDisplayLabels,
            fallback: resolved.missingValue,
            id: specification.encoding.x)
    }
    func seriesCategory(_ datum: AutoChartDatum) -> String {
        category(
            identity: datum.seriesIdentity,
            value: datum.seriesCategoryValue,
            label: datum.series,
            labels: resolved.seriesDisplayLabels,
            fallback: resolved.missingSeries,
            id: specification.encoding.series)
    }
    func facetCategory(_ datum: AutoChartDatum) -> String {
        category(
            identity: datum.facetIdentity,
            value: datum.facetCategoryValue,
            label: datum.facet,
            labels: resolved.facetDisplayLabels,
            fallback: resolved.missingFacet,
            id: specification.encoding.facet)
    }
    func yCategory(_ datum: AutoChartDatum) -> String {
        category(
            identity: datum.yIdentity,
            value: datum.yCategoryValue,
            label: datum.yLabel,
            labels: resolved.yDisplayLabels,
            fallback: resolved.missingValue,
            id: specification.encoding.y)
    }
    func formattedMeasure(_ number: Double) -> String {
        formatters.format(
            AutoChartFormattingRequest(
                column: column(measureSemantics.columnID),
                value: .double(number),
                context: .markAccessibility,
                purpose: measureSemantics.formattingPurpose))
    }
    func markLabel(_ datum: AutoChartDatum, value: Double) -> String {
        let name: String
        if specification.family == .histogram {
            name = resolved.histogramBinAccessibilityLabel(for: datum)
        } else if [
            .bar, .groupedBar, .stackedBar, .normalizedBar, .rankedDot,
            .boxPlot, .donut,
        ].contains(specification.family) {
            name = xCategory(datum)
        } else if let date = datum.xDate {
            name = formatters.format(
                column: column(specification.encoding.x),
                value: .date(date),
                context: .markAccessibility)
        } else if let number = datum.xNumber {
            name = formatters.format(
                column: column(specification.encoding.x),
                value: .double(number),
                context: .markAccessibility)
        } else {
            name = xCategory(datum)
        }
        return AutoChartAccessibility.markLabel(
            name: name,
            series: specification.encoding.series == nil ? nil : seriesCategory(datum),
            facetTitle: specification.encoding.facet == nil ? nil : resolved.facet,
            facetValue: specification.encoding.facet == nil ? nil : facetCategory(datum),
            valueDescription: formattedMeasure(value),
            textResolver: textResolver)
    }
    var pointsBySeries: [AutoChartAudioGraphSeriesKey: [AutoChartAudioGraphDescriptor.Point]] = [:]
    var seriesOrder: [AutoChartAudioGraphSeriesKey] = []
    var categoryOrder: [String] = []
    var seenCategories: Set<String> = []
    var additionalNumbers: [Double] = []
    var everyPointHasFiniteSize = specification.encoding.size != nil

    for datum in renderedData {
        guard let y = audioGraphYValue(datum) else { continue }
        let x: AutoChartAudioGraphDescriptor.XValue
        switch availability.xAxis {
        case .numeric:
            guard let value = audioGraphNumericXValue(datum, kind: .numeric) else { continue }
            x = .number(value)
        case .temporal:
            guard let value = audioGraphNumericXValue(datum, kind: .temporal) else { continue }
            x = .number(value)
        case .categorical:
            let value = xCategory(datum)
            x = .category(value)
            if seenCategories.insert(value).inserted { categoryOrder.append(value) }
        }

        let key = AutoChartAudioGraphSeriesKey(
            series: specification.encoding.series == nil ? nil : seriesCategory(datum),
            facet: specification.encoding.facet == nil ? nil : facetCategory(datum),
            secondaryCategory: specification.family == .heatmap ? yCategory(datum) : nil)
        if pointsBySeries[key] == nil { seriesOrder.append(key) }
        let additional = datum.size.flatMap { $0.isFinite ? $0 : nil }
        everyPointHasFiniteSize = everyPointHasFiniteSize && additional != nil
        let label: String
        if specification.family == .heatmap {
            label = AutoChartAccessibility.heatmapLabel(
                category: xCategory(datum),
                secondaryCategory: yCategory(datum),
                valueDescription: formattedMeasure(y),
                textResolver: textResolver)
        } else {
            label = markLabel(datum, value: y)
        }
        pointsBySeries[key, default: []].append(
            .init(x: x, y: y, label: label, additionalValue: additional))
        if let additional { additionalNumbers.append(additional) }
    }

    let xAxis: AutoChartAudioGraphDescriptor.XAxis
    switch availability.xAxis {
    case .temporal(let fallbackRange):
        let xColumn = column(specification.encoding.x)
        xAxis = .numeric(
            title: resolved.x,
            range: presentation.sharedXDateDomain.map {
                let lower = $0.lowerBound.timeIntervalSinceReferenceDate
                let upper = $0.upperBound.timeIntervalSinceReferenceDate
                return nondegenerateAudioGraphRange(lower...upper)
            } ?? fallbackRange,
            valueDescription: { value in
                formatters.format(
                    column: xColumn,
                    value: .date(Date(timeIntervalSinceReferenceDate: value)),
                    context: .markAccessibility)
            })
    case .numeric(let fallbackRange):
        let xColumn = column(specification.encoding.x)
        xAxis = .numeric(
            title: resolved.x,
            range: presentation.sharedXNumberDomain.map(nondegenerateAudioGraphRange)
                ?? fallbackRange,
            valueDescription: { value in
                formatters.format(
                    column: xColumn,
                    value: .double(value),
                    context: .markAccessibility)
            })
    case .categorical:
        xAxis = .categorical(title: resolved.x, order: categoryOrder)
    }

    let effectiveFamily = specification.family == .faceted
        ? presentation.facetBaseFamily : specification.family
    let continuous = effectiveFamily.map {
        [.line, .pointLine, .area].contains($0)
    } ?? false
    let fallbackSeriesName = resolved.y.isEmpty ? displayTitle : resolved.y
    let audioSeries = seriesOrder.map { key in
        AutoChartAudioGraphDescriptor.Series(
            name: key.name.isEmpty ? fallbackSeriesName : key.name,
            isContinuous: continuous,
            points: pointsBySeries[key] ?? [])
    }
    let sizeColumn = column(specification.encoding.size)
    let additionalAxis = everyPointHasFiniteSize
        ? audioGraphRange(additionalNumbers).map { sizeRange in
            (
                title: resolved.size,
                range: sizeRange,
                valueDescription: { value in
                    formatters.format(
                        column: sizeColumn,
                        value: .double(value),
                        context: .markAccessibility)
                }
            )
        } : nil
    return AutoChartAudioGraphDescriptor(
        title: displayTitle.isEmpty ? nil : displayTitle,
        xAxis: xAxis,
        yTitle: [.histogram, .heatmap].contains(specification.family)
            ? resolved.count : resolved.y,
        yRange: presentation.sharedYDomain.map(nondegenerateAudioGraphRange)
            ?? availability.fallbackYRange,
        yValueDescription: formattedMeasure,
        additionalAxis: additionalAxis,
        series: audioSeries)
}

#if canImport(SwiftUI) && canImport(Accessibility)
import Accessibility
import SwiftUI

extension AutoChartLazyAudioGraphDescriptor: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let target = descriptor().makeChartDescriptor()
        cache?.record(requestID, for: target)
        return target
    }

    func updateChartDescriptor(_ chartDescriptor: AXChartDescriptor) {
        guard cache?.isApplied(requestID, to: chartDescriptor) != true else { return }
        descriptor().updateChartDescriptor(chartDescriptor)
        cache?.record(requestID, for: chartDescriptor)
    }
}

extension AutoChartAudioGraphDescriptor: AXChartDescriptorRepresentable {
    private func axesAndSeries() -> (
        x: any AXDataAxisDescriptor, y: AXNumericDataAxisDescriptor,
        additional: [any AXDataAxisDescriptor], series: [AXDataSeriesDescriptor]
    ) {
        let xDescriptor: any AXDataAxisDescriptor = switch xAxis {
        case .categorical(let title, let order):
            AXCategoricalDataAxisDescriptor(title: title, categoryOrder: order)
        case .numeric(let title, let range, let valueDescription):
            numericAxis(
                title: title,
                range: range,
                valueDescription: valueDescription)
        }
        let yDescriptor = numericAxis(
            title: yTitle,
            range: yRange,
            valueDescription: yValueDescription)
        let usesAdditionalValues = additionalAxis != nil
            && series.flatMap(\.points).allSatisfy { $0.additionalValue != nil }
        let additionalDescriptors: [any AXDataAxisDescriptor] = usesAdditionalValues
            ? additionalAxis.map {
            [numericAxis(
                title: $0.title,
                range: $0.range,
                valueDescription: $0.valueDescription)]
            } ?? []
            : []
        let seriesDescriptors = series.map { series in
            AXDataSeriesDescriptor(
                name: series.name,
                isContinuous: series.isContinuous,
                dataPoints: series.points.map { point in
                    let additionalValues: [AXDataPoint.Value] = usesAdditionalValues
                        ? point.additionalValue.map {
                        [.number($0)]
                        } ?? []
                        : []
                    switch point.x {
                    case .category(let value):
                        return AXDataPoint(
                            x: value,
                            y: point.y,
                            additionalValues: additionalValues,
                            label: point.label)
                    case .number(let value):
                        return AXDataPoint(
                            x: value,
                            y: point.y,
                            additionalValues: additionalValues,
                            label: point.label)
                    }
                })
        }
        return (xDescriptor, yDescriptor, additionalDescriptors, seriesDescriptors)
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let parts = axesAndSeries()
        return AXChartDescriptor(
            title: title, summary: nil, xAxis: parts.x, yAxis: parts.y,
            additionalAxes: parts.additional, series: parts.series)
    }

    func updateChartDescriptor(_ target: AXChartDescriptor) {
        let parts = axesAndSeries()
        target.attributedTitle = nil
        target.title = title
        target.summary = nil
        target.contentDirection = .leftToRight
        target.xAxis = parts.x
        target.yAxis = parts.y
        target.additionalAxes = parts.additional
        target.series = parts.series
    }

    private func numericAxis(
        title: String,
        range: ClosedRange<Double>,
        valueDescription: @escaping (Double) -> String
    ) -> AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(
            title: title,
            range: range,
            gridlinePositions: [
                range.lowerBound,
                audioGraphMidpoint(range.lowerBound, range.upperBound),
                range.upperBound,
            ],
            valueDescriptionProvider: valueDescription)
    }
}
#endif
