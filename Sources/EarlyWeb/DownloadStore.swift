// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreServices
import Observation
import WebKit

/// One file transfer or saved document. The app's per-profile list owns it,
/// not a page, tab or window, so closing or discarding the source page never
/// ends the transfer. Metadata lives only for this app session.
@MainActor @Observable
public final class DownloadItem: Identifiable {
    public enum State: Equatable, Sendable {
        case preparing, downloading, paused, finished, failed, cancelled
        public var isActive: Bool { self == .preparing || self == .downloading }
    }

    public let id = UUID()
    /// Only a web address is kept; data/blob sources stay page-local.
    public let sourceURL: URL?
    public internal(set) var filename: String
    public internal(set) var destination: URL?
    public internal(set) var state = State.preparing
    public internal(set) var failureReason: String?
    public internal(set) var completedBytes: Int64 = 0
    public internal(set) var expectedBytes: Int64?
    /// WebKit's data for continuing a stopped or interrupted transfer.
    public internal(set) var resumeData: Data?
    /// A document Early wrote itself (Save Page As, Export as PDF).
    public internal(set) var wasSaved = false

    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(expectedBytes)))
    }

    /// A stopped or interrupted transfer that keeps its partial file.
    public var canResume: Bool { (state == .paused || state == .failed) && resumeData != nil }

    @ObservationIgnored let originURL: URL?
    @ObservationIgnored let listed: Bool
    @ObservationIgnored let requestedDestination: URL?
    @ObservationIgnored var download: WKDownload?
    /// A transient, never-displayed view that restarts a transfer when the
    /// profile has no page open. Released when the transfer settles.
    @ObservationIgnored var resumeHost: WKWebView?
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    @ObservationIgnored var onSettled: [(DownloadItem) -> Void] = []

    init(source: URL?, origin: URL?, requestedDestination: URL?, listed: Bool) {
        sourceURL = DownloadStore.webAddress(source)
        originURL = DownloadStore.webAddress(origin)
        self.requestedDestination = requestedDestination
        self.listed = listed
        filename = requestedDestination?.lastPathComponent ?? source?.lastPathComponent.nonEmptyFilename ?? "Download"
    }
}

/// Downloads and saved documents for one browsing profile. WebKit continues
/// each transfer in its network process; this list chooses destinations,
/// reports progress and lets the user stop, resume, cancel, open or reveal.
@MainActor @Observable
public final class DownloadStore: NSObject, WKDownloadDelegate {
    public static let maximumListedItems = 100

    public private(set) var items: [DownloadItem] = []
    /// Increments for every new listed download or saved file (footer feedback).
    public private(set) var startedRevision = 0
    /// Increments when a listed download or saved file completes.
    public private(set) var finishedRevision = 0
    /// The profile's website data store, used to resume a stopped transfer.
    @ObservationIgnored public var dataStoreProvider: (() -> WKWebsiteDataStore?)?
    @ObservationIgnored private let directoryProvider: () -> URL
    @ObservationIgnored private var tracked: [ObjectIdentifier: DownloadItem] = [:]
    @ObservationIgnored private var reserved: Set<String> = []

    public init(directory: URL? = nil) {
        if let directory {
            directoryProvider = { directory }
        } else {
            directoryProvider = {
                // In the sandbox this is the container's link to ~/Downloads;
                // resolve it so Finder reveals the user's real Downloads folder.
                (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
            }
        }
    }

    public var directory: URL { directoryProvider() }
    public var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }
    public var activeCount: Int { items.filter { $0.state.isActive }.count }

    /// Combined progress of active listed downloads, or nil while any size is unknown.
    public var activeProgress: Double? {
        let active = items.filter { $0.state.isActive }
        guard !active.isEmpty, active.allSatisfy({ ($0.expectedBytes ?? 0) > 0 }) else { return nil }
        let expected = active.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) }
        let completed = active.reduce(Int64(0)) { $0 + min($1.completedBytes, $1.expectedBytes ?? 0) }
        return Double(completed) / Double(expected)
    }

    @discardableResult
    func adopt(_ download: WKDownload, source: URL?, origin: URL?, destination: URL? = nil, listed: Bool = true) -> DownloadItem {
        let item = DownloadItem(source: source, origin: origin, requestedDestination: destination, listed: listed)
        attach(download, to: item)
        if listed {
            items.insert(item, at: 0)
            trimList()
            startedRevision += 1
        }
        return item
    }

    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download
        tracked[ObjectIdentifier(download)] = item
        download.delegate = self
        let progress = download.progress
        let gate = RefreshGate()
        let changed: @Sendable () -> Void = { [weak self, weak item] in
            gate.schedule { [weak self, weak item] in
                guard let self, let item else { return }
                self.synchronizeProgress(item)
            }
        }
        item.observations = [
            progress.observe(\.completedUnitCount) { _, _ in changed() },
            progress.observe(\.totalUnitCount) { _, _ in changed() }
        ]
    }

    /// Lists a document Early wrote itself, such as a saved page or PDF.
    @discardableResult
    public func recordSavedFile(at destination: URL, source: URL?) -> DownloadItem {
        let item = DownloadItem(source: source, origin: nil, requestedDestination: destination, listed: true)
        item.destination = destination
        item.state = .finished
        item.wasSaved = true
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            item.completedBytes = Int64(size)
            item.expectedBytes = Int64(size)
        }
        items.insert(item, at: 0)
        trimList()
        startedRevision += 1
        finishedRevision += 1
        return item
    }

    /// Stops a transfer and keeps its partial file so it can resume later, as
    /// in Safari. A transfer WebKit cannot resume is cancelled instead.
    public func stop(_ item: DownloadItem) {
        guard item.state == .downloading, let download = item.download else {
            cancel(item)
            return
        }
        item.state = .paused
        tracked.removeValue(forKey: ObjectIdentifier(download))
        releaseTransfer(item)
        download.cancel { [weak self, weak item] resumeData in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, item.state == .paused else { return }
                if let resumeData {
                    item.resumeData = resumeData
                } else {
                    self.discardPartialFile(of: item)
                    item.state = .cancelled
                }
            }
        }
    }

    /// Continues a stopped or interrupted transfer into its original file.
    @discardableResult
    public func resume(_ item: DownloadItem) -> Bool {
        guard item.canResume, let resumeData = item.resumeData else { return false }
        let configuration = WKWebViewConfiguration()
        if let store = dataStoreProvider?() { configuration.websiteDataStore = store }
        let host = WKWebView(frame: .zero, configuration: configuration)
        item.resumeHost = host
        item.resumeData = nil
        item.failureReason = nil
        item.state = .downloading
        if let destination = item.destination { reserved.insert(destination.standardizedFileURL.path) }
        Task { @MainActor [weak self, weak item] in
            let download = await host.resumeDownload(fromResumeData: resumeData)
            guard let self, let item, item.state == .downloading else {
                _ = await download.cancel()
                return
            }
            self.attach(download, to: item)
        }
        return true
    }

    /// Fully cancels: an active transfer stops, and any partial file is deleted.
    public func cancel(_ item: DownloadItem) {
        if item.canResume || item.state == .paused {
            discardPartialFile(of: item)
            item.resumeData = nil
            item.state = .cancelled
            return
        }
        guard item.state.isActive else { return }
        item.state = .cancelled
        let partial = item.destination
        if let download = item.download {
            tracked.removeValue(forKey: ObjectIdentifier(download))
            // Settles immediately: WebKit does not always report a cancelled
            // download as failed. Remove the partial file once it stops writing.
            download.cancel { _ in
                if let partial { try? FileManager.default.removeItem(at: partial) }
            }
        }
        releaseTransfer(item)
        releaseReservation(item)
    }

    /// Quitting or deleting the profile ends every transfer and removes partial
    /// files that could no longer be resumed.
    public func cancelAll() {
        for item in Array(tracked.values) + items where item.state.isActive || item.state == .paused || item.canResume {
            cancel(item)
        }
    }

    /// Removes finished, failed and cancelled rows. Files are never deleted;
    /// stopped transfers stay so they can resume.
    public func clearInactive() {
        items.removeAll { !$0.state.isActive && $0.state != .paused && !$0.canResume }
    }

    public func remove(_ item: DownloadItem) {
        guard !item.state.isActive else { return }
        if item.state == .paused || item.canResume { cancel(item) }
        items.removeAll { $0 === item }
    }

    public func fileExists(_ item: DownloadItem) -> Bool {
        guard item.state == .finished, let destination = item.destination else { return false }
        return FileManager.default.fileExists(atPath: destination.path)
    }

    /// A finished file, or the partial file of a stopped transfer.
    public func canReveal(_ item: DownloadItem) -> Bool {
        guard item.state == .finished || item.state == .paused || item.canResume,
              let destination = item.destination else { return false }
        return FileManager.default.fileExists(atPath: destination.path)
    }

    public func reveal(_ item: DownloadItem) {
        guard canReveal(item), let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    public func open(_ item: DownloadItem) {
        guard fileExists(item), let destination = item.destination else { return }
        NSWorkspace.shared.open(destination)
    }

    // MARK: WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        guard let item = tracked[ObjectIdentifier(download)], item.state.isActive else { return nil }
        if response.expectedContentLength > 0 { item.expectedBytes = response.expectedContentLength }
        let destination: URL
        if let existing = item.destination {
            destination = existing // A resumed transfer continues its own file.
        } else if let requested = item.requestedDestination {
            // A save panel already confirmed replacing this exact file. WebKit
            // refuses an existing destination, so remove only that chosen file.
            if FileManager.default.fileExists(atPath: requested.path) {
                try? FileManager.default.removeItem(at: requested)
            }
            destination = requested
        } else {
            let directory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            destination = Self.uniqueDestination(for: suggestedFilename, in: directory, reserved: reserved)
        }
        reserved.insert(destination.standardizedFileURL.path)
        item.destination = destination
        item.filename = destination.lastPathComponent
        item.state = .downloading
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = tracked.removeValue(forKey: ObjectIdentifier(download)) else { return }
        synchronizeProgress(item)
        if let destination = item.destination {
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                item.completedBytes = Int64(size)
                if item.expectedBytes == nil { item.expectedBytes = Int64(size) }
            }
            // Gatekeeper and Finder treat the file as downloaded from the web.
            Self.applyQuarantine(to: destination, source: item.sourceURL, origin: item.originURL)
        }
        item.state = .finished
        if item.listed { finishedRevision += 1 }
        releaseTransfer(item)
        releaseReservation(item)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = tracked.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let nsError = error as NSError
        releaseTransfer(item)
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled && resumeData == nil {
            item.state = .cancelled
        } else {
            item.state = .failed
            item.failureReason = nsError.localizedDescription
            if let resumeData {
                // An interrupted transfer keeps its partial file for Resume.
                item.resumeData = resumeData
                return
            }
        }
        // Never leave an incomplete file that looks like a finished download.
        discardPartialFile(of: item)
    }

    // MARK: Helpers

    private func synchronizeProgress(_ item: DownloadItem) {
        guard let progress = item.download?.progress else { return }
        item.completedBytes = max(item.completedBytes, progress.completedUnitCount)
        if progress.totalUnitCount > 0 { item.expectedBytes = progress.totalUnitCount }
    }

    /// Ends the live transfer: progress observation, transient host and the
    /// owner's callbacks (which release the source page's protection).
    private func releaseTransfer(_ item: DownloadItem) {
        item.observations.forEach { $0.invalidate() }
        item.observations.removeAll()
        item.download = nil
        item.resumeHost = nil
        let callbacks = item.onSettled
        item.onSettled.removeAll()
        callbacks.forEach { $0(item) }
    }

    private func releaseReservation(_ item: DownloadItem) {
        if let destination = item.destination { reserved.remove(destination.standardizedFileURL.path) }
    }

    private func discardPartialFile(of item: DownloadItem) {
        if let destination = item.destination, FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        releaseReservation(item)
    }

    private func trimList() {
        while items.count > Self.maximumListedItems, let index = items.lastIndex(where: { !$0.state.isActive }) {
            items.remove(at: index)
        }
    }

    static func webAddress(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// A plain file name: no path components, control characters or leading
    /// dot that would create a hidden file.
    static func sanitizedFilename(_ suggested: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var name = suggested.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Download" }
        let ext = (name as NSString).pathExtension
        if name.count > 200 {
            let base = (name as NSString).deletingPathExtension
            name = ext.isEmpty ? String(base.prefix(200)) : String(base.prefix(max(1, 199 - ext.count))) + "." + ext
        }
        return name
    }

    /// Finder-style numbering ("Report 2.pdf") avoids replacing existing files
    /// and destinations reserved by other downloads still in progress.
    static func uniqueDestination(for suggested: String, in directory: URL, reserved: Set<String>,
                                  exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = sanitizedFilename(suggested)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appending(path: name, directoryHint: .notDirectory)
        var counter = 2
        while exists(candidate) || reserved.contains(candidate.standardizedFileURL.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appending(path: numbered, directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }

    @discardableResult
    static func applyQuarantine(to url: URL, source: URL?, origin: URL?) -> Bool {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Early",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String
        ]
        if let source = webAddress(source) { properties[kLSQuarantineDataURLKey as String] = source }
        if let origin = webAddress(origin) { properties[kLSQuarantineOriginURLKey as String] = origin }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

private extension String {
    var nonEmptyFilename: String? { isEmpty || self == "/" ? nil : self }
}
