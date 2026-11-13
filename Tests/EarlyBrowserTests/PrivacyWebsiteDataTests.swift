// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyBrowser

@Suite(.serialized) @MainActor struct PrivacyWebsiteDataTests {
    @MainActor private final class Fetches {
        var pending: [(UUID, CheckedContinuation<[String], Never>)] = []
        func fetch(_ profile: UUID) async -> [String] {
            await withCheckedContinuation { pending.append((profile, $0)) }
        }
        func finish(_ index: Int, _ values: [String]) { pending[index].1.resume(returning: values) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func switchingProfilesRejectsOldCompletionsAndOldRemovalActions() async throws {
        let data = ProfileWebsiteData<String>(), fetches = Fetches(), a = UUID(), b = UUID()
        await data.load(for: a) { _ in ["old A"] }
        let old = try #require(data.records(for: a))
        let first = Task { await data.load(for: a, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 1 }
        data.select(b)
        #expect(data.snapshot == nil && data.records(for: a) == nil && data.records(for: b) == nil)
        let second = Task { await data.load(for: b, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 2 }
        fetches.finish(1, ["B"])
        await second.value
        fetches.finish(0, ["late A"])
        await first.value
        #expect(data.records(for: b)?.records == ["B"])
        await data.remove(old.records, from: old, using: { _, _ in Issue.record("Stale records must not be removed") },
                          fetch: { _ in Issue.record("A stale action must not reload"); return [] })
        #expect(data.records(for: b)?.records == ["B"])
    }

    @Test func repeatedSwitchesRequireRequestIdentityEvenWhenTheProfileMatchesAgain() async throws {
        let data = ProfileWebsiteData<String>(), fetches = Fetches(), a = UUID(), b = UUID()
        let first = Task { await data.load(for: a, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 1 }
        let second = Task { await data.load(for: b, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 2 }
        let third = Task { await data.load(for: a, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 3 }
        fetches.finish(2, ["current A"]); await third.value
        fetches.finish(1, ["old B"]); await second.value
        fetches.finish(0, ["old A"]); await first.value
        #expect(data.records(for: a)?.records == ["current A"])
    }

    @Test(arguments: [false, true])
    func cancellationAndDisappearanceRejectFetchResults(disappeared: Bool) async throws {
        let data = ProfileWebsiteData<String>(), fetches = Fetches(), profile = UUID()
        let request = Task { await data.load(for: profile, fetch: fetches.fetch) }
        try await wait { fetches.pending.count == 1 }
        if disappeared { data.invalidate() } else { request.cancel() }
        fetches.finish(0, ["obsolete"])
        await request.value
        #expect(data.snapshot == nil && !data.isLoading)
    }

    @Test func removalKeepsItsOriginalProfileAndCannotReloadOverANewerSelection() async throws {
        let data = ProfileWebsiteData<String>(), a = UUID(), b = UUID()
        await data.load(for: a) { _ in ["A cookie"] }
        let source = try #require(data.records(for: a))
        var release: CheckedContinuation<Void, Never>?
        var removed: [UUID] = []
        let removal = Task {
            await data.remove(source.records, from: source, using: { records, profile in
                #expect(records == ["A cookie"])
                removed.append(profile)
                await withCheckedContinuation { release = $0 }
            }, fetch: { _ in Issue.record("Old removal must not replace B's list"); return [] })
        }
        try await wait { release != nil }
        #expect(data.isRemoving && data.snapshot == nil)
        await data.remove(source.records, from: source, using: { _, _ in Issue.record("No duplicate removal") }, fetch: { _ in [] })
        await data.load(for: b) { _ in ["B cookie"] }
        release?.resume(); await removal.value
        #expect(removed == [a])
        #expect(data.records(for: b)?.records == ["B cookie"] && !data.isRemoving)
        let current = try #require(data.records(for: b))
        await data.remove(current.records, from: current, using: { records, profile in
            #expect(records == ["B cookie"] && profile == b)
        }, fetch: { profile in #expect(profile == b); return [] })
        #expect(data.records(for: b)?.records.isEmpty == true)
    }
}
