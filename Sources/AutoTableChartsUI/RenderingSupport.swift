#if ATC_TEST_HOOKS && canImport(SwiftUI) && canImport(Charts)
import SwiftUI

struct AutoChartViewTestHookState {
    let requestID: AutoChartPresentationRequestID
    let zoomScale: Binding<Double>
    let zoomAnchor: Binding<Double>
    let selectionCount: Int
    let selectedCategory: String?
    let selectedAngle: Double?
}

@MainActor
final class AutoChartViewTestHooks {
    var observe: (AutoChartViewTestHookState) -> Void = { _ in }
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
#endif
