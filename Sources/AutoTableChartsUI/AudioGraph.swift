#if canImport(SwiftUI) && canImport(Accessibility)
import Accessibility
import Foundation
import SwiftUI

/// Value-only input for an Audio Graph. Keeping UIKit/AppKit objects out of
/// the SwiftUI view state makes descriptor reconstruction deterministic.
struct AutoChartAudioGraphDescriptor: AXChartDescriptorRepresentable {
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
        let additionalDescriptors: [any AXDataAxisDescriptor] = additionalAxis.map {
            [numericAxis(
                title: $0.title,
                range: $0.range,
                valueDescription: $0.valueDescription)]
        } ?? []
        let seriesDescriptors = series.map { series in
            AXDataSeriesDescriptor(
                name: series.name,
                isContinuous: series.isContinuous,
                dataPoints: series.points.map { point in
                    let additionalValues: [AXDataPoint.Value] = point.additionalValue.map {
                        [.number($0)]
                    } ?? []
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
