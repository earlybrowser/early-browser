// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One budget for the input and suggestions; growing the editor must not push
/// results below a short window. Its top edge stays still while typing.
public struct CommandBarLayout: Equatable, Sendable {
    public let topInset: Double
    public let maximumCardHeight: Double
    public let maximumInputHeight: Double
    private let statusHeight: Double

    public init(availableHeight: Double, hasSuggestions: Bool, statusCount: Int) {
        let height = availableHeight.isFinite ? max(0, availableHeight) : 600
        topInset = max(16, height * 0.40 - 32)
        maximumCardHeight = max(64, min(440, height - topInset - 16))
        statusHeight = Double(min(2, max(0, statusCount))) * 44
        let resultReserve = hasSuggestions ? 61.0 : 0 // Divider/gap + one row.
        maximumInputHeight = min(120, max(24, maximumCardHeight - 40 - statusHeight - resultReserve))
    }

    public func suggestionHeight(inputHeight: Double) -> Double {
        let input = inputHeight.isFinite ? min(maximumInputHeight, max(24, inputHeight)) : 24
        return min(220, max(0, maximumCardHeight - 40 - statusHeight - input - 25))
    }
}
