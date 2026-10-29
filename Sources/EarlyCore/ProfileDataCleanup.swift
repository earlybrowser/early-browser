// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Profile cleanup is retryable: an already absent file is success, while
/// permission and other storage errors must reach the cleanup coordinator.
public enum ProfileDataCleanup {
    public static func removeItem(at url: URL?) throws {
        guard let url else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }
}
