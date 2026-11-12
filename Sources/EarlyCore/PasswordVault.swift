// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Observation
import Security

/// One saved sign-in for a website's origin (`scheme://host[:port]`). Logins
/// saved from an HTTP sign-in prompt also keep the realm it asked for.
public struct SavedLogin: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var origin: String
    public var username: String
    public var password: String
    public var realm: String?
    public var note: String
    public var created: Date
    public var modified: Date
    public var lastUsed: Date?

    public init(id: UUID = UUID(), origin: String, username: String, password: String, realm: String? = nil,
                note: String = "", created: Date = Date(), modified: Date? = nil, lastUsed: Date? = nil) {
        self.id = id
        self.origin = origin
        self.username = username
        self.password = password
        self.realm = realm
        self.note = note
        self.created = created
        self.modified = modified ?? created
        self.lastUsed = lastUsed
    }

    public var host: String { URL(string: origin)?.host ?? origin }
}

/// Where a vault's encryption key comes from. The Keychain in the app;
/// tests keep it in memory.
public protocol PasswordVaultKey: Sendable {
    /// The vault's key, or nil when none was made yet.
    func existing() throws -> Data?
    /// The vault's key, made now if there is none.
    func make() throws -> Data
    /// Forgets the vault's key, when its profile is deleted.
    func remove() throws
    /// A key an earlier build of Early kept, to move its passwords over.
    func legacy() throws -> Data?
    func removeLegacy() throws
}

extension PasswordVaultKey {
    public func legacy() throws -> Data? { nil }
    public func removeLegacy() throws {}
}

/// One generic password item in the login keychain for all of Early; each
/// profile's key is derived from it with HKDF and the profile's identifier,
/// so profiles are encrypted separately but macOS asks only once. Early is
/// not signed by a developer team, so macOS asks again ("Always Allow")
/// after each new build before Early may read it: without a team, the
/// Keychain admits only the exact build that last had access, whatever the
/// item's access list says (checked 2026-10-24, also with a self-signed
/// certificate).
public struct KeychainVaultKey: PasswordVaultKey {
    public static let service = "Early Passwords"
    static let sharedAccount = "vault"
    public let profile: UUID

    public init(profile: UUID) { self.profile = profile }

    /// A profile's own key from the shared one.
    public static func derive(_ shared: Data, profile: UUID) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: Data(service.utf8),
                               info: Data("profile \(profile.uuidString)".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    public func existing() throws -> Data? {
        try Self.read(Self.sharedAccount).map { Self.derive($0, profile: profile) }
    }

    public func make() throws -> Data {
        if let shared = try Self.read(Self.sharedAccount) { return Self.derive(shared, profile: profile) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var item = Self.query(Self.sharedAccount)
        item[kSecValueData as String] = fresh
        item[kSecAttrLabel as String] = Self.service
        item[kSecAttrDescription as String] = "Encryption key for Early’s saved passwords"
        let status = SecItemAdd(item as CFDictionary, nil)
        // Another profile made it at the same moment.
        if status == errSecDuplicateItem, let shared = try Self.read(Self.sharedAccount) { return Self.derive(shared, profile: profile) }
        guard status == errSecSuccess else { throw PasswordVault.KeyError(status: status) }
        return Self.derive(fresh, profile: profile)
    }

    /// The shared key stays for the other profiles; deleting the profile's
    /// file is what makes its passwords unrecoverable.
    public func remove() throws {}

    /// Earlier builds kept one item per profile, named by its identifier.
    public func legacy() throws -> Data? { try Self.read(profile.uuidString) }

    public func removeLegacy() throws {
        let status = SecItemDelete(Self.query(profile.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PasswordVault.KeyError(status: status) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PasswordVault.KeyError(status: status) }
        return data
    }
}

/// Development builds only: the shared key in a file beside their own
/// vaults, so rebuilding Early never asks for the Keychain. Releases use the
/// Keychain, and their vaults are never opened with this key.
public struct FileVaultKey: PasswordVaultKey {
    public let file: URL
    public let profile: UUID

    public init(file: URL, profile: UUID) {
        self.file = file
        self.profile = profile
    }

    public func existing() throws -> Data? {
        try read().map { KeychainVaultKey.derive($0, profile: profile) }
    }

    public func make() throws -> Data {
        if let shared = try read() { return KeychainVaultKey.derive(shared, profile: profile) }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fresh.write(to: file, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            // Another profile made it at the same moment.
            guard let shared = try read() else { throw PasswordVault.KeyError(status: errSecIO) }
            return KeychainVaultKey.derive(shared, profile: profile)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return KeychainVaultKey.derive(fresh, profile: profile)
    }

    /// The file is shared by every profile, like the Keychain item.
    public func remove() throws {}

    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count == 32 else { throw PasswordVault.KeyError(status: errSecDecode) }
        return data
    }
}

/// A profile's saved passwords: one AES-GCM encrypted file whose key is in
/// the Keychain, like Chrome's on macOS. Nothing is read until passwords are
/// first needed, and without a file the Keychain is not touched until the
/// first save. Nothing leaves this Mac.
@MainActor @Observable
public final class PasswordVault {
    public enum State: Equatable, Sendable {
        case notLoaded, loading, ready
        /// Saved passwords exist but could not be opened; nothing is written
        /// over them. `canReset` when they can never be opened again.
        case unavailable(String, canReset: Bool)
    }

    /// What adding a login did.
    public enum SaveResult: Equatable, Sendable { case added, updated, unchanged }

    public struct ImportSummary: Equatable, Sendable {
        public var added = 0
        /// Already saved with the same password.
        public var duplicates = 0
        /// Already saved with a different password; the saved one was kept.
        public var conflicts = 0
        /// Rows without a website address or password.
        public var skipped = 0
    }

    struct KeyError: Error, Equatable { let status: OSStatus }

    private struct Contents: Codable, Sendable {
        var version = 1
        var logins: [SavedLogin] = []
        var neverSaved: [String] = []
        var drafts: [SavedLogin] = []

        init(logins: [SavedLogin], neverSaved: [String], drafts: [SavedLogin]) {
            self.logins = logins
            self.neverSaved = neverSaved
            self.drafts = drafts
        }

        /// Files from before drafts existed have none.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            logins = try container.decodeIfPresent([SavedLogin].self, forKey: .logins) ?? []
            neverSaved = try container.decodeIfPresent([String].self, forKey: .neverSaved) ?? []
            drafts = try container.decodeIfPresent([SavedLogin].self, forKey: .drafts) ?? []
        }
    }

    public private(set) var logins: [SavedLogin] = []
    /// Websites the person asked Early never to offer saving for.
    public private(set) var neverSaved: [String] = []
    /// Strong passwords Early filled in that no website has accepted yet.
    /// Kept so they can't be lost, but never filled or used to replace a
    /// working password on their own.
    public private(set) var drafts: [SavedLogin] = []
    public private(set) var state: State
    /// Why the latest changes couldn't be written to disk; nil once a write
    /// succeeds. They stay in memory, so ``retrySaving()`` can still keep them.
    public private(set) var saveError: String?
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored private let key: (any PasswordVaultKey)?
    @ObservationIgnored private var symmetricKey: SymmetricKey?
    @ObservationIgnored private var loading: Task<Bool, Never>?
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var removing: Task<Void, Error>?
    @ObservationIgnored private var requestedRevision: UInt64 = 0
    @ObservationIgnored private var durableRevision: UInt64 = 0
    @ObservationIgnored private var mutationRevision: UInt64 = 0
    /// The encrypted-file boundary also lets tests suspend or fail real writes.
    @ObservationIgnored var writeFile: @Sendable (Data, URL) throws -> Void = PasswordVault.writeEncryptedFile
    /// Recovery must preserve the old file before an empty vault can be used.
    @ObservationIgnored var moveRecoveryFile: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)
    /// Opened with an earlier build's key: re-encrypted with the current one,
    /// then the old key goes.
    @ObservationIgnored private var movesFromLegacyKey = false
    /// Bumped when the passwords are deleted or reset: work started before
    /// then neither writes nor restores anything.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRemoved = false
    @ObservationIgnored private let now: () -> Date
    static let draftLimit = 50
    /// A recent strong password for a site is offered again, not a new one.
    static let draftReuse: TimeInterval = 86_400

    nonisolated static let magic = Data("EARLYPW1".utf8)

    /// Without a file or key, passwords stay in memory (private testing).
    public init(fileURL: URL?, key: (any PasswordVaultKey)?, now: @escaping () -> Date = { Date() }) {
        self.fileURL = key == nil ? nil : fileURL
        self.key = fileURL == nil ? nil : key
        self.now = now
        state = self.fileURL == nil ? .ready : .notLoaded
    }

    public var isReady: Bool { state == .ready }

    /// Opens the saved passwords if needed. One that could not be opened is
    /// tried again only when asked, so the Keychain doesn't keep asking.
    @discardableResult
    public func load(retry: Bool = false) async -> Bool {
        guard !isRemoved else { return false }
        if state == .ready { return true }
        if case .unavailable = state, !retry { return false }
        if let loading { return await loading.value }
        guard let fileURL, let key else { state = .ready; return true }
        state = .loading
        let started = generation
        let task = Task { @MainActor [weak self] () -> Bool in
            let result = await Task.detached { () -> Result<(contents: Contents?, key: Data?), KeyError> in
                guard let data = try? Data(contentsOf: fileURL) else {
                    // No file: nothing saved yet, and no reason to ask the Keychain.
                    return FileManager.default.fileExists(atPath: fileURL.path) ? .failure(KeyError(status: errSecIO)) : .success((nil, nil))
                }
                do {
                    let current = try key.existing()
                    if let current, let contents = try? Self.decrypt(data, key: SymmetricKey(data: current)) {
                        return .success((contents, current))
                    }
                    if let old = try key.legacy(), let contents = try? Self.decrypt(data, key: SymmetricKey(data: old)) {
                        return .success((contents, nil))
                    }
                    return .failure(KeyError(status: current == nil ? errSecItemNotFound : errSecDecode))
                } catch let error as KeyError {
                    return .failure(error)
                } catch {
                    return .failure(KeyError(status: errSecInternalError))
                }
            }.value
            // Deleted or reset while reading: nothing comes back.
            guard let self, self.generation == started else { return false }
            self.loading = nil
            switch result {
            case .success((nil, _)):
                self.state = .ready
            case .success((let contents?, let current)):
                self.logins = contents.logins
                self.neverSaved = contents.neverSaved
                self.drafts = contents.drafts
                self.state = .ready
                if let current {
                    self.symmetricKey = SymmetricKey(data: current)
                } else {
                    self.movesFromLegacyKey = true
                    self.persist()
                }
            case .failure(let error):
                self.state = Self.unavailable(error)
                return false
            }
            return true
        }
        loading = task
        return await task.value
    }

    static func unavailable(_ error: KeyError) -> State {
        switch error.status {
        case errSecItemNotFound:
            .unavailable("The key for your saved passwords is missing from the Keychain, so they can’t be opened.", canReset: true)
        case errSecDecode:
            .unavailable("Your saved passwords couldn’t be read.", canReset: true)
        case errSecIO:
            .unavailable("Your saved passwords couldn’t be read from disk.", canReset: false)
        default:
            .unavailable("Early wasn’t allowed to open your saved passwords. Try again, and choose Always Allow when macOS asks.", canReset: false)
        }
    }

    /// Passwords that can never be opened move aside (kept, not deleted).
    /// Only after preservation succeeds can an empty vault take their place.
    public func resetUnreadable() {
        guard case .unavailable(_, true) = state else { return }
        if let fileURL {
            let stamp = Int(now().timeIntervalSince1970)
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp)-\(UUID().uuidString).vault")
            do {
                try moveRecoveryFile(fileURL, aside)
            } catch {
                state = .unavailable("Your saved passwords couldn’t be preserved, so they weren’t reset. \(error.localizedDescription)", canReset: true)
                return
            }
        }
        generation += 1
        requestedRevision = 0
        durableRevision = 0
        symmetricKey = nil
        logins = []
        neverSaved = []
        drafts = []
        saveError = nil
        state = .ready
    }

    // MARK: Reading

    /// Logins for a page's origin, most recently used first. An `https` page
    /// also gets the same host's `http` logins; never the other way round.
    public func logins(for origin: String) -> [SavedLogin] {
        let accepted = Self.matchingOrigins(for: origin)
        return logins.filter { accepted.contains($0.origin) }.sorted { lhs, rhs in
            if (lhs.lastUsed ?? .distantPast) != (rhs.lastUsed ?? .distantPast) {
                return (lhs.lastUsed ?? .distantPast) > (rhs.lastUsed ?? .distantPast)
            }
            return lhs.username.localizedStandardCompare(rhs.username) == .orderedAscending
        }
    }

    nonisolated static func matchingOrigins(for origin: String) -> Set<String> {
        guard origin.hasPrefix("https://") else { return [origin] }
        let rest = origin.dropFirst("https://".count)
        // An explicit https port has no http counterpart.
        return rest.contains(":") ? [origin] : [origin, "http://" + rest]
    }

    public func login(id: UUID) -> SavedLogin? { logins.first { $0.id == id } }

    public func login(origin: String, username: String) -> SavedLogin? {
        logins.first { $0.origin == origin && $0.username == username }
    }

    public func isNeverSaved(_ origin: String) -> Bool { neverSaved.contains(origin) }

    /// The strong password Early filled in for this site, by its password.
    public func draft(origin: String, password: String) -> SavedLogin? {
        drafts.first { $0.origin == origin && $0.password == password }
    }

    /// A strong password from the last day for this site, to offer again
    /// rather than a new one each time a form is retried.
    public func recentDraft(origin: String) -> SavedLogin? {
        drafts.filter { $0.origin == origin && now().timeIntervalSince($0.created) < Self.draftReuse }
            .max { $0.created < $1.created }
    }

    // MARK: Changing

    /// Adds a login, or changes the password of the same origin and username.
    @discardableResult
    public func save(origin: String, username: String, password: String, realm: String? = nil) -> SaveResult? {
        guard isReady, !password.isEmpty else { return nil }
        let date = now()
        if let index = logins.firstIndex(where: { $0.origin == origin && $0.username == username }) {
            guard logins[index].password != password || (realm != nil && logins[index].realm != realm) else { return .unchanged }
            logins[index].password = password
            if let realm { logins[index].realm = realm }
            logins[index].modified = date
            persist()
            return .updated
        }
        logins.append(SavedLogin(origin: origin, username: username, password: password, realm: realm, created: date))
        neverSaved.removeAll { $0 == origin }
        persist()
        return .added
    }

    /// An edited login. Refused when another login already has its origin
    /// and username.
    @discardableResult
    public func update(_ login: SavedLogin) -> Bool {
        guard isReady, !login.password.isEmpty, let index = logins.firstIndex(where: { $0.id == login.id }),
              !logins.contains(where: { $0.id != login.id && $0.origin == login.origin && $0.username == login.username })
        else { return false }
        guard logins[index] != login else { return true }
        var changed = login
        changed.modified = now()
        logins[index] = changed
        persist()
        return true
    }

    public func delete(_ ids: Set<UUID>) {
        guard isReady, logins.contains(where: { ids.contains($0.id) }) else { return }
        logins.removeAll { ids.contains($0.id) }
        persist()
    }

    /// A login was filled into a page.
    public func markUsed(_ id: UUID) {
        guard isReady, let index = logins.firstIndex(where: { $0.id == id }) else { return }
        logins[index].lastUsed = now()
        persist()
    }

    public func neverSave(_ origin: String) {
        guard isReady, !neverSaved.contains(origin) else { return }
        neverSaved.append(origin)
        neverSaved.sort()
        persist()
    }

    public func allowSaving(_ origin: String) {
        guard isReady, neverSaved.contains(origin) else { return }
        neverSaved.removeAll { $0 == origin }
        persist()
    }

    // MARK: Strong-password drafts

    /// Keeps a strong password Early filled in, apart from the saved logins,
    /// until the website accepts it.
    public func saveDraft(origin: String, username: String, password: String) {
        guard isReady, !password.isEmpty else { return }
        if let index = drafts.firstIndex(where: { $0.origin == origin && $0.password == password }) {
            guard !username.isEmpty, drafts[index].username != username else { return }
            drafts[index].username = username
            drafts[index].modified = now()
        } else {
            drafts.append(SavedLogin(origin: origin, username: username, password: password, created: now()))
            if drafts.count > Self.draftLimit { drafts.removeFirst(drafts.count - Self.draftLimit) }
        }
        persist()
    }

    /// A draft becomes a saved login, unless a login with its user name
    /// exists: replacing that one needs the person's say (``replace(_:with:)``).
    @discardableResult
    public func commitDraft(_ id: UUID, username: String? = nil) -> SaveResult? {
        guard isReady, let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        let draft = drafts[index]
        let name = username.flatMap { $0.isEmpty ? nil : $0 } ?? draft.username
        if let existing = login(origin: draft.origin, username: name) {
            guard existing.password == draft.password else { return nil }
            drafts.remove(at: index)
            persist()
            return .unchanged
        }
        drafts.remove(at: index)
        logins.append(SavedLogin(origin: draft.origin, username: name, password: draft.password, created: now()))
        neverSaved.removeAll { $0 == draft.origin }
        persist()
        return .added
    }

    /// The person chose to replace a saved login's password with a draft.
    @discardableResult
    public func replace(_ loginID: UUID, with draftID: UUID) -> Bool {
        guard isReady, let draft = drafts.first(where: { $0.id == draftID }),
              let index = logins.firstIndex(where: { $0.id == loginID }) else { return false }
        logins[index].password = draft.password
        logins[index].modified = now()
        drafts.removeAll { $0.id == draftID }
        persist()
        return true
    }

    public func deleteDraft(_ id: UUID) {
        guard isReady, drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        persist()
    }

    /// A website accepted the password: its draft is no longer needed.
    public func removeDrafts(origin: String, password: String) {
        guard isReady, drafts.contains(where: { $0.origin == origin && $0.password == password }) else { return }
        drafts.removeAll { $0.origin == origin && $0.password == password }
        persist()
    }

    /// Imported rows never replace a saved password.
    @discardableResult
    public func importRows(_ rows: [PasswordCSV.Row], skipped: Int = 0) -> ImportSummary {
        var summary = ImportSummary(skipped: skipped)
        guard isReady else { return summary }
        let merged = Self.merge(rows, into: logins, skipped: skipped, date: now(), checking: {})
        summary = merged.summary
        if summary.added > 0 { logins = merged.logins; persist() }
        return summary
    }

    public enum ImportFailure: Error, Equatable { case unavailable, saving }

    /// File reading, parsing and bulk preparation run off the main actor. Edits
    /// arriving during that work are merged again against the latest logins.
    public func importCSV(from url: URL, onSaving: () -> Void = {}) async throws -> ImportSummary {
        try await importCSV(read: { try PasswordCSV.read(url) }, onSaving: onSaving)
    }

    func importCSV(read: @escaping @Sendable () throws -> PasswordCSV.Parsed,
                   onSaving: () -> Void = {}) async throws -> ImportSummary {
        guard isReady, !isRemoved else { throw ImportFailure.unavailable }
        let started = generation
        let parsed = try await Self.importWork(read)
        while true {
            try Task.checkCancellation()
            guard isReady, !isRemoved, generation == started else { throw ImportFailure.unavailable }
            let revision = mutationRevision, existing = logins, date = now()
            let merged = try await Self.importWork {
                try Self.merge(parsed.rows, into: existing, skipped: parsed.skipped, date: date,
                               checking: { try Task.checkCancellation() })
            }
            try Task.checkCancellation()
            guard isReady, !isRemoved, generation == started else { throw ImportFailure.unavailable }
            guard revision == mutationRevision else { continue }
            // This is the commit boundary. Cancellation before it changes
            // nothing; afterward finish the save and report its real outcome.
            onSaving()
            if merged.summary.added > 0 { logins = merged.logins; persist() }
            let saved = await flush()
            guard isReady, !isRemoved, generation == started else { throw ImportFailure.unavailable }
            guard saved else { throw ImportFailure.saving }
            return merged.summary
        }
    }

    private nonisolated static func importWork<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private struct ImportIdentity: Hashable { var origin: String; var username: String }
    private struct ImportMerge: Sendable { var logins: [SavedLogin]; var summary: ImportSummary }

    private nonisolated static func merge(_ rows: [PasswordCSV.Row], into existing: [SavedLogin],
        skipped: Int, date: Date, checking check: () throws -> Void) rethrows -> ImportMerge {
        var passwords: [ImportIdentity: String] = [:]
        for (index, login) in existing.enumerated() {
            if index % 256 == 0 { try check() }
            let id = ImportIdentity(origin: login.origin, username: login.username)
            if passwords[id] == nil { passwords[id] = login.password }
        }
        var logins = existing, summary = ImportSummary(skipped: skipped)
        for (index, row) in rows.enumerated() {
            if index % 256 == 0 { try check() }
            let id = ImportIdentity(origin: row.origin, username: row.username)
            if let saved = passwords[id] {
                if saved == row.password { summary.duplicates += 1 } else { summary.conflicts += 1 }
            } else {
                passwords[id] = row.password
                logins.append(SavedLogin(origin: row.origin, username: row.username, password: row.password,
                                        realm: row.realm, note: row.note, created: date))
                summary.added += 1
            }
        }
        try check()
        return ImportMerge(logins: logins, summary: summary)
    }

    public func exportCSV() -> String { PasswordCSV.export(logins) }

    /// Deleting a profile: its file and key go, and no open or save still
    /// under way can write or restore anything afterwards.
    public func removeAll() async throws {
        if let removing { return try await removing.value }
        generation += 1
        isRemoved = true
        let previousLoad = loading, previousWrite = writing
        loading = nil
        writing = nil
        requestedRevision = 0
        durableRevision = 0
        logins = []
        neverSaved = []
        drafts = []
        symmetricKey = nil
        saveError = nil
        state = .unavailable("This profile’s passwords were deleted.", canReset: false)
        let fileURL = fileURL, key = key
        let task = Task { @MainActor in
            // A pending key creation or file write must finish before removal,
            // even though its generation can no longer publish saved state.
            _ = await previousLoad?.value
            await previousWrite?.value
            try await Self.remove(fileURL: fileURL, key: key)
        }
        removing = task
        defer { removing = nil; writing = nil }
        do { try await task.value }
        catch {
            saveError = "This profile’s passwords could not yet be erased. \(error.localizedDescription)"
            throw error
        }
    }

    public nonisolated static func remove(fileURL: URL?, key: (any PasswordVaultKey)?) async throws {
        try await Task.detached(priority: .utility) {
            try ProfileDataCleanup.removeItem(at: fileURL)
            // Retry keys even when an earlier attempt already removed the file.
            // Shared key implementations deliberately keep other profiles' keys.
            try key?.remove()
            try key?.removeLegacy()
        }.value
    }

    /// Includes edits arriving during the wait, not just the write that happened
    /// to be active when flush began. A failure keeps the latest changes in memory.
    @discardableResult
    public func flush() async -> Bool {
        while true {
            if let removing {
                do { try await removing.value; return true }
                catch { return false }
            }
            guard let writing else { break }
            await writing.value
        }
        return saveError == nil && durableRevision == requestedRevision
    }

    /// Writes the passwords again after a failed save.
    public func retrySaving() {
        guard isReady else { return }
        persist()
    }

    // MARK: Storage

    private func persist() {
        mutationRevision += 1
        guard let fileURL, let key, !isRemoved else { return }
        requestedRevision += 1
        // The live arrays are the newest pending snapshot. Only the active
        // write retains a separate copy; bursts never queue whole vaults.
        guard writing == nil else { return }
        let started = generation
        writing = Task { @MainActor [weak self] in
            guard let self, self.generation == started else { return }
            defer { if self.generation == started { self.writing = nil } }
            if self.symmetricKey == nil {
                // The first save, or passwords moving from an earlier build's key.
                let made = await Task.detached { try? key.make() }.value
                guard self.generation == started else { return }
                guard let made else {
                    self.saveError = "Early couldn’t save a key for your passwords in the Keychain."
                    return
                }
                self.symmetricKey = SymmetricKey(data: made)
            }
            guard let symmetric = self.symmetricKey else {
                self.saveError = "Your passwords couldn’t be encrypted."
                return
            }
            while self.durableRevision < self.requestedRevision {
                let revision = self.requestedRevision
                let contents = Contents(logins: self.logins, neverSaved: self.neverSaved, drafts: self.drafts)
                let writeFile = self.writeFile
                // Encryption and disk I/O stay off the main actor. After this
                // write, take only the newest revision that arrived meanwhile.
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    guard let data = try? Self.encrypt(contents, key: symmetric) else { return "Your passwords couldn’t be encrypted." }
                    do {
                        try writeFile(data, fileURL)
                        return nil
                    } catch {
                        return "Your passwords couldn’t be written to disk. \(error.localizedDescription)"
                    }
                }.value
                // Removal drains this in-flight write before erasing the file.
                guard self.generation == started else { return }
                if let failure {
                    self.saveError = failure
                    return
                }
                self.durableRevision = revision
                // An older success must not clear an error while newer changes
                // are still pending. Retry reports success only once up to date.
                if self.durableRevision == self.requestedRevision { self.saveError = nil }
                if self.movesFromLegacyKey {
                    self.movesFromLegacyKey = false
                    Task.detached { try? key.removeLegacy() }
                }
            }
        }
    }

    private nonisolated static func writeEncryptedFile(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func encrypt(_ contents: Contents, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sealed = try AES.GCM.seal(try encoder.encode(contents), using: key)
        guard let combined = sealed.combined else { throw KeyError(status: errSecInternalError) }
        return magic + combined
    }

    private nonisolated static func decrypt(_ data: Data, key: SymmetricKey) throws -> Contents {
        guard data.starts(with: magic) else { throw KeyError(status: errSecDecode) }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Contents.self, from: try AES.GCM.open(box, using: key))
    }
}
