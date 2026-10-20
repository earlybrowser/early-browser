// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct PageSnapshotCacheTests {
    private func view() -> WKWebView {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800), configuration: configuration)
    }

    private func image(width: Int = 64, height: Int = 40) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * height)
        let result = NSImage(size: NSSize(width: width, height: height))
        result.addRepresentation(bitmap)
        return result
    }

    @Test func duplicateEventsCoalesceAndCaptureNeverAllocatesOrLoadsAView() {
        let probe = SnapshotProbe(), view = view(), id = UUID(), navigation = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        for _ in 0..<100 { cache.request(tabID: id, navigationID: navigation, view: view) }
        #expect(probe.calls.count == 1 && cache.inFlightCount == 1 && cache.pendingCount == 0)
        #expect(probe.calls[0].view === view)
        #expect(view.url == nil && !view.isLoading)
        #expect(probe.calls[0].rect == view.bounds)
        #expect(probe.calls[0].width <= 320 && !probe.calls[0].afterUpdates)
        probe.finish(0, image: image())
        #expect(cache.count == 1 && cache.inFlightCount == 0)
        #expect(cache.image(for: id) != nil && view.url == nil)
    }

    @Test func invalidationRejectsOldNavigationAndSerializesItsReplacement() {
        let probe = SnapshotProbe(), view = view(), id = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        cache.request(tabID: id, navigationID: UUID(), view: view)
        cache.invalidate(tabID: id)
        let replacementNavigation = UUID()
        for _ in 0..<20 { cache.request(tabID: id, navigationID: replacementNavigation, view: view) }
        #expect(cache.inFlightCount == 1 && cache.pendingCount == 1 && probe.calls.count == 1)
        probe.finish(0, image: image())
        #expect(cache.image(for: id) == nil && probe.calls.count == 2)
        probe.finish(1, image: image(width: 20))
        #expect(cache.image(for: id)?.size.width == 20 && cache.inFlightCount == 0)
    }

    @Test func latestQueuedNavigationReplacesOldWorkAndQueueIsBounded() {
        let probe = SnapshotProbe(), view = view(), active = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), limits: .init(pending: 2), capture: probe.capture)
        cache.request(tabID: active, navigationID: UUID(), view: view)
        let skipped = UUID(), replaced = UUID(), latest = UUID()
        cache.request(tabID: skipped, navigationID: UUID(), view: view)
        cache.request(tabID: replaced, navigationID: UUID(), view: view)
        cache.request(tabID: replaced, navigationID: UUID(), view: view)
        cache.request(tabID: latest, navigationID: UUID(), view: view)
        #expect(cache.pendingCount == 2 && probe.calls.count == 1)
        probe.finish(0, image: image())
        probe.finish(1, image: image())
        probe.finish(2, image: image())
        #expect(cache.image(for: active) != nil && cache.image(for: replaced) != nil && cache.image(for: latest) != nil)
        #expect(cache.image(for: skipped) == nil && cache.pendingCount == 0 && cache.inFlightCount == 0)
    }

    @Test func pixelAndDecodedByteBudgetsEvictLeastRecentlyUsedEntries() throws {
        let probe = SnapshotProbe(), view = view(), first = UUID(), second = UUID(), third = UUID()
        let cache = PageSnapshotCache(profileID: UUID(),
            limits: .init(entries: 3, bytes: 512, pixelWidth: 8, pixelHeight: 8), capture: probe.capture)
        for (index, id) in [first, second].enumerated() {
            cache.request(tabID: id, navigationID: UUID(), view: view)
            probe.finish(index, image: image(width: 100, height: 100))
        }
        let thumbnail = try #require(cache.image(for: first))
        let bitmap = try #require(thumbnail.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 8 && bitmap.pixelsHigh == 8 && cache.byteCount == 512)
        cache.request(tabID: third, navigationID: UUID(), view: view)
        probe.finish(2, image: image(width: 100, height: 100))
        #expect(cache.image(for: first) != nil && cache.image(for: second) == nil && cache.image(for: third) != nil)
        #expect(cache.count == 2 && cache.byteCount == 512)
    }

    @Test func entryBudgetAndTallPortraitImagesAreBounded() throws {
        let probe = SnapshotProbe(), view = view(), old = UUID(), new = UUID()
        let cache = PageSnapshotCache(profileID: UUID(),
            limits: .init(entries: 1, pixelWidth: 32, pixelHeight: 20), capture: probe.capture)
        for (index, id) in [old, new].enumerated() {
            cache.request(tabID: id, navigationID: UUID(), view: view)
            probe.finish(index, image: image(width: 100, height: 400))
        }
        let bitmap = try #require(cache.image(for: new)?.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 5 && bitmap.pixelsHigh == 20)
        #expect(cache.count == 1 && cache.image(for: old) == nil && cache.byteCount == 400)
    }

    @Test func retiringPageKeepsItsPreviewButCancelsNewPixels() {
        let probe = SnapshotProbe(), view = view(), id = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        cache.request(tabID: id, navigationID: UUID(), view: view)
        probe.finish(0, image: image(width: 20))
        cache.request(tabID: id, navigationID: UUID(), view: view)
        cache.cancelCapture(tabID: id)
        probe.finish(1, image: image(width: 40))
        #expect(cache.image(for: id)?.size.width == 20 && cache.count == 1)
        cache.invalidate(tabID: id)
        #expect(cache.count == 0 && cache.byteCount == 0)
    }

    @Test func profileCachesAreIsolatedAndReconciliationDeletesPixelsAndQueuedWork() {
        let probe = SnapshotProbe(), view = view(), id = UUID(), closed = UUID()
        let first = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        let second = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        first.request(tabID: id, navigationID: UUID(), view: view)
        probe.finish(0, image: image())
        #expect(first.profileID != second.profileID && second.image(for: id) == nil)
        first.request(tabID: closed, navigationID: UUID(), view: view)
        first.request(tabID: id, navigationID: UUID(), view: view)
        first.retain(tabIDs: [id])
        probe.finish(1, image: image())
        #expect(first.image(for: closed) == nil && probe.calls.count == 3)
        probe.finish(2, image: image())
        first.retain(tabIDs: [])
        #expect(first.count == 0 && first.byteCount == 0 && second.count == 0)
    }

    @Test func clearAndShutdownRejectLateCallbacksWithoutOverlappingCaptures() {
        let probe = SnapshotProbe(), view = view(), old = UUID(), new = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        cache.request(tabID: old, navigationID: UUID(), view: view)
        cache.clear()
        cache.request(tabID: new, navigationID: UUID(), view: view)
        #expect(cache.inFlightCount == 1 && probe.calls.count == 1)
        probe.finish(0, image: image())
        #expect(cache.image(for: old) == nil && probe.calls.count == 2)
        cache.shutdown()
        probe.finish(1, image: image())
        cache.request(tabID: new, navigationID: UUID(), view: view)
        #expect(cache.count == 0 && cache.byteCount == 0 && cache.inFlightCount == 0 && probe.calls.count == 2)
    }

    @Test func queueNeverRetainsDiscardedWebViews() {
        let probe = SnapshotProbe(), first = view()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        cache.request(tabID: UUID(), navigationID: UUID(), view: first)
        weak var retired: WKWebView?
        autoreleasepool {
            let temporary = view()
            retired = temporary
            cache.request(tabID: UUID(), navigationID: UUID(), view: temporary)
        }
        #expect(retired == nil)
        probe.finish(0, image: nil)
        #expect(probe.calls.count == 1 && cache.pendingCount == 0 && cache.inFlightCount == 0)
    }

    @Test func disabledZeroBudgetAndInvalidGeometryDoNotCapture() {
        let probe = SnapshotProbe(), view = view()
        let disabled = PageSnapshotCache(profileID: UUID(), enabled: false, capture: probe.capture)
        let noBudget = PageSnapshotCache(profileID: UUID(), limits: .init(bytes: 0), capture: probe.capture)
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        disabled.request(tabID: UUID(), navigationID: UUID(), view: view)
        noBudget.request(tabID: UUID(), navigationID: UUID(), view: view)
        view.frame = .zero
        cache.request(tabID: UUID(), navigationID: UUID(), view: view)
        #expect(probe.calls.isEmpty && cache.count == 0)
        let limits = PageSnapshotCache.Limits(entries: .max, bytes: .max, pixelWidth: .max, pixelHeight: .max, pending: .max)
        #expect(limits.entries == 32 && limits.bytes == 16 * 1_024 * 1_024)
        #expect(limits.pixelWidth == 512 && limits.pixelHeight == 320 && limits.pending == 16)
    }

    @Test func failedSnapshotDoesNotReplaceExistingPixels() {
        let probe = SnapshotProbe(), view = view(), id = UUID()
        let cache = PageSnapshotCache(profileID: UUID(), capture: probe.capture)
        cache.request(tabID: id, navigationID: UUID(), view: view)
        probe.finish(0, image: image())
        cache.request(tabID: id, navigationID: UUID(), view: view)
        probe.finish(1, image: nil)
        #expect(cache.image(for: id) != nil && cache.count == 1 && cache.inFlightCount == 0)
    }

    @Test func captureGeometryBoundsIntermediatePixelsBeforeWebKitAllocates() throws {
        let limits = PageSnapshotCache.Limits(pixelWidth: 320, pixelHeight: 200)
        for scale in [CGFloat(1), 2, 3] {
            for rect in [CGRect(x: 0, y: 0, width: 1_200, height: 800),
                         CGRect(x: 0, y: 0, width: 200, height: 1_000)] {
                let width = try #require(PageSnapshotCache.snapshotWidth(for: rect, scale: scale, limits: limits))
                #expect(width * scale <= 320)
                #expect(width * scale * rect.height / rect.width <= 200.001)
            }
        }
        #expect(PageSnapshotCache.snapshotWidth(for: CGRect(x: 0, y: 0, width: 1, height: 32_000), scale: 2, limits: limits) == nil)
        #expect(PageSnapshotCache.snapshotWidth(for: CGRect(x: 0, y: 0, width: 1_000_000, height: 1), scale: 2, limits: limits) == nil)
        #expect(PageSnapshotCache.snapshotWidth(for: .infinite, scale: 2, limits: limits) == nil)
        #expect(PageSnapshotCache.snapshotWidth(for: .zero, scale: 2, limits: limits) == nil)
        #expect(PageSnapshotCache.snapshotWidth(for: CGRect(x: 0, y: 0, width: 10, height: 10), scale: .infinity, limits: limits) == nil)
    }
}

@MainActor private final class SnapshotProbe {
    struct Call {
        weak var view: WKWebView?
        let rect: CGRect
        let width: Double
        let afterUpdates: Bool
        let completion: @MainActor (NSImage?) -> Void
    }
    var calls: [Call] = []
    func capture(_ view: WKWebView, _ configuration: WKSnapshotConfiguration,
                 completion: @escaping @MainActor (NSImage?) -> Void) {
        calls.append(Call(view: view, rect: configuration.rect,
            width: configuration.snapshotWidth?.doubleValue ?? .infinity,
            afterUpdates: configuration.afterScreenUpdates, completion: completion))
    }
    func finish(_ index: Int, image: NSImage?) { calls[index].completion(image) }
}
