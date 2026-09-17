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

package struct AutoChartFailureScope: Hashable, Sendable {
    package let requestID: AutoChartRequestID
    package let recommendationID: AutoChartRecommendationID?

    package init(
        requestID: AutoChartRequestID,
        recommendationID: AutoChartRecommendationID? = nil
    ) {
        self.requestID = requestID
        self.recommendationID = recommendationID
    }
}

package struct AutoChartFailureEpisodeContext: Sendable {
    package static let coalescing = Self(episodesToReplace: [:])

    package let episodesToReplace: [AutoChartFailureScope: UUID]

    package init(episodesToReplace: [AutoChartFailureScope: UUID]) {
        self.episodesToReplace = episodesToReplace
    }
}

package struct AutoChartFailureEpisodeState: Sendable {
    package let observedEpisodes: [AutoChartFailureScope: UUID]
    package let context: AutoChartFailureEpisodeContext
}

private struct AutoChartRecencyOrder<Key: Hashable> {
    private struct Links {
        var older: Key?
        var newer: Key?
    }

    private var linksByKey: [Key: Links] = [:]
    private var oldest: Key?
    private var newest: Key?

    mutating func touch(_ key: Key) {
        remove(key)
        linksByKey[key] = Links(older: newest, newer: nil)
        if let newest {
            linksByKey[newest]?.newer = key
        } else {
            oldest = key
        }
        newest = key
    }

    mutating func popOldest() -> Key? {
        guard let oldest else { return nil }
        remove(oldest)
        return oldest
    }

    mutating func removeAll() {
        linksByKey.removeAll(keepingCapacity: false)
        oldest = nil
        newest = nil
    }

    mutating func remove(_ key: Key) {
        guard let links = linksByKey.removeValue(forKey: key) else { return }
        if let older = links.older {
            linksByKey[older]?.newer = links.newer
        } else {
            oldest = links.newer
        }
        if let newer = links.newer {
            linksByKey[newer]?.older = links.older
        } else {
            newest = links.older
        }
    }
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
    private var recency = AutoChartRecencyOrder<AutoChartRequestID>()
    private var failures: [AutoChartFailureScope: AutoChartFailure] = [:]
    private var failureRecency = AutoChartRecencyOrder<AutoChartFailureScope>()
    private var progressEntries: [AutoChartRequestID: AutoChartProgressEntry] = [:]

    let engine: AutoChartAnalyzer

    public init(configuration: AutoChartAnalyzerConfiguration = .standard) {
        self.configuration = configuration
        self.engine = AutoChartAnalyzer(configuration: configuration)
    }

    #if ATC_TEST_HOOKS
    init(
        configuration: AutoChartAnalyzerConfiguration = .standard,
        testHooks: AutoChartAnalyzerTestHooks
    ) {
        self.configuration = configuration
        self.engine = AutoChartAnalyzer(
            configuration: configuration,
            testHooks: testHooks)
    }
    #endif

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
        recency.touch(requestID)
        return value
    }

    func store<RowID>(_ analysis: AutoChartAnalysis<RowID>) {
        lock.lock()
        defer { lock.unlock() }
        removeFailureLocked(
            for: AutoChartFailureScope(requestID: analysis.request))
        guard configuration.analyses.maximumEntries > 0,
            configuration.maximumRetainedCost > 0,
            analysis.estimatedRetainedCost <= configuration.maximumRetainedCost
        else { return }
        completed[analysis.request] = AutoChartCompletedAnalysisBox(analysis)
        recency.touch(analysis.request)
        trimCompletedLocked()
    }

    func coalescedFailure(
        for requestID: AutoChartRequestID,
        recommendationID: AutoChartRecommendationID? = nil,
        error: any Error,
        stage: AutoChartFailureStage,
        episodeContext: AutoChartFailureEpisodeContext = .coalescing
    ) -> AutoChartFailure {
        lock.withLock {
            let key = AutoChartFailureScope(
                requestID: requestID,
                recommendationID: recommendationID)
            let proposed = AutoChartFailure.wrapping(error, stage: stage)
            if let existing = failures[key],
                existing.diagnosticID == proposed.diagnosticID,
                episodeContext.episodesToReplace[key] != existing.episodeID
            {
                failureRecency.touch(key)
                return existing
            }
            failures[key] = proposed
            failureRecency.touch(key)
            trimFailuresLocked()
            return proposed
        }
    }

    package func recordSuccess(for scope: AutoChartFailureScope) {
        lock.withLock {
            removeFailureLocked(for: scope)
        }
    }

    package func failureEpisodeState(
        for requestID: AutoChartRequestID,
        observedEpisodes: [AutoChartFailureScope: UUID],
        restartsCurrentEpisodes: Bool
    ) -> AutoChartFailureEpisodeState {
        lock.withLock {
            let liveObserved = observedEpisodes.filter { scope, episodeID in
                failures[scope]?.episodeID == episodeID
            }
            let episodesToReplace: [AutoChartFailureScope: UUID]
            if restartsCurrentEpisodes {
                episodesToReplace = failures.reduce(into: [:]) { result, entry in
                    guard entry.key.requestID == requestID else { return }
                    result[entry.key] = entry.value.episodeID
                }
            } else {
                episodesToReplace = liveObserved.filter {
                    $0.key.requestID == requestID
                }
            }
            return AutoChartFailureEpisodeState(
                observedEpisodes: liveObserved,
                context: AutoChartFailureEpisodeContext(
                    episodesToReplace: episodesToReplace))
        }
    }

    package func recordingFailureEpisode(
        for requestID: AutoChartRequestID,
        episodeID: UUID,
        observedEpisodes: [AutoChartFailureScope: UUID]
    ) -> [AutoChartFailureScope: UUID] {
        lock.withLock {
            var liveObserved = observedEpisodes.filter { scope, observedEpisodeID in
                failures[scope]?.episodeID == observedEpisodeID
            }
            for (scope, failure) in failures
            where scope.requestID == requestID && failure.episodeID == episodeID {
                liveObserved[scope] = episodeID
            }
            return liveObserved
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

    /// Ends every retained failure episode for a request.
    ///
    /// Call this before a request-wide explicit retry when all request and chart
    /// preparation failures should begin new episodes. UI sessions apply narrower
    /// attempt-aware episode handling internally.
    public func beginRetry(for requestID: AutoChartRequestID) {
        lock.withLock {
            let keys = failures.keys.filter { $0.requestID == requestID }
            for key in keys { removeFailureLocked(for: key) }
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
                recency.removeAll()
                failures.removeAll(keepingCapacity: false)
                failureRecency.removeAll()
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
            recency.removeAll()
            failures.removeAll(keepingCapacity: false)
            failureRecency.removeAll()
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
            guard let oldest = recency.popOldest() else { break }
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
        while failures.count > maximumFailures,
            let oldest = failureRecency.popOldest()
        {
            failures.removeValue(forKey: oldest)
        }
    }

    private func removeFailureLocked(for scope: AutoChartFailureScope) {
        failures.removeValue(forKey: scope)
        failureRecency.remove(scope)
    }
}
