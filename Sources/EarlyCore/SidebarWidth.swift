import Foundation

public enum SidebarWidth {
    public static let defaultValue = 240.0
    public static let minimum = 220.0
    public static let maximum = 360.0

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(maximum, max(minimum, value))
    }
}
