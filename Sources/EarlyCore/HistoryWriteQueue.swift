// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum HistoryDeletion: Sendable {
    case visits([Int64]), pages([URL]), since(Date?)
}

/// All windows accepting visits for one store share this queue. Acceptance and
/// barriers happen synchronously on the main actor; SQLite stays on its actor.
/// The store owns the queue, so closing a window cannot orphan accepted writes.
@MainActor public final class HistoryWriteQueue {
    enum Write {
        case visit(URL, String?, Date), title(URL, String, Date)

        func apply(to store: HistoryStore) async throws {
            switch self {
            case let .visit(url, title, date): try await store.record(url, title: title, at: date)
            case let .title(url, title, _): try await store.updateTitle(url, title: title)
            }
        }

        func isRemoved(by deletion: HistoryDeletion) -> Bool {
            switch (deletion, self) {
            case (.since(let since), .visit(_, _, let date)): since == nil || date >= since!
            case (.since(let since), .title(_, _, let date)): since == nil || date >= since!
            case (.pages(let urls), .visit(let url, _, _)), (.pages(let urls), .title(let url, _, _)): urls.contains(url)
            case (.visits, _): false // These identify only visits already committed to SQLite.
            }
        }
    }

    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failed: [Write] = []
    public private(set) var failure: String?
    /// Quit seals acceptance before draining; Cancel reopens it. Private
    /// windows never have a queue, and deleted profiles are sealed permanently.
    public var acceptsWrites = true

    nonisolated init() {}

    func append(_ write: Write, to store: HistoryStore) {
        guard acceptsWrites else { return }
        enqueue {
            // Preserve order after a failure, including titles arriving later.
            guard self.failed.isEmpty else { self.failed.append(write); return }
            do { try await write.apply(to: store) }
            catch { self.failed.append(write); self.failure = error.localizedDescription }
        }
    }

    public func wait() async { await tail?.value }

    /// A bounded quit wait. Cancelling/timing out the wait does not cancel or
    /// duplicate the SQLite operation; Try Again can finish the same work.
    public func drain(timeout: Duration = .seconds(10)) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while tail != nil {
            if ContinuousClock.now >= deadline { return "Saving browsing history is taking longer than expected." }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return "Saving browsing history was interrupted." }
        }
        return failure
    }

    func retry(in store: HistoryStore) {
        enqueue {
            let writes = self.failed
            self.failed = []
            self.failure = nil
            for write in writes {
                guard self.failed.isEmpty else { self.failed.append(write); continue }
                do { try await write.apply(to: store) }
                catch { self.failed.append(write); self.failure = error.localizedDescription }
            }
        }
    }

    func delete(_ deletion: HistoryDeletion, from store: HistoryStore) -> Task<Result<Void, Error>, Never> {
        let previous = tail
        let task = Task { () -> Result<Void, Error> in
            await previous?.value
            do {
                switch deletion {
                case .visits(let ids): try await store.deleteVisits(ids)
                case .pages(let urls): try await store.deletePages(urls)
                case .since(let date): try await store.deleteVisits(since: date)
                }
                // Writes that failed before this barrier must not return on a
                // later quit retry after the user successfully cleared them.
                self.failed.removeAll { $0.isRemoved(by: deletion) }
                if self.failed.isEmpty { self.failure = nil }
                return .success(())
            } catch { return .failure(error) }
        }
        enqueue { _ = await task.value }
        return task
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        generation &+= 1
        let current = generation
        tail = Task {
            await previous?.value
            await operation()
            if current == self.generation { self.tail = nil }
        }
    }
}

extension HistoryStore {
    @MainActor public func queueVisit(_ url: URL, title: String?, at date: Date) {
        pendingWrites.append(.visit(url, title, date), to: self)
    }

    @MainActor public func queueTitle(_ url: URL, title: String, visitedAt date: Date) {
        pendingWrites.append(.title(url, title, date), to: self)
    }

    @MainActor public func queueDeletion(_ deletion: HistoryDeletion) -> Task<Result<Void, Error>, Never> {
        pendingWrites.delete(deletion, from: self)
    }

    @MainActor public func retryPendingWrites() { pendingWrites.retry(in: self) }
}
