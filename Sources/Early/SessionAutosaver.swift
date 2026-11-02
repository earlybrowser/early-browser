// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Observation

/// One writer, with only the latest pending snapshot retained during a burst.
/// Encoding and SQLite I/O take place on SessionRepository's actor.
@MainActor @Observable
final class SessionAutosaver {
    @ObservationIgnored private let write: @Sendable (BrowserWorkspace, UInt64) async throws -> Void
    @ObservationIgnored private let delay: Duration
    private let disabledReason: String?
    private var pending: BrowserWorkspace?
    private var writer: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var lastSavedAt: Date?
    var isAvailable: Bool { disabledReason == nil }

    init(repository: SessionRepository, disabledReason: String?, delay: Duration = .milliseconds(150),
         write: (@Sendable (BrowserWorkspace, UInt64) async throws -> Void)? = nil) {
        self.write = write ?? { try await repository.saveWorkspace($0, revision: $1) }
        self.delay = delay
        self.disabledReason = disabledReason
        error = disabledReason
    }

    func enqueue(_ snapshot: BrowserWorkspace) {
        guard disabledReason == nil else { return }
        pending = snapshot
        guard writer == nil else { return }
        isSaving = true
        writer = Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            guard let self else { return }
            var latestError = self.error
            while let snapshot = self.pending {
                self.pending = nil
                self.revision += 1
                do {
                    try await self.write(snapshot, self.revision)
                    latestError = nil
                    self.lastSavedAt = Date()
                } catch {
                    latestError = error.localizedDescription
                    self.error = latestError
                }
            }
            // An older successful write must not hide the error while a newer
            // snapshot is still being saved or about to fail.
            self.error = latestError
            self.isSaving = false
            self.writer = nil
        }
    }

    func flush() async -> Bool {
        // A callback can enqueue a new writer while this await resumes. Drain
        // that writer too before quit/deletion treats the snapshot as durable.
        while let writer { await writer.value }
        return error == nil
    }
}
