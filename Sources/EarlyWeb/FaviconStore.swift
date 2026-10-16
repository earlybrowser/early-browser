import AppKit
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Website artwork is separate from session metadata and never creates a web view.
/// An origin shares one small icon; pins use their original origin, not a detour.
@MainActor @Observable
public final class FaviconStore {
    public private(set) var images: [String: NSImage] = [:]
    public private(set) var colors: [String: FaviconColor] = [:]
    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private let load: @Sendable (String, [URL], Bool) async -> Data?

    private struct Request {
        let token = UUID()
        let candidates: [URL]
        let discovered: Bool
    }

    public convenience init(profileID: UUID, ephemeral: Bool = false) {
        let directory = ephemeral ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Early/Favicons/\(profileID.uuidString)", isDirectory: true)
        let loader = FaviconLoader(directory: directory)
        self.init { origin, urls, cached in await loader.load(origin: origin, candidates: urls, preferCache: cached) }
    }

    init(load: @escaping @Sendable (String, [URL], Bool) async -> Data?) { self.load = load }

    public func image(for url: URL) -> NSImage? {
        Self.origin(url).flatMap { images[$0] }
    }

    public func color(for url: URL) -> FaviconColor? {
        Self.origin(url).flatMap { colors[$0] }
    }

    /// Called by visible rows and once after a live page finishes navigating.
    /// Restored/closed pins only read the cache or request the site's icon file.
    public func request(_ pageURL: URL, discovered: [String] = []) {
        guard let origin = Self.origin(pageURL) else { return }
        let candidates = Self.candidates(pageURL: pageURL, discovered: discovered)
        let isDiscovered = candidates.count > 1 || candidates.first != URL(string: origin + "/favicon.ico")
        if let previous = requests[origin] {
            guard isDiscovered, previous.candidates != candidates else { return }
        }
        if requests[origin] == nil {
            // Bound both decoded artwork and negative-cache bookkeeping.
            if order.count >= 256, let oldest = order.first(where: { !running.contains($0) && !pending.contains($0) }) {
                order.removeAll { $0 == oldest }
                requests.removeValue(forKey: oldest)
                images.removeValue(forKey: oldest)
                colors.removeValue(forKey: oldest)
            }
            guard order.count < 256 else { return }
            order.append(origin)
        }
        requests[origin] = Request(candidates: candidates, discovered: isDiscovered)
        if !pending.contains(origin) { pending.append(origin) }
        drain()
    }

    private func drain() {
        while running.count < 4, let index = pending.firstIndex(where: { !running.contains($0) }) {
            let origin = pending.remove(at: index)
            guard let request = requests[origin] else { continue }
            running.insert(origin)
            let load = load
            Task { [weak self] in
                let data = await load(origin, request.candidates, !request.discovered)
                let color = await Task.detached(priority: .utility) {
                    data.flatMap { FaviconColor.extract(from: $0) }
                }.value
                guard let self else { return }
                if self.requests[origin]?.token == request.token,
                   let data, let image = NSImage(data: data) {
                    self.images[origin] = image
                    self.colors[origin] = color
                }
                self.running.remove(origin)
                self.drain()
            }
        }
    }

    static func origin(_ url: URL) -> String? {
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
        session = URLSession(configuration: configuration, delegate: FaviconRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func load(origin: String, candidates: [URL], preferCache: Bool) async -> Data? {
        let cached = read(origin)
        if preferCache, let cached { return cached }
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                var request = URLRequest(url: url)
                request.httpShouldHandleCookies = false
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      response.expectedContentLength <= Self.byteLimit else {
                    bytes.task.cancel(); continue
                }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= Self.byteLimit || Task.isCancelled { bytes.task.cancel(); break }
                    data.append(byte)
                }
                guard data.count < Self.byteLimit, let png = Self.thumbnail(data) else { continue }
                write(png, origin: origin)
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

    private func file(_ origin: String) -> URL? {
        let key = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(key + ".png")
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

private final class FaviconRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              !(response.url?.scheme == "https" && url.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
}
