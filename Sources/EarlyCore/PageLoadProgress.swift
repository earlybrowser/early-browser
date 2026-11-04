// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Presentation state for one main-frame navigation. Native progress and KVO
/// loading changes are samples, not additional navigation-start events.
public struct PageLoadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, requested, loading, completed, interrupted }

    public private(set) var generation = UUID()
    public private(set) var fraction = 0.0
    public private(set) var phase = Phase.idle
    private var navigation: ObjectIdentifier?

    public init() {}

    public var isLoading: Bool { phase == .requested || phase == .loading }

    public mutating func request() {
        generation = UUID()
        fraction = 0
        navigation = nil
        phase = .requested
    }

    public mutating func started(_ navigation: ObjectIdentifier?, expected: ObjectIdentifier?) {
        let acknowledgesRequest = phase == .requested
            && (navigation == nil || expected == nil || navigation == expected)
        let repeatedStart = phase == .loading && navigation != nil && navigation == self.navigation
        if repeatedStart { return }
        if !acknowledgesRequest {
            generation = UUID()
            fraction = 0
        }
        self.navigation = navigation
        phase = .loading
    }

    public mutating func advance(_ estimate: Double) {
        // Before the provisional start, WebKit may still expose the previous
        // document's estimate. Leave space for the actual completion event.
        guard phase == .loading, estimate.isFinite else { return }
        fraction = max(fraction, min(max(estimate, 0), 0.95))
    }

    public mutating func finish(_ navigation: ObjectIdentifier?) {
        guard phase == .loading else { return }
        if let navigation, let current = self.navigation, navigation != current { return }
        fraction = 1
        self.navigation = nil
        phase = .completed
    }

    /// Fragment/history loads can settle without a provisional document. The
    /// owner calls this only when WebKit is idle. A declined request must not
    /// leave the indicator running or claim to have loaded the requested URL.
    public mutating func settleRequest(atRequestedURL: Bool) {
        guard phase == .requested else { return }
        guard atRequestedURL else { interrupt(); return }
        fraction = 1
        phase = .completed
    }

    public mutating func interrupt() {
        navigation = nil
        phase = .interrupted
    }
}
