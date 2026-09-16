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
    let hasSelectionSummary: Bool
    let hasForeignSelectionNotice: Bool
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

enum AutoChartDeferredPresentationOutcome: Equatable {
    case exact
    case cancelled
    case published
}

@MainActor
final class AutoChartViewTestHooks {
    var observe: (AutoChartViewTestHookState) -> Void = { _ in }
    var pressForeignSelectionClearForTesting: (() -> Void)?
    var callbackSchedulerForTesting: AutoChartCallbackWorkScheduler?
    var presentationOwnerDidAppearForTesting: () -> Void = {}
    var foundationNotificationForTesting: () -> Void = {}
    var didPublishDeferredPresentation: (AutoChartPresentationRequestID) -> Void = { _ in }
    var didFinishDeferredPresentation: (
        AutoChartPresentationRequestID, AutoChartDeferredPresentationOutcome
    ) -> Void = { _, _ in }
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

private struct AutoChartViewRevisionForTestingKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var autoChartViewRevisionForTesting: Int {
        get { self[AutoChartViewRevisionForTestingKey.self] }
        set { self[AutoChartViewRevisionForTestingKey.self] = newValue }
    }
}
#endif
