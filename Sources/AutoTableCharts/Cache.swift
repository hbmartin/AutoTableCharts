import Foundation

private final class AutoChartCompletedAnalysisBox: @unchecked Sendable {
    let value: Any
    let exclusiveCost: Int
    let sharedSourceIdentifier: ObjectIdentifier
    let sharedSourceCost: Int

    init<RowID>(_ analysis: AutoChartAnalysis<RowID>) {
        value = analysis
        exclusiveCost = analysis.exclusiveRetainedCost
        sharedSourceIdentifier = analysis.sharedSourceIdentifier
        sharedSourceCost = analysis.sharedSourceRetainedCost
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
    private var failureRecency: [AutoChartRequestID] = []
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
        failureRecency.removeAll { $0 == analysis.request }
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
                failureRecency.removeAll { $0 == requestID }
                failureRecency.append(requestID)
                return existing
            }
            failures[requestID] = proposed
            failureRecency.removeAll { $0 == requestID }
            failureRecency.append(requestID)
            trimFailuresLocked()
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
        lock.withLock {
            failures.removeValue(forKey: requestID)
            failureRecency.removeAll { $0 == requestID }
        }
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
                failureRecency.removeAll(keepingCapacity: false)
            } else {
                trimCompletedLocked()
                trimFailuresLocked()
            }
        }
        await engine.trim(to: target)
    }

    public func removeAll() async {
        lock.withLock {
            completed.removeAll(keepingCapacity: false)
            recency.removeAll(keepingCapacity: false)
            failures.removeAll(keepingCapacity: false)
            failureRecency.removeAll(keepingCapacity: false)
            progressEntries = progressEntries.mapValues { entry in
                var entry = entry
                entry.current = nil
                return entry
            }
        }
        await engine.removeAll()
    }

    private func trimCompletedLocked() {
        func retainedCostState() -> (
            total: Int,
            sourceReferenceCounts: [ObjectIdentifier: Int],
            overflowed: Bool
        ) {
            var result = 0
            var overflowed = false
            var sourceReferenceCounts: [ObjectIdentifier: Int] = [:]
            for box in completed.values {
                let (exclusiveTotal, exclusiveOverflow) = result.addingReportingOverflow(
                    box.exclusiveCost)
                if exclusiveOverflow {
                    result = Int.max
                    overflowed = true
                } else if !overflowed {
                    result = exclusiveTotal
                }
                sourceReferenceCounts[box.sharedSourceIdentifier, default: 0] += 1
                if sourceReferenceCounts[box.sharedSourceIdentifier] == 1 {
                    let (sharedTotal, sharedOverflow) = result.addingReportingOverflow(
                        box.sharedSourceCost)
                    if sharedOverflow {
                        result = Int.max
                        overflowed = true
                    } else if !overflowed {
                        result = sharedTotal
                    }
                }
            }
            return (result, sourceReferenceCounts, overflowed)
        }

        var costState = retainedCostState()
        while completed.count > configuration.analyses.maximumEntries
            || costState.overflowed
            || costState.total > configuration.maximumRetainedCost
        {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            guard let removed = completed.removeValue(forKey: oldest) else { continue }
            if costState.overflowed {
                costState = retainedCostState()
                continue
            }
            costState.total -= removed.exclusiveCost
            if costState.sourceReferenceCounts[removed.sharedSourceIdentifier] == 1 {
                costState.total -= removed.sharedSourceCost
                costState.sourceReferenceCounts.removeValue(
                    forKey: removed.sharedSourceIdentifier)
            } else {
                costState.sourceReferenceCounts[removed.sharedSourceIdentifier, default: 1] -= 1
            }
        }
    }

    private func trimFailuresLocked() {
        let maximumFailures = max(1, configuration.analyses.maximumEntries)
        while failures.count > maximumFailures, let oldest = failureRecency.first {
            failureRecency.removeFirst()
            failures.removeValue(forKey: oldest)
        }
    }
}
