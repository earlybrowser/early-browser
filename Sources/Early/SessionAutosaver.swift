// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Observation

/// One writer, with only the latest pending snapshot retained during a burst.
/// Encoding and SQLite I/O take place on SessionRepository's actor.
@MainActor @Observable
final class SessionAutosaver {
    private let repository: SessionRepository
    private let disabledReason: String?
    private var pending: BrowserWorkspace?
    private var writer: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var lastSavedAt: Date?
    var isAvailable: Bool { disabledReason == nil }

    init(repository: SessionRepository, disabledReason: String?) {
        self.repository = repository
        self.disabledReason = disabledReason
        error = disabledReason
    }

    func enqueue(_ snapshot: BrowserWorkspace) {
        guard disabledReason == nil else { return }
        pending = snapshot
        guard writer == nil else { return }
        isSaving = true
        writer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            while let snapshot = self.pending {
                self.pending = nil
                self.revision += 1
                do {
                    try await self.repository.saveWorkspace(snapshot, revision: self.revision)
                    self.error = nil
                    self.lastSavedAt = Date()
                } catch { self.error = error.localizedDescription }
            }
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
