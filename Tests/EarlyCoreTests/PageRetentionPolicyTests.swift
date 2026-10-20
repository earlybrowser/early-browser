// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Testing

@Suite struct PageRetentionPolicyTests {
    @Test func retainsRecentPagesAndUsesExplicitAccessRatherThanInputOrder() {
        let ids = (1...5).map(id)
        var policy = PageRetentionPolicy(maximumInactivePages: 2)
        for id in ids { policy.recordUse(of: id) }
        policy.recordUse(of: ids[0])
        let pages = ids.reversed().map { page($0) }
        #expect(policy.discardCandidates(from: pages) == [ids[1], ids[2], ids[3]])
        let retained = pages.filter { !policy.discardCandidates(from: pages).contains($0.id) }
        #expect(policy.discardCandidates(from: retained).isEmpty)
    }

    @Test func everyVisibleSplitPaneIsProtectedAndDoesNotConsumeInactiveAllowance() {
        let ids = (1...5).map(id)
        var policy = PageRetentionPolicy(maximumInactivePages: 1)
        for id in ids { policy.recordUse(of: id) }
        let pages = [page(ids[0], visible: true, focused: true),
                     page(ids[1], visible: true), page(ids[2]), page(ids[3]), page(ids[4])]
        #expect(policy.discardCandidates(from: pages) == [ids[2], ids[3]])
        #expect(policy.discardCandidates(from: pages, pressure: .critical) == Array(ids[2...4]))
    }

    @Test func loadingAndImportantInteractionsSurviveAllPressureLevels() {
        let ids = (1...7).map(id)
        let pages = [page(ids[0], protections: .interaction),
                     page(ids[1], protections: .media),
                     page(ids[2], protections: .download),
                     page(ids[3], loading: true),
                     page(ids[4], visible: true, focused: true),
                     page(ids[5], protections: [.interaction, .media, .download]),
                     page(ids[6])]
        let policy = PageRetentionPolicy(maximumInactivePages: 0)
        for pressure: PageRetentionPolicy.Pressure in [.normal, .warning, .critical] {
            #expect(policy.discardCandidates(from: pages, pressure: pressure) == [ids[6]])
            #expect(policy.discardCandidates(from: Array(pages.dropLast()), pressure: pressure).isEmpty)
        }
    }

    @Test func pressureReducesAllowanceWithoutEvictingProtectedPages() {
        let ids = (1...7).map(id)
        var policy = PageRetentionPolicy(maximumInactivePages: 4)
        for id in ids { policy.recordUse(of: id) }
        let pages = ids.map { page($0, protections: $0 == ids[0] ? .media : []) }
        #expect(policy.discardCandidates(from: pages) == Array(ids[1...3]))
        #expect(policy.discardCandidates(from: pages, pressure: .warning) == Array(ids[1...5]))
        #expect(policy.discardCandidates(from: pages, pressure: .critical) == Array(ids[1...6]))
    }

    @Test func releasingProtectionMakesTheOldPageEligibleAgain() {
        let oldest = id(1), newest = id(2)
        var policy = PageRetentionPolicy(maximumInactivePages: 1)
        policy.recordUse(of: oldest)
        policy.recordUse(of: newest)
        #expect(policy.discardCandidates(from: [page(oldest, protections: .interaction), page(newest)]) == [newest])
        #expect(policy.discardCandidates(from: [page(oldest), page(newest)]) == [oldest])
    }

    @Test func discardedAndUnloadedMetadataDoNotConsumeLiveBudget() {
        let unloaded = PageRetentionPolicy.Page(id: id(1), lifecycle: PageLifecycle())
        var discarded = PageLifecycle()
        discarded.transition(.allocate)
        discarded.transition(.discard)
        var suspended = PageLifecycle()
        suspended.transition(.allocate)
        suspended.transition(.suspend)
        var failed = PageLifecycle()
        failed.transition(.allocate)
        failed.transition(.fail)
        let pages = [unloaded, .init(id: id(2), lifecycle: discarded),
                     .init(id: id(3), lifecycle: suspended), .init(id: id(4), lifecycle: failed)]
        let policy = PageRetentionPolicy(maximumInactivePages: 1)
        #expect(policy.discardCandidates(from: pages) == [id(3)])
        #expect(policy.discardCandidates(from: pages, pressure: .critical) == [id(3), id(4)])
    }

    @Test func pruningRemovesPreviousIdentityRecencyAndUnknownPagesSortDeterministically() {
        let ids = (1...4).map(id)
        var policy = PageRetentionPolicy(maximumInactivePages: 1)
        for id in ids { policy.recordUse(of: id) }
        policy.reconcile(tabIDs: [ids[0], ids[1]])
        policy.forget(ids[1])
        let pages = ids.reversed().map { page($0) }
        #expect(policy.discardCandidates(from: pages) == [ids[1], ids[2], ids[3]])
        policy.recordUse(of: ids[3])
        #expect(policy.discardCandidates(from: pages) == [ids[1], ids[2], ids[0]])
    }

    @Test func duplicateSnapshotsCannotEvictVisibleOrProtectedIdentities() {
        let ids = (1...3).map(id)
        let pages = [page(ids[0]), page(ids[0], visible: true, focused: true),
                     page(ids[1]), page(ids[1], protections: .download), page(ids[2]), page(ids[2])]
        let policy = PageRetentionPolicy(maximumInactivePages: 0)
        #expect(policy.discardCandidates(from: pages, pressure: .critical) == [ids[2]])
    }

    @Test func negativeAllowanceBehavesAsZeroAndEmptyInputNeedsNoResources() {
        let policy = PageRetentionPolicy(maximumInactivePages: -5)
        #expect(policy.discardCandidates(from: []).isEmpty)
        #expect(policy.discardCandidates(from: [page(id(1))]) == [id(1)])
    }

    private func page(_ id: UUID, visible: Bool = false, focused: Bool = false,
                      loading: Bool = false, protections: PageRetentionPolicy.Protection = []) -> PageRetentionPolicy.Page {
        var lifecycle = PageLifecycle()
        lifecycle.setPresentation(visible: visible, focused: focused)
        lifecycle.transition(.allocate)
        if loading { lifecycle.transition(.startLoading) }
        return .init(id: id, lifecycle: lifecycle, protections: protections)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
