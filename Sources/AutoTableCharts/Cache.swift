import Foundation

private final class AutoChartCompletedAnalysisBox: @unchecked Sendable {
    let value: Any
    let cost: Int

    init<RowID>(_ analysis: AutoChartAnalysis<RowID>) {
        value = analysis
        cost = analysis.estimatedRetainedCost
    }
}

private struct AutoChartProgressEntry {
    var current: AutoChartProgress?
    var callbacks: [UUID: @Sendable (AutoChartProgress) -> Void] = [:]
}

/// A thread-safe cache shared by analyzers and UI sessions.
///
/// Synchronous lookup exposes completed work only. New work and lifecycle
/// operations remain asynchronous because they are coordinated by the cache's
/// analyzer actor.
public final class AutoChartCache: @unchecked Sendable {
    public let configuration: AutoChartAnalyzerConfiguration

    private let lock = NSLock()
    private var completed: [AutoChartRequestID: AutoChartCompletedAnalysisBox] = [:]
    private var recency: [AutoChartRequestID] = []
    private var failures: [AutoChartRequestID: AutoChartFailure] = [:]
    private var progressEntries: [AutoChartRequestID: AutoChartProgressEntry] = [:]

    let engine: AutoChartAnalyzer

    public init(configuration: AutoChartAnalyzerConfiguration = .standard) {
        self.configuration = configuration
        self.engine = AutoChartAnalyzer(configuration: configuration)
    }

    /// Returns a completed typed analysis without starting work or crossing an actor.
    public func completedAnalysis<RowID: Hashable & Sendable>(
        for requestID: AutoChartRequestID,
        as rowIDType: RowID.Type = RowID.self
    ) -> AutoChartAnalysis<RowID>? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = completed[requestID]?.value as? AutoChartAnalysis<RowID> else {
            return nil
        }
        recency.removeAll { $0 == requestID }
        recency.append(requestID)
        return value
    }

    func store<RowID>(_ analysis: AutoChartAnalysis<RowID>) {
        lock.lock()
        defer { lock.unlock() }
        guard configuration.analyses.maximumEntries > 0,
            configuration.maximumRetainedCost > 0,
            analysis.estimatedRetainedCost <= configuration.maximumRetainedCost
        else { return }
        completed[analysis.request] = AutoChartCompletedAnalysisBox(analysis)
        failures.removeValue(forKey: analysis.request)
        recency.removeAll { $0 == analysis.request }
        recency.append(analysis.request)
        trimCompletedLocked()
    }

    func coalescedFailure(
        for requestID: AutoChartRequestID,
        error: any Error,
        stage: AutoChartFailureStage
    ) -> AutoChartFailure {
        lock.withLock {
            let proposed = AutoChartFailure.wrapping(error, stage: stage)
            if let existing = failures[requestID],
                existing.diagnosticID == proposed.diagnosticID
            {
                return existing
            }
            failures[requestID] = proposed
            return proposed
        }
    }

    func registerProgress(
        for requestID: AutoChartRequestID,
        callback: (@Sendable (AutoChartProgress) -> Void)?
    ) -> UUID? {
        guard let callback else { return nil }
        let token = UUID()
        let current: AutoChartProgress? = lock.withLock {
            var entry = progressEntries[requestID] ?? AutoChartProgressEntry()
            entry.callbacks[token] = callback
            progressEntries[requestID] = entry
            return entry.current
        }
        if let current { callback(current) }
        return token
    }

    func reportProgress(
        _ progress: AutoChartProgress,
        for requestID: AutoChartRequestID,
        fallback: (@Sendable (AutoChartProgress) -> Void)?
    ) {
        let callbacks: [@Sendable (AutoChartProgress) -> Void] = lock.withLock {
            guard var entry = progressEntries[requestID] else { return [] }
            entry.current = progress
            progressEntries[requestID] = entry
            return Array(entry.callbacks.values)
        }
        if callbacks.isEmpty {
            fallback?(progress)
        } else {
            callbacks.forEach { $0(progress) }
        }
    }

    func unregisterProgress(for requestID: AutoChartRequestID, token: UUID?) {
        guard let token else { return }
        lock.withLock {
            guard var entry = progressEntries[requestID] else { return }
            entry.callbacks.removeValue(forKey: token)
            if entry.callbacks.isEmpty {
                progressEntries.removeValue(forKey: requestID)
            } else {
                progressEntries[requestID] = entry
            }
        }
    }

    /// Ends the previous failure episode before an explicit retry attempt.
    public func beginRetry(for requestID: AutoChartRequestID) {
        _ = lock.withLock { failures.removeValue(forKey: requestID) }
    }

    /// Exact statistics for the underlying three cache layers.
    public func statistics() async -> AutoChartCacheStatistics {
        await engine.cacheStatistics
    }

    public func trim(to target: AutoChartCacheTrimTarget) async {
        lock.withLock {
            if target == .minimum {
                completed.removeAll(keepingCapacity: false)
                recency.removeAll(keepingCapacity: false)
                failures.removeAll(keepingCapacity: false)
                progressEntries.removeAll(keepingCapacity: false)
            } else {
                trimCompletedLocked()
            }
        }
        await engine.trim(to: target)
    }

    public func removeAll() async {
        lock.withLock {
            completed.removeAll(keepingCapacity: false)
            recency.removeAll(keepingCapacity: false)
            failures.removeAll(keepingCapacity: false)
            progressEntries.removeAll(keepingCapacity: false)
        }
        await engine.removeAll()
    }

    private func trimCompletedLocked() {
        func totalCost() -> Int {
            completed.values.reduce(0) { partial, box in
                let (sum, overflow) = partial.addingReportingOverflow(box.cost)
                return overflow ? Int.max : sum
            }
        }
        while completed.count > configuration.analyses.maximumEntries
            || totalCost() > configuration.maximumRetainedCost
        {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            completed.removeValue(forKey: oldest)
        }
    }
}
