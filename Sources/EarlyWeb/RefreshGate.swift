// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The lock protects only this one flag; no UI work runs under the lock.
final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard !queued else { lock.unlock(); return }
        queued = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            queued = false
            lock.unlock()
            work()
        }
    }
}
