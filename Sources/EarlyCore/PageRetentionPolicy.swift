// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decides which live background pages may release their WebKit resources.
/// This policy owns no views, performs no loading, and never changes tab metadata.
public struct PageRetentionPolicy: Sendable {
    public enum Pressure: Equatable, Sendable {
        case normal, warning, critical
    }

    /// Resource owners report interactions that cannot be inferred from the
    /// lightweight lifecycle: for example editing a form, a dialog, a context
    /// menu, a media presentation, or an in-progress download.
    public struct Protection: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let interaction = Protection(rawValue: 1 << 0)
        public static let media = Protection(rawValue: 1 << 1)
        public static let download = Protection(rawValue: 1 << 2)
    }

    public struct Page: Equatable, Sendable {
        public let id: UUID
        public let lifecycle: PageLifecycle
        public let protections: Protection

        public init(id: UUID, lifecycle: PageLifecycle, protections: Protection = []) {
            self.id = id
            self.lifecycle = lifecycle
            self.protections = protections
        }

        fileprivate var isInactive: Bool {
            lifecycle.ownsView && !lifecycle.isVisible && !lifecycle.isFocused
        }

        fileprivate var isProtected: Bool {
            !isInactive || lifecycle.state == .loading || !protections.isEmpty
        }
    }

    /// Visible pages do not consume this background-page allowance. Protected
    /// background pages do consume it but are never discarded, even if retaining
    /// them requires exceeding the configured limit during memory pressure.
    public let maximumInactivePages: Int
    private var recency: [UUID: UInt64] = [:]
    private var accessSequence: UInt64 = 0

    public init(maximumInactivePages: Int = 8) {
        self.maximumInactivePages = max(0, maximumInactivePages)
    }

    public func inactiveAllowance(for pressure: Pressure) -> Int {
        switch pressure {
        case .normal: maximumInactivePages
        case .warning: maximumInactivePages / 2
        case .critical: 0
        }
    }

    /// Called on accepted page use or allocation, never by rendering or polling.
    public mutating func recordUse(of id: UUID) {
        if accessSequence == .max {
            // Preserve ordering if a manager ever outlives the sequence space.
            let ordered = recency.keys.sorted { older($0, than: $1) }
            for (index, id) in ordered.enumerated() { recency[id] = UInt64(index + 1) }
            accessSequence = UInt64(ordered.count)
        }
        accessSequence += 1
        recency[id] = accessSequence
    }

    public mutating func forget(_ id: UUID) { recency[id] = nil }

    /// Deleted tabs leave no history in the resource policy. Discarded tabs may
    /// keep their identity here, so a later explicit activation can update it.
    public mutating func reconcile(tabIDs: Set<UUID>) {
        recency = recency.filter { tabIDs.contains($0.key) }
    }

    /// Normal operation retains the configured background allowance. A warning
    /// halves it; critical pressure releases every eligible background page.
    /// All pressure levels preserve visibility, loading, and protection rules.
    /// Returned identities are unique and ordered from least recently used.
    public func discardCandidates(from pages: [Page], pressure: Pressure = .normal) -> [UUID] {
        let allowance = inactiveAllowance(for: pressure)
        let inactiveIDs = Set(pages.filter(\.isInactive).map(\.id))
        let excess = max(0, inactiveIDs.count - allowance)
        guard excess > 0 else { return [] }
        // Any protected snapshot wins if a caller accidentally includes the
        // same identity twice; inconsistent input must not discard a live pane.
        let protectedIDs = Set(pages.filter(\.isProtected).map(\.id))
        return Array(inactiveIDs.subtracting(protectedIDs)
            .sorted { older($0, than: $1) }
            .prefix(excess))
    }

    private func older(_ left: UUID, than right: UUID) -> Bool {
        let leftUse = recency[left, default: 0], rightUse = recency[right, default: 0]
        if leftUse != rightUse { return leftUse < rightUse }
        return left.uuidString < right.uuidString
    }
}
