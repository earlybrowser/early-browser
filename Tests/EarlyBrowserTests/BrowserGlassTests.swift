// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import SwiftUI
import Testing

@Suite(.serialized) @MainActor
struct BrowserGlassTests {
    @Test func availabilityPreferencesAndAccessibilityGateEverySurface() {
        for supported in [false, true] {
            for translucent in [false, true] {
                for reduceTransparency in [false, true] {
                    for increasedContrast in [false, true] {
                        for reduceMotion in [false, true] {
                            let policy = BrowserGlassPolicy(supportsLiquidGlass: supported,
                                allowsTransparency: translucent, reduceTransparency: reduceTransparency,
                                increasedContrast: increasedContrast, reduceMotion: reduceMotion)
                            let expected = supported && translucent && !reduceTransparency && !increasedContrast
                            #expect(policy.usesLiquidGlass == expected)
                            #expect(policy.allowsInteraction == (expected && !reduceMotion))
                        }
                    }
                }
            }
        }
    }

    @Test func reduceMotionKeepsTheMaterialButDisablesInteractiveEffects() {
        let policy = BrowserGlassPolicy(supportsLiquidGlass: true, allowsTransparency: true,
            reduceTransparency: false, increasedContrast: false, reduceMotion: true)
        #expect(policy.usesLiquidGlass)
        #expect(!policy.allowsInteraction)
    }

    private final class FallbackProbe {
        var visits = 0
        func background() -> Color {
            visits += 1
            return Color(nsColor: .windowBackgroundColor)
        }
    }

    @Test func viewUsesFallbackWhenChromeTransparencyIsDisabled() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let probe = FallbackProbe()
            let view = Text("Early").frame(width: 240, height: 34)
                .background {
                    BrowserGlassBackground(cornerRadius: 10, allowsTransparency: false) {
                        probe.background()
                    }
                }
                .environment(\.colorScheme, scheme)
            // Merely measuring a view can skip its decorative background.
            // Rasterize the solid branch offscreen to exercise its builder.
            let renderer = ImageRenderer(content: view)
            let image = try #require(renderer.nsImage)
            #expect(image.size == CGSize(width: 240, height: 34))
            #expect(probe.visits > 0)
        }
    }

    /// Detached hosting/layout only. No app windows or UI automation, and no
    /// claim that these size checks qualify native compositing or visual timing.
    @Test func backgroundsAndBatchingDoNotChangeIslandOrPanelDimensions() {
        _ = NSApplication.shared
        let surfaces: [(CGSize, CGFloat)] = [
            (CGSize(width: 240, height: 32), 7),   // Today tab
            (CGSize(width: 240, height: 34), 10),  // Pin / closed folder
            (CGSize(width: 64, height: 43.2), 9),  // Favorite
            (CGSize(width: 240, height: 162), 10), // Expanded folder envelope
            (CGSize(width: 240, height: 36), 12),  // Address bar
            (CGSize(width: 560, height: 320), 16), // Command bar
            (CGSize(width: 960, height: 180), 20), // Switcher
            (CGSize(width: 1280, height: 800), 16) // Unified frame
        ]
        for (size, radius) in surfaces {
            for translucent in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = BrowserGlassGroup {
                        Text("Early").frame(width: size.width, height: size.height)
                            .background {
                                BrowserGlassBackground(cornerRadius: radius, tint: .blue.opacity(0.15),
                                    interactive: true, allowsTransparency: translucent) {
                                    RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.08))
                                }
                            }
                    }
                    .environment(\.colorScheme, scheme)
                    let host = NSHostingView(rootView: view)
                    // AppKit rounds fractional point sizes to backing pixels.
                    // Compare to the same foreground without any glass/group.
                    let plain = NSHostingView(rootView: Text("Early")
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, scheme))
                    #expect(host.fittingSize == plain.fittingSize)
                    #expect(host.window == nil)
                }
            }
        }
    }
}
