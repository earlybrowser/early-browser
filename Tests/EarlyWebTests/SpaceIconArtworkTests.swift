// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import Testing

@Suite @MainActor
struct SpaceIconArtworkTests {
    @Test func everySpacePickerSymbolHasNativeArtwork() {
        for symbol in SpaceIcon.Symbol.allCases {
            #expect(NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: symbol.label) != nil,
                    "Missing Space icon: \(symbol.rawValue)")
        }
    }
}
