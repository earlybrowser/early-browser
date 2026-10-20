// SPDX-License-Identifier: MPL-2.0

import Dispatch
import EarlyCore

/// Dispatch owns the source; cancellation on owner release removes the native
/// subscription without an observer that retains the WebViewManager.
final class PageMemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(handler: @escaping @Sendable (PageRetentionPolicy.Pressure) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let data = self?.source.data else { return }
            handler(data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal)
        }
        source.resume()
    }

    deinit { source.cancel() }
}
