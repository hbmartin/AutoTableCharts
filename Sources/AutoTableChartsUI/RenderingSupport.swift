#if ATC_TEST_HOOKS && canImport(SwiftUI) && canImport(Charts)
import SwiftUI
#if canImport(Accessibility)
import Accessibility
#endif

struct AutoChartViewTestHookState {
    let requestID: AutoChartPresentationRequestID
    let zoomScale: Binding<Double>
    let zoomAnchor: Binding<Double>
    let selectionCount: Int
    let selectedCategory: String?
    let selectedAngle: Double?
    let displayTitle: String
    let renderedXLabels: [String]
    let facetDisplayValues: [String]
    let sharedXCategoryDomain: [String]
    let kpiValueText: String?
    let kpiTitle: String?
    let kpiAccessibilityText: String?
}

@MainActor
final class AutoChartViewTestHooks {
    var observe: (AutoChartViewTestHookState) -> Void = { _ in }
    var didPublishDeferredPresentation: (AutoChartPresentationRequestID) -> Void = { _ in }
    #if canImport(Accessibility)
    var observeAudioGraph: (
        AutoChartAudioGraphViewCache, AutoChartLazyAudioGraphDescriptor
    ) -> Void = { _, _ in }
    #endif
}

private struct AutoChartViewTestHooksKey: EnvironmentKey {
    static let defaultValue: AutoChartViewTestHooks? = nil
}

extension EnvironmentValues {
    var autoChartViewTestHooks: AutoChartViewTestHooks? {
        get { self[AutoChartViewTestHooksKey.self] }
        set { self[AutoChartViewTestHooksKey.self] = newValue }
    }
}

private struct AutoChartViewTestRevisionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var autoChartViewTestRevision: Int {
        get { self[AutoChartViewTestRevisionKey.self] }
        set { self[AutoChartViewTestRevisionKey.self] = newValue }
    }
}
#endif
