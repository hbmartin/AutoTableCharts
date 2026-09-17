import Foundation
import Testing

private actor MainActorRegressionMutex {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isLocked = false
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]

    func acquire(id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isLocked else {
            isLocked = true
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiterOrder.append(id)
                waiters[id] = Waiter(continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        while let id = waiterOrder.first {
            waiterOrder.removeFirst()
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume(returning: true)
            return
        }
        isLocked = false
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.continuation.resume(returning: false)
    }

    var waitingCount: Int { waiters.count }
}

private enum MainActorRegressionScope {
    @TaskLocal static var holdsMutex = false
}

private let mainActorRegressionMutex = MainActorRegressionMutex()

struct MainActorRegressionSerializationTrait: SuiteTrait, TestTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        if MainActorRegressionScope.holdsMutex {
            try await function()
            return
        }
        let id = UUID()
        guard await mainActorRegressionMutex.acquire(id: id) else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            try await MainActorRegressionScope.$holdsMutex.withValue(true) {
                try await function()
            }
            await mainActorRegressionMutex.release()
        } catch {
            await mainActorRegressionMutex.release()
            throw error
        }
    }
}

extension Trait where Self == MainActorRegressionSerializationTrait {
    static var serializedMainActorRegression: Self { Self() }
}

@Suite(.serializedMainActorRegression)
struct MainActorRegressionSerializationTraitTests {
    @Test(
        .serializedMainActorRegression,
        .timeLimit(.minutes(1)))
    func recursiveTraitApplicationIsReentrant() {
        #expect(MainActorRegressionScope.holdsMutex)
    }

    @Test(.timeLimit(.minutes(1)))
    func mutexIsFIFOAndMutuallyExclusive() async {
        let mutex = MainActorRegressionMutex()
        #expect(await mutex.acquire(id: UUID()))

        let second = Task { await mutex.acquire(id: UUID()) }
        #expect(await waitForMutexWaiters(mutex, count: 1))
        let third = Task { await mutex.acquire(id: UUID()) }
        #expect(await waitForMutexWaiters(mutex, count: 2))

        await mutex.release()
        #expect(await second.value)
        #expect(await mutex.waitingCount == 1)
        await mutex.release()
        #expect(await third.value)
        #expect(await mutex.waitingCount == 0)
        await mutex.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func mutexRemovesCancelledWaiters() async {
        let mutex = MainActorRegressionMutex()
        #expect(await mutex.acquire(id: UUID()))

        let cancelled = Task { await mutex.acquire(id: UUID()) }
        #expect(await waitForMutexWaiters(mutex, count: 1))
        cancelled.cancel()
        #expect(!(await cancelled.value))
        #expect(await mutex.waitingCount == 0)

        await mutex.release()
        #expect(await mutex.acquire(id: UUID()))
        await mutex.release()
    }
}

private func waitForMutexWaiters(
    _ mutex: MainActorRegressionMutex,
    count: Int
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await mutex.waitingCount != count {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
