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

        func apply(to store: HistoryStore, epoch: UUID) async throws {
            switch self {
            case let .visit(url, title, date): try await store.record(url, title: title, at: date, acceptedIn: epoch)
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

    @MainActor private final class TitleBatch {
        private struct Visit: Hashable {
            let url: URL
            let date: Date
        }

        let timer = Task { try await Task.sleep(for: .milliseconds(100)) }
        private var titles: [Visit: (title: String, order: Int)] = [:]
        private var order = 0

        func append(_ url: URL, title: String, date: Date) {
            titles[Visit(url: url, date: date)] = (title, order)
            order += 1
        }

        var writes: [Write] {
            // Different visits can share a URL. Apply the last updates in
            // arrival order so the page title still follows the latest update.
            titles.sorted { $0.value.order < $1.value.order }.map { visit, entry in
                .title(visit.url, entry.title, visit.date)
            }
        }
    }

    private var tail: Task<Void, Never>?
    private var titleBatch: TitleBatch?
    private var generation: UInt64 = 0
    private var acceptanceEpoch = UUID()
    private var failed: [(write: Write, epoch: UUID)] = []
    public private(set) var failure: String?
    /// Quit seals acceptance before draining; Cancel reopens it. Private
    /// windows never have a queue, and deleted profiles are sealed permanently.
    public var acceptsWrites = true

    nonisolated init() {}

    fileprivate func append(_ write: Write, to store: HistoryStore) {
        guard acceptsWrites else { return }
        let epoch = acceptanceEpoch
        enqueue { await self.apply(write, to: store, epoch: epoch) }
    }

    fileprivate func appendTitle(_ url: URL, title: String, visitedAt date: Date, to store: HistoryStore) -> Bool {
        guard acceptsWrites, HistoryStore.records(url), HistoryStore.hasTitle(title) else { return false }
        if let titleBatch {
            titleBatch.append(url, title: title, date: date)
        } else {
            let batch = TitleBatch()
            let epoch = acceptanceEpoch
            batch.append(url, title: title, date: date)
            enqueue {
                _ = await batch.timer.result
                if self.titleBatch === batch { self.titleBatch = nil }
                for write in batch.writes { await self.apply(write, to: store, epoch: epoch) }
            }
            titleBatch = batch
        }
        return true
    }

    private func apply(_ write: Write, to store: HistoryStore, epoch: UUID) async {
        // Preserve order after a failure, including titles arriving later.
        guard failed.isEmpty else { failed.append((write, epoch)); return }
        do { try await write.apply(to: store, epoch: epoch) }
        catch { failed.append((write, epoch)); failure = error.localizedDescription }
    }

    private func sealTitles() {
        titleBatch?.timer.cancel()
        titleBatch = nil
    }

    public func wait() async {
        sealTitles()
        await tail?.value
    }

    /// A bounded quit wait. Cancelling/timing out the wait does not cancel or
    /// duplicate the SQLite operation; Try Again can finish the same work.
    public func drain(timeout: Duration = .seconds(10)) async -> String? {
        sealTitles()
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
            for entry in writes { await self.apply(entry.write, to: store, epoch: entry.epoch) }
        }
    }

    func delete(_ deletion: HistoryDeletion, request: UUID, from store: HistoryStore) -> Task<Result<Void, Error>, Never> {
        acceptanceEpoch = request
        let previous = tail
        let task = Task { () -> Result<Void, Error> in
            await previous?.value
            do {
                try await store.applyDeletion(deletion, request: request)
                // Writes that failed before this barrier must not return on a
                // later quit retry after the user successfully cleared them.
                self.failed.removeAll { $0.epoch != request && $0.write.isRemoved(by: deletion) }
                if self.failed.isEmpty { self.failure = nil }
                return .success(())
            } catch { return .failure(error) }
        }
        enqueue { _ = await task.value }
        return task
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        // A visit, deletion or retry starts a new batch. Close the old one
        // before accepting any later titles and wake it without delaying the barrier.
        sealTitles()
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

    @MainActor @discardableResult public func queueTitle(_ url: URL, title: String, visitedAt date: Date) -> Bool {
        pendingWrites.appendTitle(url, title: title, visitedAt: date, to: self)
    }

    @MainActor public func queueDeletion(_ deletion: HistoryDeletion, request: UUID = UUID()) -> Task<Result<Void, Error>, Never> {
        pendingWrites.delete(deletion, request: request, from: self)
    }

    @MainActor public func retryPendingWrites() { pendingWrites.retry(in: self) }
}
