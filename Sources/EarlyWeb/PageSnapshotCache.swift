// SPDX-License-Identifier: MPL-2.0

import AppKit
import Observation
import WebKit

/// Small, memory-only previews owned by one profile. Callers provide an existing
/// live view at a navigation/visibility event; reading a preview never loads one.
@MainActor @Observable
public final class PageSnapshotCache {
    public struct Limits: Equatable, Sendable {
        public let entries: Int
        public let bytes: Int
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let pending: Int

        public init(entries: Int = 16, bytes: Int = 8 * 1_024 * 1_024,
                    pixelWidth: Int = 320, pixelHeight: Int = 200, pending: Int = 8) {
            // Hard ceilings also make custom policies safe against accidental
            // unbounded allocation and overflowing pixel/byte arithmetic.
            self.entries = min(max(entries, 0), 32)
            self.bytes = min(max(bytes, 0), 16 * 1_024 * 1_024)
            self.pixelWidth = min(max(pixelWidth, 1), 512)
            self.pixelHeight = min(max(pixelHeight, 1), 320)
            self.pending = min(max(pending, 0), 16)
        }
    }

    public let profileID: UUID
    public let limits: Limits
    public private(set) var byteCount = 0
    public var count: Int { entries.count }
    public var pendingCount: Int { pending.count }
    public var inFlightCount: Int { running == nil ? 0 : 1 }

    private struct Entry {
        let image: NSImage
        let bytes: Int
    }

    private final class Request {
        let token = UUID()
        let tabID: UUID
        let navigationID: UUID
        weak var view: WKWebView?
        init(tabID: UUID, navigationID: UUID, view: WKWebView) {
            self.tabID = tabID
            self.navigationID = navigationID
            self.view = view
        }
    }

    typealias Capture = @MainActor (WKWebView, WKSnapshotConfiguration, @escaping @MainActor (NSImage?) -> Void) -> Void

    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var requests: [UUID: Request] = [:]
    @ObservationIgnored private var pending: [UUID] = []
    @ObservationIgnored private var running: Request?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let capture: Capture

    public convenience init(profileID: UUID, enabled: Bool = true, limits: Limits = Limits()) {
        self.init(profileID: profileID, enabled: enabled, limits: limits) { view, configuration, completion in
            view.takeSnapshot(with: configuration) { image, _ in completion(image) }
        }
    }

    init(profileID: UUID, enabled: Bool = true, limits: Limits = Limits(), capture: @escaping Capture) {
        self.profileID = profileID
        self.enabled = enabled
        self.limits = limits
        self.capture = capture
    }

    public func image(for tabID: UUID) -> NSImage? {
        guard let entry = entries[tabID] else { return nil }
        touch(tabID)
        return entry.image
    }

    /// Duplicate events for the same pending page coalesce. At most one WebKit
    /// capture is physically outstanding, including an invalidated capture.
    public func request(tabID: UUID, navigationID: UUID, view: WKWebView) {
        guard enabled, !stopped, limits.entries > 0, limits.bytes > 0,
              Self.valid(view.bounds) else { return }
        if let previous = requests[tabID], previous.navigationID == navigationID,
           previous.view === view { return }
        requests[tabID] = Request(tabID: tabID, navigationID: navigationID, view: view)
        pending.removeAll { $0 == tabID }
        pending.append(tabID)
        // Keep the latest events; abandoned queue entries own no views/images.
        while pending.count > limits.pending + (running == nil ? 1 : 0) {
            let oldest = pending.removeFirst()
            requests[oldest] = nil
        }
        drain()
    }

    /// Invalidate on navigation, close, sensitive-content policy, or page failure.
    /// A late WebKit completion cannot repopulate the cleared entry.
    public func invalidate(tabID: UUID) {
        cancelCapture(tabID: tabID)
        removeEntry(tabID)
    }

    /// Retiring a live page cancels its pending pixels while retaining the last
    /// completed preview for the same durable tab. Closing/deleting uses invalidate.
    public func cancelCapture(tabID: UUID) {
        requests[tabID] = nil
        pending.removeAll { $0 == tabID }
    }

    public func retain(tabIDs: Set<UUID>) {
        for id in Set(entries.keys).union(requests.keys) where !tabIDs.contains(id) { invalidate(tabID: id) }
    }

    /// Clears pixels and queued work immediately, including callbacks already in
    /// flight. No image is written to the session, cache directory, or filesystem.
    public func clear() {
        requests.removeAll()
        pending.removeAll()
        entries.removeAll()
        order.removeAll()
        byteCount = 0
    }

    public func shutdown() {
        stopped = true
        clear()
    }

    private func drain() {
        guard running == nil, !stopped else { return }
        while !pending.isEmpty {
            let id = pending.removeFirst()
            guard let request = requests[id] else { continue }
            guard let view = request.view, Self.valid(view.bounds) else {
                requests[id] = nil
                continue
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            // WebKit's snapshot width is in points. Account for Retina before
            // capture, then rasterize again into our exact pixel bounds below.
            let scale = max(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
            guard let width = Self.snapshotWidth(for: view.bounds, scale: scale, limits: limits) else {
                requests[id] = nil
                continue
            }
            configuration.snapshotWidth = NSNumber(value: width)
            configuration.afterScreenUpdates = false
            running = request
            capture(view, configuration) { [weak self] image in
                self?.finish(request, image: image)
            }
            return
        }
    }

    private func finish(_ request: Request, image: NSImage?) {
        // Invalidating cannot cancel WebKit's API. Keep its physical slot until
        // completion so repeated cancellations cannot start unlimited captures.
        guard running?.token == request.token else { return }
        running = nil
        if !stopped, requests[request.tabID]?.token == request.token {
            requests[request.tabID] = nil
            if let image, let entry = thumbnail(image), entry.bytes <= limits.bytes {
                removeEntry(request.tabID)
                while !order.isEmpty && (entries.count >= limits.entries || byteCount + entry.bytes > limits.bytes) {
                    removeEntry(order[0])
                }
                entries[request.tabID] = entry
                byteCount += entry.bytes
                touch(request.tabID)
            }
        }
        drain()
    }

    private func thumbnail(_ image: NSImage) -> Entry? {
        guard Self.valid(CGRect(origin: .zero, size: image.size)) else { return nil }
        // NSImage.size is in points; Retina representations can have twice as
        // many pixels. Keep the useful pixels without relying on display scale.
        let source = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        let sourceWidth = source.map { CGFloat($0.pixelsWide) } ?? image.size.width
        let sourceHeight = source.map { CGFloat($0.pixelsHigh) } ?? image.size.height
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let ratio = min(CGFloat(limits.pixelWidth) / sourceWidth,
            CGFloat(limits.pixelHeight) / sourceHeight, 1)
        let width = max(1, Int((sourceWidth * ratio).rounded(.down)))
        let height = max(1, Int((sourceHeight * ratio).rounded(.down)))
        let bytesPerRow = width * 4
        guard bytesPerRow * height <= limits.bytes,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: bytesPerRow, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: width, height: height))
        result.addRepresentation(bitmap)
        return Entry(image: result, bytes: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    private func removeEntry(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) { byteCount -= entry.bytes }
        order.removeAll { $0 == id }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty && rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.maxX.isFinite && rect.maxY.isFinite &&
            rect.width > 0 && rect.height > 0
    }

    static func snapshotWidth(for rect: CGRect, scale: CGFloat, limits: Limits) -> Double? {
        guard valid(rect), scale.isFinite, scale >= 1,
              rect.width <= 32_768, rect.height <= 32_768 else { return nil }
        let pixels = min(CGFloat(limits.pixelWidth), CGFloat(limits.pixelHeight) * rect.width / rect.height)
        let width = pixels / scale
        // Rounding an extremely narrow capture up to a point could make its
        // proportional height enormous. Skip it instead of exceeding the budget.
        return width >= 1 && width.isFinite ? Double(width) : nil
    }
}
