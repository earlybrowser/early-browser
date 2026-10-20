// SPDX-License-Identifier: MPL-2.0

/// Runtime only: never encoded with tab metadata. Visibility is independent of
/// loading/failure so a background load cannot accidentally become foreground.
public struct PageLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unloaded, loading, active, background, suspended, discarded, failed
    }

    public enum Event: Equatable, Sendable {
        case allocate, startLoading, finishLoading, stopLoading, fail, discard
        /// Policy hooks only. The resource owner must perform the corresponding
        /// suspension/resumption before reporting these events; changing this
        /// value alone does not freeze WebKit or its JavaScript.
        case suspend, resume
    }

    public private(set) var state: State = .unloaded
    public private(set) var isVisible = false
    public private(set) var isFocused = false

    public init() {}

    public var ownsView: Bool { state != .unloaded && state != .discarded }

    @discardableResult
    public mutating func setPresentation(visible: Bool, focused: Bool) -> Bool {
        guard !focused || visible else { return false }
        isVisible = visible
        isFocused = focused
        if state == .active || state == .background { state = visible ? .active : .background }
        return true
    }

    /// Illegal or stale transitions are no-ops. In particular a late completion
    /// cannot resurrect a discarded view, and only background pages may suspend.
    @discardableResult
    public mutating func transition(_ event: Event) -> Bool {
        switch event {
        case .allocate:
            guard !ownsView else { return false }
            state = isVisible ? .active : .background
        case .startLoading:
            guard ownsView, state != .suspended else { return false }
            state = .loading
        case .finishLoading, .stopLoading:
            guard state == .loading else { return false }
            state = isVisible ? .active : .background
        case .fail:
            guard ownsView, state != .suspended else { return false }
            state = .failed
        case .suspend:
            guard state == .background, !isVisible else { return false }
            state = .suspended
        case .resume:
            guard state == .suspended else { return false }
            state = isVisible ? .active : .background
        case .discard:
            guard state != .discarded else { return false }
            state = .discarded
        }
        return true
    }
}
