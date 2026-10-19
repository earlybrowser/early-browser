// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

/// Window-owned, cancellable command-bar search. Each query gets a generation;
/// a superseded local ranking or provider response can never be published.
/// Ranking runs off the main actor on an immutable candidate snapshot.
@MainActor @Observable
public final class CommandSearch {
    public private(set) var results: [CommandSearchResult] = []
    public private(set) var selectedID: String?
    /// True until the current query's local ranking is published. Rows from
    /// the previous query remain visible for layout but cannot be selected.
    public private(set) var isRefreshing = false
    public private(set) var isLoadingProviders = false
    public let limits: CommandSearchLimits
    @ObservationIgnored private let providers: [any CommandSearchProvider]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(providers: [any CommandSearchProvider] = [], limits: CommandSearchLimits = CommandSearchLimits(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers
        self.limits = limits
        self.now = now
    }

    public var selectedResult: CommandSearchResult? {
        guard !isRefreshing, let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        guard !isRefreshing, let selectedID else { return nil }
        return results.firstIndex { $0.id == selectedID }
    }

    /// Select by position among fresh results; nil or out of range clears.
    public func select(index: Int?) {
        guard !isRefreshing, let index, results.indices.contains(index) else {
            selectedID = nil
            return
        }
        selectedID = results[index].id
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        results = []
        selectedID = nil
        isRefreshing = false
        isLoadingProviders = false
    }

    public func update(query: String, candidates: [CommandSearchCandidate]) {
        generation += 1
        task?.cancel()
        task = nil
        selectedID = nil
        isLoadingProviders = false
        guard CommandSearchRanker.Query(query, limit: limits.maximumQueryLength) != nil else {
            results = []
            isRefreshing = false
            return
        }
        isRefreshing = true
        let revision = generation
        let limits = limits
        let date = now()
        let providers = providers
        let local = Array(candidates.prefix(limits.maximumCandidates))
        task = Task { [weak self] in
            do {
                let ranked = try await Self.rank(query, local, date, limits)
                guard let self, !Task.isCancelled, self.generation == revision else { return }
                self.results = ranked
                self.isRefreshing = false
                guard !providers.isEmpty else {
                    self.task = nil
                    return
                }
                self.isLoadingProviders = true
                let external = await Self.collect(query, from: providers, limit: limits.providerResults)
                try Task.checkCancellation()
                let merged = try await Self.rank(query, local + external, date, limits)
                guard !Task.isCancelled, self.generation == revision else { return }
                // Keep a still-present selection by identity, not by position.
                if let selected = self.selectedID, !merged.contains(where: { $0.id == selected }) { self.selectedID = nil }
                self.results = merged
                self.isLoadingProviders = false
                self.task = nil
            } catch {
                // Cancelled: a newer generation owns the published state.
            }
        }
    }

    nonisolated static func rank(_ query: String, _ candidates: [CommandSearchCandidate], _ now: Date,
                                 _ limits: CommandSearchLimits) async throws -> [CommandSearchResult] {
        let work = Task.detached(priority: .userInitiated) {
            try CommandSearchRanker.rank(query, candidates: candidates, now: now, limits: limits)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Provider failures only remove that provider's rows. Each response is
    /// bounded before ranking, so a misbehaving source cannot grow the list.
    nonisolated static func collect(_ query: String, from providers: [any CommandSearchProvider],
                                    limit: Int) async -> [CommandSearchCandidate] {
        await withTaskGroup(of: (Int, [CommandSearchCandidate]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let values = (try? await provider.candidates(matching: query, limit: limit)) ?? []
                    return (index, Array(values.prefix(limit)))
                }
            }
            var responses: [(Int, [CommandSearchCandidate])] = []
            for await response in group { responses.append(response) }
            // Provider order, not completion order, keeps ranking deterministic.
            return responses.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}
