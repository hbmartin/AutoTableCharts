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

/// Defers the comparatively expensive value formatting and descriptor assembly
/// until Accessibility asks SwiftUI for an Audio Graph.
struct AutoChartLazyAudioGraphDescriptor: @unchecked Sendable {
    var build: @Sendable () -> AutoChartAudioGraphDescriptor?
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

func makeAutoChartAudioGraphDescriptor<RowID: Hashable & Sendable>(
    preparedChart: AutoChartPreparedChart<RowID>,
    renderedData: [AutoChartDatum],
    resolved: AutoChartResolvedPresentation,
    displayTitle: String,
    formatters: AutoChartFormatters,
    textResolver: AutoChartTextResolver
) -> AutoChartAudioGraphDescriptor? {
    let specification = preparedChart.recommendation.specification
    guard ![.kpi, .range].contains(specification.family) else { return nil }
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
    func nondegenerateRange(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        guard range.lowerBound == range.upperBound else { return range }
        let padding = max(abs(range.lowerBound) * 0.05, 1)
        return (range.lowerBound - padding)...(range.upperBound + padding)
    }
    func range(_ values: [Double]) -> ClosedRange<Double>? {
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        return nondegenerateRange(minimum...maximum)
    }
    func midpoint(_ lower: Double, _ upper: Double) -> Double {
        lower.sign == upper.sign
            ? lower + (upper - lower) / 2
            : lower / 2 + upper / 2
    }

    let isNumericX = presentation.xSemanticType == .quantitative
        || specification.family == .histogram
    let isTemporalX = presentation.xSemanticType == .temporal
    var pointsBySeries: [AutoChartAudioGraphSeriesKey: [AutoChartAudioGraphDescriptor.Point]] = [:]
    var seriesOrder: [AutoChartAudioGraphSeriesKey] = []
    var categoryOrder: [String] = []
    var seenCategories: Set<String> = []
    var xNumbers: [Double] = []
    var yNumbers: [Double] = []
    var additionalNumbers: [Double] = []
    var everyPointHasFiniteSize = specification.encoding.size != nil

    for datum in renderedData {
        guard let y = datum.yNumber ?? datum.median, y.isFinite else { continue }
        let x: AutoChartAudioGraphDescriptor.XValue
        if isTemporalX, let date = datum.xDate {
            let value = date.timeIntervalSinceReferenceDate
            guard value.isFinite else { continue }
            x = .number(value)
            xNumbers.append(value)
        } else if isNumericX,
            let value = datum.xNumber
                ?? (datum.lower.flatMap { lower in
                    datum.upper.map { midpoint(lower, $0) }
                }),
            value.isFinite
        {
            x = .number(value)
            xNumbers.append(value)
        } else {
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
        yNumbers.append(y)
        if let additional { additionalNumbers.append(additional) }
    }
    guard !yNumbers.isEmpty else { return nil }

    let xAxis: AutoChartAudioGraphDescriptor.XAxis
    if isTemporalX {
        guard let fallbackRange = range(xNumbers) else { return nil }
        let xColumn = column(specification.encoding.x)
        xAxis = .numeric(
            title: resolved.x,
            range: presentation.sharedXDateDomain.map {
                let lower = $0.lowerBound.timeIntervalSinceReferenceDate
                let upper = $0.upperBound.timeIntervalSinceReferenceDate
                return nondegenerateRange(lower...upper)
            } ?? fallbackRange,
            valueDescription: { value in
                formatters.format(
                    column: xColumn,
                    value: .date(Date(timeIntervalSinceReferenceDate: value)),
                    context: .markAccessibility)
            })
    } else if isNumericX {
        guard let fallbackRange = range(xNumbers) else { return nil }
        let xColumn = column(specification.encoding.x)
        xAxis = .numeric(
            title: resolved.x,
            range: presentation.sharedXNumberDomain.map(nondegenerateRange) ?? fallbackRange,
            valueDescription: { value in
                formatters.format(
                    column: xColumn,
                    value: .double(value),
                    context: .markAccessibility)
            })
    } else {
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
        ? range(additionalNumbers).map { sizeRange in
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
        yRange: presentation.sharedYDomain.map(nondegenerateRange)
            ?? range(yNumbers)!,
        yValueDescription: formattedMeasure,
        additionalAxis: additionalAxis,
        series: audioSeries)
}

#if canImport(SwiftUI) && canImport(Accessibility)
import Accessibility
import SwiftUI

extension AutoChartLazyAudioGraphDescriptor: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        guard let descriptor = build() else {
            preconditionFailure("Audio Graph descriptor requested for an unsupported chart")
        }
        return descriptor.makeChartDescriptor()
    }
}

extension AutoChartAudioGraphDescriptor: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
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
        return AXChartDescriptor(
            title: title,
            summary: nil,
            xAxis: xDescriptor,
            yAxis: yDescriptor,
            additionalAxes: additionalDescriptors,
            series: seriesDescriptors)
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
                (range.lowerBound + range.upperBound) / 2,
                range.upperBound,
            ],
            valueDescriptionProvider: valueDescription)
    }
}
#endif
