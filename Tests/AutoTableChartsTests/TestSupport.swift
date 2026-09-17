import Dispatch
import Testing

private final class MainActorRegressionSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func acquire() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        semaphore.signal()
    }
}

private let mainActorRegressionSemaphore = MainActorRegressionSemaphore()

struct MainActorRegressionSerializationTrait: SuiteTrait, TestTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await mainActorRegressionSemaphore.acquire()
        defer { mainActorRegressionSemaphore.release() }
        try Task.checkCancellation()
        try await function()
    }
}

extension Trait where Self == MainActorRegressionSerializationTrait {
    static var serializedMainActorRegression: Self { Self() }
}
