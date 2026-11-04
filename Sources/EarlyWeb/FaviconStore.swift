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
    @ObservationIgnored private var running: Set<Key> = []
    @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let load: @Sendable (String, [URL], Bool) async -> Data?

    private struct Request {
        let token = UUID()
        let candidates: [URL]
        let discovered: Bool
    }

    public convenience init(profileID: UUID, ephemeral: Bool = false) {
        let directory = ephemeral ? nil : Self.cacheDirectory(for: profileID)
        let loader = FaviconLoader(directory: directory)
        self.init { key, urls, cached in await loader.load(cacheKey: key, candidates: urls, preferCache: cached) }
    }

    init(appearance: Appearance? = nil, load: @escaping @Sendable (String, [URL], Bool) async -> Data?) {
        self.appearance = appearance ?? .current
        self.load = load
        if appearance == nil {
            appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.setAppearance(.current) }
            }
        }
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

    /// Only used after deleting a profile and waiting for its artwork requests.
    public nonisolated static func removeCache(for profileID: UUID) async throws {
        guard let directory = cacheDirectory(for: profileID) else { return }
        try await Task.detached(priority: .utility) {
            try ProfileDataCleanup.removeItem(at: directory)
        }.value
    }

    /// After website data is cleared, forgets artwork for every site except
    /// those of `pageURLs` (the profile's tabs, pins and Favorites, which keep
    /// their icons).
    public func forget(keeping pageURLs: [URL]) {
        let kept = Set(pageURLs.compactMap(Self.origin))
        for (key, task) in tasks where !kept.contains(key.origin) { task.cancel() }
        tasks = tasks.filter { kept.contains($0.key.origin) }
        pending.removeAll { !kept.contains($0.origin) }
        requests = requests.filter { kept.contains($0.key.origin) }
        running = running.filter { kept.contains($0.origin) }
        cachedImages = cachedImages.filter { kept.contains($0.key.origin) }
        cachedColors = cachedColors.filter { kept.contains($0.key.origin) }
        order.removeAll { !kept.contains($0.origin) }
    }

    /// Removes this profile's cached icons saved since `date` (nil: all),
    /// except those of the sites of `pageURLs`.
    public nonisolated static func removeCachedIcons(for profileID: UUID, since date: Date?, keeping pageURLs: [URL]) async {
        guard let directory = cacheDirectory(for: profileID) else { return }
        let kept = Set(pageURLs.compactMap(origin).flatMap { origin in
            // Include the old, unclassified file for website-data cleanup;
            // new loads never reuse it as an arbitrary appearance variant.
            [FaviconLoader.fileName(for: origin)] + Appearance.allCases.map {
                FaviconLoader.fileName(for: Key(origin: origin, appearance: $0).cacheIdentifier)
            }
        })
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where !kept.contains(file.lastPathComponent) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                if date.map({ modified >= $0 }) ?? true { try? FileManager.default.removeItem(at: file) }
            }
        }.value
    }

    public func shutdown() async {
        stopped = true
        appearanceObservation = nil
        let outstanding = Array(tasks.values)
        outstanding.forEach { $0.cancel() }
        pending.removeAll()
        requests.removeAll()
        for task in outstanding { await task.value }
        tasks.removeAll()
        running.removeAll()
        cachedImages.removeAll()
        cachedColors.removeAll()
        order.removeAll()
    }

    public func image(for url: URL, appearance: Appearance? = nil) -> NSImage? {
        Self.origin(url).flatMap { cachedImages[Key(origin: $0, appearance: appearance ?? self.appearance)] }
    }

    public func color(for url: URL) -> FaviconColor? {
        Self.origin(url).flatMap { cachedColors[Key(origin: $0, appearance: appearance)] }
    }

    /// Called by visible rows and when a live document's icon selection changes.
    /// Restored/closed pins only read the cache or request the site's icon file.
    public func request(_ pageURL: URL, discovered: [String]? = nil, appearance: Appearance? = nil) {
        guard !stopped, let origin = Self.origin(pageURL) else { return }
        let key = Key(origin: origin, appearance: appearance ?? self.appearance)
        let candidates = Self.candidates(pageURL: pageURL, discovered: discovered ?? [])
        let isDiscovered = discovered != nil
        if let previous = requests[key] {
            guard isDiscovered, !previous.discovered || previous.candidates != candidates else { return }
        }
        if requests[key] == nil {
            // Bound both decoded artwork and negative-cache bookkeeping.
            if order.count >= 256, let oldest = order.first(where: { !running.contains($0) && !pending.contains($0) }) {
                order.removeAll { $0 == oldest }
                requests.removeValue(forKey: oldest)
                cachedImages.removeValue(forKey: oldest)
                cachedColors.removeValue(forKey: oldest)
            }
            guard order.count < 256 else { return }
            order.append(key)
        }
        requests[key] = Request(candidates: candidates, discovered: isDiscovered)
        if !pending.contains(key) { pending.append(key) }
        drain()
    }

    private func drain() {
        guard !stopped else { return }
        while running.count < 4,
              let index = pending.firstIndex(where: { $0.appearance == appearance && !running.contains($0) })
                ?? pending.firstIndex(where: { !running.contains($0) }) {
            let key = pending.remove(at: index)
            guard let request = requests[key] else { continue }
            running.insert(key)
            let load = load
            tasks[key] = Task { [weak self] in
                let data = await load(key.cacheIdentifier, request.candidates, !request.discovered)
                let color = await Task.detached(priority: .utility) {
                    data.flatMap { FaviconColor.extract(from: $0) }
                }.value
                guard let self else { return }
                if !Task.isCancelled, self.requests[key]?.token == request.token,
                   let data, let image = NSImage(data: data) {
                    self.cachedImages[key] = image
                    self.cachedColors[key] = color
                }
                self.running.remove(key)
                self.tasks.removeValue(forKey: key)
                self.drain()
            }
        }
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

    func load(cacheKey: String, candidates: [URL], preferCache: Bool) async -> Data? {
        let cached = read(cacheKey)
        if preferCache, let cached { return cached }
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                var request = URLRequest(url: url)
                request.httpShouldHandleCookies = false
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await BoundedResponse.load(request, in: session, limit: Self.byteLimit - 1,
                                                                       redirects: Self.allowsRedirect)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                guard !Task.isCancelled, let png = Self.thumbnail(data) else { continue }
                write(png, origin: cacheKey)
                return png
            } catch { continue }
        }
        return cached
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
