// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import EarlyCore
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Website artwork is separate from session metadata and never creates a web view.
/// An origin shares one small icon per appearance; pins use their original origin.
@MainActor @Observable
public final class FaviconStore {
    public enum Appearance: String, CaseIterable, Sendable {
        case light, dark

        @MainActor static var current: Self {
            NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }

    private struct Key: Hashable, Sendable {
        let origin: String
        let appearance: Appearance
        var cacheIdentifier: String { origin + "#favicon-" + appearance.rawValue }
    }

    private struct Profile: Hashable {
        let id: UUID
        let ephemeral: Bool
    }

    private struct CacheReference { weak var cache: FaviconProfileCache? }
    private static var profileCaches: [Profile: CacheReference] = [:]
    private static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300)]

    public private(set) var appearance: Appearance
    private var cachedImages: [Key: NSImage] = [:]
    private var cachedColors: [Key: FaviconColor] = [:]
    public var images: [String: NSImage] {
        Dictionary(uniqueKeysWithValues: cachedImages.filter { $0.key.appearance == appearance }.map { ($0.key.origin, $0.value) })
    }
    public var colors: [String: FaviconColor] {
        Dictionary(uniqueKeysWithValues: cachedColors.filter { $0.key.appearance == appearance }.map { ($0.key.origin, $0.value) })
    }
    @ObservationIgnored private var requests: [Key: Request] = [:]
    @ObservationIgnored private var order: [Key] = []
    @ObservationIgnored private var pending: [Key] = []
    @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let cache: FaviconProfileCache
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let load: @Sendable (String, [URL], Bool) async -> FaviconLoad

    private struct Request {
        enum State {
            case loading
            case ready
            case failed(retryAt: ContinuousClock.Instant)
        }

        let token = UUID()
        let candidates: [URL]
        let discovered: Bool
        var failures = 0
        var state = State.loading
    }

    public convenience init(profileID: UUID, ephemeral: Bool = false) {
        let cache = Self.cache(for: profileID, ephemeral: ephemeral)
        let loader = cache.loader
        self.init(cache: cache, appearance: nil, now: { .now }) { key, urls, cached in
            await loader.load(cacheKey: key, candidates: urls, preferCache: cached)
        }
    }

    convenience init(appearance: Appearance? = nil, now: @escaping () -> ContinuousClock.Instant = { .now },
                     profileID: UUID? = nil, ephemeral: Bool = false,
                     load: @escaping @Sendable (String, [URL], Bool) async -> Data?) {
        let cache = profileID.map { Self.cache(for: $0, ephemeral: ephemeral) } ?? FaviconProfileCache(directory: nil)
        self.init(cache: cache, appearance: appearance, now: now) { key, urls, cached in
            if let data = await load(key, urls, cached) { return .loaded(data) }
            return .failed(cached: nil)
        }
    }

    private init(cache: FaviconProfileCache, appearance: Appearance?, now: @escaping () -> ContinuousClock.Instant,
                 load: @escaping @Sendable (String, [URL], Bool) async -> FaviconLoad) {
        self.appearance = appearance ?? .current
        self.load = load
        self.cache = cache
        self.now = now
        cache.add(self)
        if appearance == nil {
            appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.setAppearance(.current) }
            }
        }
    }

    private static func cache(for profileID: UUID, ephemeral: Bool) -> FaviconProfileCache {
        let key = Profile(id: profileID, ephemeral: ephemeral)
        if let cache = profileCaches[key]?.cache { return cache }
        profileCaches = profileCaches.filter { $0.value.cache != nil }
        let cache = FaviconProfileCache(directory: ephemeral ? nil : cacheDirectory(for: profileID))
        profileCaches[key] = CacheReference(cache: cache)
        return cache
    }

    /// Restored pins can switch artwork without opening a page. Live pages
    /// separately report their newly matching declared icons through WebKit.
    func setAppearance(_ value: Appearance) {
        guard !stopped, value != appearance else { return }
        appearance = value
        for origin in Set(requests.keys.map(\.origin)) {
            if let url = URL(string: origin) { request(url) }
        }
    }

    nonisolated static func cacheDirectory(for profileID: UUID) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Early/Favicons/\(profileID.uuidString)", isDirectory: true)
    }

    /// Permanently stops the profile's artwork requests before removing its cache.
    public static func removeCache(for profileID: UUID, ephemeral: Bool = false) async throws {
        try await cache(for: profileID, ephemeral: ephemeral).remove()
    }

    /// Forgets in-memory artwork for every site except
    /// those of `pageURLs` (the profile's tabs, pins and Favorites, which keep
    /// their icons).
    public func forget(keeping pageURLs: [URL]) {
        _ = forget(keeping: Set(pageURLs.compactMap(Self.origin)))
    }

    fileprivate func forget(keeping kept: Set<String>) -> [Task<Void, Never>] {
        // Keep the physical slots until these tasks finish, even when a new
        // request for the same key is queued behind a cancelled one.
        let cancelled = tasks.compactMap { kept.contains($0.key.origin) ? nil : $0.value }
        cancelled.forEach { $0.cancel() }
        pending.removeAll { !kept.contains($0.origin) }
        requests = requests.filter { kept.contains($0.key.origin) }
        cachedImages = cachedImages.filter { kept.contains($0.key.origin) }
        cachedColors = cachedColors.filter { kept.contains($0.key.origin) }
        order.removeAll { !kept.contains($0.origin) }
        return cancelled
    }

    func clear(since date: Date?, keeping pageURLs: [URL]) async {
        await cache.clear(since: date, keeping: Set(pageURLs.compactMap(Self.origin)))
    }

    /// Clears profile artwork even when no browsing window is open.
    public static func removeCachedIcons(for profileID: UUID, since date: Date?, keeping pageURLs: [URL],
                                         ephemeral: Bool = false) async {
        await cache(for: profileID, ephemeral: ephemeral).clear(since: date, keeping: Set(pageURLs.compactMap(origin)))
    }

    fileprivate nonisolated static func fileNames(for origins: Set<String>) -> Set<String> {
        Set(origins.flatMap { origin in
            // Include the old, unclassified file for website-data cleanup;
            // new loads never reuse it as an arbitrary appearance variant.
            [FaviconLoader.fileName(for: origin)] + Appearance.allCases.map {
                FaviconLoader.fileName(for: Key(origin: origin, appearance: $0).cacheIdentifier)
            }
        })
    }

    public func shutdown() async {
        let outstanding = stop()
        for task in outstanding { await task.value }
    }

    fileprivate func stop() -> [Task<Void, Never>] {
        stopped = true
        appearanceObservation = nil
        return forget(keeping: [])
    }

    public func image(for url: URL, appearance: Appearance? = nil) -> NSImage? {
        Self.origin(url).flatMap { cachedImages[Key(origin: $0, appearance: appearance ?? self.appearance)] }
    }

    public func color(for url: URL) -> FaviconColor? {
        Self.origin(url).flatMap { cachedColors[Key(origin: $0, appearance: appearance)] }
    }

    /// Called by visible rows and when a live document's icon selection changes.
    /// Restored/closed pins only read the cache or request the site's icon file.
    /// Failures are retried on demand once their backoff expires.
    public func request(_ pageURL: URL, discovered: [String]? = nil, appearance: Appearance? = nil) {
        guard !stopped, !cache.removed, let origin = Self.origin(pageURL) else { return }
        let key = Key(origin: origin, appearance: appearance ?? self.appearance)
        // Ordinary row updates keep an earlier discovery's candidate list.
        if discovered == nil, let previous = requests[key] {
            retry(key, previous, explicitly: false)
            return
        }
        let candidates = Self.candidates(pageURL: pageURL, discovered: discovered ?? [])
        let isDiscovered = discovered != nil
        if let previous = requests[key], previous.discovered == isDiscovered, previous.candidates == candidates {
            retry(key, previous, explicitly: false)
            return
        }
        if requests[key] == nil {
            // Bound both decoded artwork and negative-cache bookkeeping.
            if order.count >= 256, let oldest = order.first(where: { tasks[$0] == nil && !pending.contains($0) }) {
                order.removeAll { $0 == oldest }
                requests.removeValue(forKey: oldest)
                cachedImages.removeValue(forKey: oldest)
                cachedColors.removeValue(forKey: oldest)
            }
            guard order.count < 256 else { return }
            order.append(key)
        }
        enqueue(key, Request(candidates: candidates, discovered: isDiscovered))
    }

    /// An explicit reload can retry a failed appearance with its known URLs.
    func retryFailedIcons(for pageURL: URL) {
        guard !stopped, !cache.removed, let origin = Self.origin(pageURL) else { return }
        for appearance in Appearance.allCases {
            let key = Key(origin: origin, appearance: appearance)
            if let previous = requests[key] { retry(key, previous, explicitly: true) }
        }
    }

    private func retry(_ key: Key, _ request: Request, explicitly: Bool) {
        guard case .failed(let retryAt) = request.state, explicitly || now() >= retryAt else { return }
        enqueue(key, Request(candidates: request.candidates, discovered: request.discovered, failures: request.failures))
    }

    private func enqueue(_ key: Key, _ request: Request) {
        requests[key] = request
        if !pending.contains(key) { pending.append(key) }
        drain()
    }

    fileprivate func drain() {
        guard !stopped, !cache.removed, !cache.isClearing else { return }
        while tasks.count < 4,
              let index = pending.firstIndex(where: { $0.appearance == appearance && tasks[$0] == nil })
                ?? pending.firstIndex(where: { tasks[$0] == nil }) {
            let key = pending.remove(at: index)
            guard let request = requests[key] else { continue }
            let load = load, cache = cache
            let task = Task { [weak self] in
                defer {
                    cache.finished(request.token)
                    self?.tasks[key] = nil
                    self?.drain()
                }
                let result = await load(key.cacheIdentifier, request.candidates, !request.discovered)
                guard !Task.isCancelled, self?.requests[key]?.token == request.token else { return }
                let color: FaviconColor?
                if let data = result.data {
                    color = await Task.detached(priority: .utility) { FaviconColor.extract(from: data) }.value
                } else { color = nil }
                guard let self, !Task.isCancelled, self.requests[key]?.token == request.token else { return }
                self.complete(key, request: request, result: result, color: color)
            }
            tasks[key] = task
            cache.track(task, token: request.token, origin: key.origin)
        }
    }

    private func complete(_ key: Key, request: Request, result: FaviconLoad, color: FaviconColor?) {
        if let data = result.data, let image = NSImage(data: data) {
            cachedImages[key] = image
            cachedColors[key] = color
            if case .loaded = result {
                requests[key]?.state = .ready
                return
            }
        }
        let index = min(request.failures, Self.retryDelays.count - 1)
        requests[key]?.failures = index + 1
        requests[key]?.state = .failed(retryAt: now().advanced(by: Self.retryDelays[index]))
    }

    nonisolated static func origin(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }

    static func candidates(pageURL: URL, discovered: [String]) -> [URL] {
        guard let origin = origin(pageURL) else { return [] }
        var result: [URL] = []
        for value in discovered.prefix(8) {
            guard value.utf8.count <= 4096, let url = URL(string: value, relativeTo: pageURL)?.absoluteURL,
                  Self.origin(url) != nil,
                  !(pageURL.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https"),
                  !result.contains(url) else { continue }
            result.append(url)
            if result.count == 3 { break }
        }
        let fallback = URL(string: origin + "/favicon.ico")!
        if !result.contains(fallback) { result.append(fallback) }
        return result
    }
}

/// Holds the disk writer and clear barrier for all the windows of a profile.
@MainActor
private final class FaviconProfileCache {
    private struct StoreReference { weak var store: FaviconStore? }
    private struct Load {
        let origin: String
        let task: Task<Void, Never>
    }
    private var stores: [StoreReference] = []
    // Closing a window releases its pending queue. Keep only the running
    // loads here until the loader returns, including any in-progress write.
    private var loads: [UUID: Load] = [:]
    private let directory: URL?
    lazy var loader = FaviconLoader(directory: directory)
    private var clearTask: Task<Void, Never>?
    private var removalTask: Task<Void, any Error>?
    private(set) var removed = false
    var isClearing: Bool { clearTask != nil }

    init(directory: URL?) { self.directory = directory }

    func add(_ store: FaviconStore) {
        stores.removeAll { $0.store == nil }
        stores.append(StoreReference(store: store))
    }

    func track(_ task: Task<Void, Never>, token: UUID, origin: String) {
        loads[token] = Load(origin: origin, task: task)
    }

    func finished(_ token: UUID) { loads[token] = nil }

    private func cancelLoads(keeping kept: Set<String>) -> [Task<Void, Never>] {
        let affected = loads.values.compactMap { kept.contains($0.origin) ? nil : $0.task }
        affected.forEach { $0.cancel() }
        return affected
    }

    func clear(since date: Date?, keeping kept: Set<String>) async {
        // A second caller clears against its own date and kept sites.
        while let clearTask { await clearTask.value }
        if let removalTask { _ = await removalTask.result; return }
        guard !removed else { return }
        let task = Task {
            for store in stores.compactMap(\.store) { _ = store.forget(keeping: kept) }
            let outstanding = cancelLoads(keeping: kept)
            for request in outstanding { await request.value }
            if directory != nil { await loader.clear(since: date, keeping: kept) }
            clearTask = nil
            for store in stores.compactMap(\.store) { store.drain() }
        }
        clearTask = task
        await task.value
    }

    func remove() async throws {
        if let removalTask { return try await removalTask.value }
        removed = true
        let task = Task {
            for store in stores.compactMap(\.store) { _ = store.stop() }
            let outstanding = cancelLoads(keeping: [])
            for request in outstanding { await request.value }
            await clearTask?.value
            if directory != nil { try await loader.removeCache() }
        }
        removalTask = task
        defer { removalTask = nil }
        try await task.value
    }
}

enum FaviconLoad: Sendable {
    case loaded(Data)
    case failed(cached: Data?)

    var data: Data? {
        switch self {
        case .loaded(let data): data
        case .failed(let cached): cached
        }
    }
}

/// Disk access, streaming and bounded image decoding happen off the main actor.
actor FaviconLoader {
    static let byteLimit = 512 * 1024
    private let directory: URL?
    private let session: URLSession

    init(directory: URL?, configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func load(cacheKey: String, candidates: [URL], preferCache: Bool) async -> FaviconLoad {
        let cached = read(cacheKey)
        if preferCache, let cached { return .loaded(cached) }
        for url in candidates {
            guard !Task.isCancelled else { return .failed(cached: nil) }
            do {
                var request = URLRequest(url: url)
                request.httpShouldHandleCookies = false
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await BoundedResponse.load(request, in: session, limit: Self.byteLimit - 1,
                                                                       redirects: Self.allowsRedirect)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard !Task.isCancelled, let png = Self.thumbnail(data) else { continue }
                write(png, origin: cacheKey)
                return .loaded(png)
            } catch { continue }
        }
        return .failed(cached: cached)
    }

    func clear(since date: Date?, keeping origins: Set<String>) {
        guard let directory else { return }
        let kept = FaviconStore.fileNames(for: origins)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if date.map({ modified >= $0 }) ?? true { try? FileManager.default.removeItem(at: file) }
        }
    }

    func removeCache() throws {
        if let directory { try ProfileDataCleanup.removeItem(at: directory) }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated static func fileName(for origin: String) -> String {
        SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func file(_ origin: String) -> URL? {
        directory?.appendingPathComponent(Self.fileName(for: origin))
    }

    private func read(_ origin: String) -> Data? {
        guard let file = file(origin), let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size <= Self.byteLimit,
              let date = values.contentModificationDate, Date().timeIntervalSince(date) < 7 * 86400,
              let data = try? Data(contentsOf: file) else { return nil }
        return Self.thumbnail(data)
    }

    private func write(_ data: Data, origin: String) {
        guard let directory, let file = file(origin) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "png" }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast <
                    (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            // Only this profile's disposable icon cache is pruned.
            for old in files.prefix(max(0, files.count - 256)) { try? FileManager.default.removeItem(at: old) }
        } catch { /* A read-only cache must not affect browsing. */ }
    }
}

extension FaviconLoader {
    /// Only to web addresses without credentials, and never from HTTPS down to HTTP.
    static let allowsRedirect: BoundedResponse.Redirects = { response, request in
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return false }
        return !(response.url?.scheme == "https" && url.scheme != "https")
    }
}
