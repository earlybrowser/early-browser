// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum SidebarWidth {
    public static let defaultValue = 240.0
    public static let minimum = 220.0
    public static let maximum = 360.0

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        // WebKit compares swipe-preview pixels with an integer-point viewport.
        // Fractional sidebar drags can otherwise leave a half-point-wide page
        // after SwiftUI layout, making valid history previews appear blank.
        return min(maximum, max(minimum, value)).rounded()
    }
}
