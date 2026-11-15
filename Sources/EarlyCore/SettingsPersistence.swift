// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

/// Profile settings participate in quit even after their last window closes.
@MainActor
public protocol SettingsStore: AnyObject {
    var acceptsChanges: Bool { get set }
    var loadError: String? { get }
    var saveError: String? { get }
    func flush(timeout: Duration) async -> Bool
    func retrySaving()
}

/// One reader and one writer per application-owned catalog. The live value is
/// the pending snapshot: edits never queue whole files. Removal drains any I/O
/// already in progress before deleting, including a write past its commit point.
@MainActor @Observable
final class SettingsPersistence<Value: Sendable> {
    private(set) var value: Value
    private(set) var isLoaded: Bool
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isRemoved = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    var acceptsChanges = true
    var canChange: Bool { isLoaded && !isRemoved && acceptsChanges }

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored private let empty: Value
    @ObservationIgnored private let decode: @Sendable (Data) throws -> Value
    @ObservationIgnored private let encode: @Sendable (Value) throws -> Data
    @ObservationIgnored var readFile: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    @ObservationIgnored var writeFile: @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    @ObservationIgnored private var loading: Task<Bool, Never>?
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var removing: Task<Void, Error>?
    @ObservationIgnored private var requestedRevision = 0
    @ObservationIgnored private var durableRevision = 0
    @ObservationIgnored var onAvailabilityChange: (() -> Void)?

    init(fileURL: URL?, empty: Value, decode: @escaping @Sendable (Data) throws -> Value,
         encode: @escaping @Sendable (Value) throws -> Data) {
        self.fileURL = fileURL
        self.empty = empty
        value = empty
        isLoaded = fileURL == nil
        self.decode = decode
        self.encode = encode
        if fileURL != nil { startLoading() }
    }

    /// A failed read never becomes an empty, writable catalog. Retrying must
    /// first recover the saved choices, so they cannot be silently overwritten.
    func load(retry: Bool = false) async -> Bool {
        guard !isRemoved else { return false }
        if isLoaded { return true }
        if let loading { return await loading.value }
        guard retry || loadError == nil else { return false }
        startLoading()
        return await loading?.value ?? false
    }

    private func startLoading() {
        guard !isRemoved, !isLoaded, loading == nil, let fileURL else { return }
        isLoading = true
        loading = Task { [weak self] in
            guard let self else { return false }
            defer { self.loading = nil; self.isLoading = false }
            let read = self.readFile, decode = self.decode, empty = self.empty
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Value in
                    do { return try decode(read(fileURL)) }
                    catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return empty }
                }
            }.value
            guard !self.isRemoved else { return false }
            switch result {
            case .success(let value):
                self.value = value
                self.isLoaded = true
                self.loadError = nil
                self.onAvailabilityChange?()
                return true
            case .failure(let error):
                self.loadError = error.localizedDescription
                return false
            }
        }
    }

    /// Callers compare before changing, avoiding saves for no-op edits.
    func change(_ value: Value) {
        mutate { $0 = value }
    }

    func mutate(_ body: (inout Value) -> Void) {
        guard canChange else { return }
        body(&value)
        requestedRevision += 1
        if fileURL == nil { durableRevision = requestedRevision; return }
        persist()
    }

    private func persist() {
        guard isLoaded, !isRemoved, writing == nil, let fileURL,
              durableRevision != requestedRevision else { return }
        isSaving = true
        writing = Task { [weak self] in
            guard let self else { return }
            defer { self.writing = nil; self.isSaving = false }
            // Coalesce a burst before taking a snapshot; flush waits for it.
            try? await Task.sleep(for: .milliseconds(25))
            while !self.isRemoved && self.durableRevision != self.requestedRevision {
                let revision = self.requestedRevision, snapshot = self.value
                let encode = self.encode, write = self.writeFile
                let error = await Task.detached(priority: .utility) { () -> String? in
                    do { try write(encode(snapshot), fileURL); return nil }
                    catch { return error.localizedDescription }
                }.value
                guard !self.isRemoved else { return }
                if let error { self.saveError = error; return }
                self.durableRevision = revision
                if revision == self.requestedRevision { self.saveError = nil }
            }
        }
    }

    func retrySaving() {
        guard !isRemoved else { return }
        if !isLoaded {
            startLoading()
        } else {
            persist()
        }
    }

    /// Includes changes made during the wait. A deadline lets quit offer
    /// Retry/Cancel/Quit Anyway without cancelling a partially committed write.
    func flush(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while loading != nil || writing != nil || removing != nil {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        if isRemoved { return saveError == nil }
        return isLoaded && saveError == nil && durableRevision == requestedRevision
    }

    func removeFile() async throws {
        if let removing { return try await removing.value }
        isRemoved = true
        acceptsChanges = false
        value = empty
        onAvailabilityChange?()
        let loading = self.loading, writing = self.writing, fileURL = self.fileURL
        let task = Task {
            _ = await loading?.value
            await writing?.value
            try await BackgroundFileIO.run { try ProfileDataCleanup.removeItem(at: fileURL) }
        }
        removing = task
        defer { removing = nil }
        do {
            try await task.value
            loadError = nil
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }
}
