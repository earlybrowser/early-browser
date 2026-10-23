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

/// Where a vault's encryption key is kept. The Keychain in the app; tests
/// keep it in memory.
public protocol PasswordVaultKey: Sendable {
    /// The saved key, or nil when none was saved yet.
    func existing() throws -> Data?
    func create(_ key: Data) throws
    func remove() throws
}

/// A generic password item in the login keychain, one per profile. Early is
/// not signed by a developer team, so macOS asks once ("Always Allow") after
/// each new build before Early may read it.
public struct KeychainVaultKey: PasswordVaultKey {
    public static let service = "Early Passwords"
    public let account: String

    public init(account: String) { self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func existing() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PasswordVault.KeyError(status: status) }
        return data
    }

    public func create(_ key: Data) throws {
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = Self.service
        item[kSecAttrDescription as String] = "Encryption key for Early’s saved passwords"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasswordVault.KeyError(status: status) }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PasswordVault.KeyError(status: status) }
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

    private struct Contents: Codable {
        var version = 1
        var logins: [SavedLogin] = []
        var neverSaved: [String] = []
    }

    public private(set) var logins: [SavedLogin] = []
    /// Websites the person asked Early never to offer saving for.
    public private(set) var neverSaved: [String] = []
    public private(set) var state: State
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored private let key: (any PasswordVaultKey)?
    @ObservationIgnored private var symmetricKey: SymmetricKey?
    @ObservationIgnored private var loading: Task<Bool, Never>?
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    static let magic = Data("EARLYPW1".utf8)

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
        if state == .ready { return true }
        if case .unavailable = state, !retry { return false }
        if let loading { return await loading.value }
        guard let fileURL, let key else { state = .ready; return true }
        state = .loading
        let task = Task { @MainActor [weak self] () -> Bool in
            let result = await Task.detached { () -> Result<(Data?, Data?), KeyError> in
                guard let data = try? Data(contentsOf: fileURL) else {
                    // No file: nothing saved yet, and no reason to ask the Keychain.
                    return FileManager.default.fileExists(atPath: fileURL.path) ? .failure(KeyError(status: errSecIO)) : .success((nil, nil))
                }
                do {
                    guard let saved = try key.existing() else { return .failure(KeyError(status: errSecItemNotFound)) }
                    return .success((saved, data))
                } catch let error as KeyError {
                    return .failure(error)
                } catch {
                    return .failure(KeyError(status: errSecInternalError))
                }
            }.value
            guard let self else { return false }
            self.loading = nil
            switch result {
            case .success((nil, _)):
                self.state = .ready
            case .success((let keyData?, let data)):
                let symmetric = SymmetricKey(data: keyData)
                guard let data, let contents = try? Self.decrypt(data, key: symmetric) else {
                    self.state = .unavailable("Your saved passwords couldn’t be read.", canReset: true)
                    return false
                }
                self.symmetricKey = symmetric
                self.logins = contents.logins
                self.neverSaved = contents.neverSaved
                self.state = .ready
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
        case errSecIO:
            .unavailable("Your saved passwords couldn’t be read from disk.", canReset: false)
        default:
            .unavailable("Early wasn’t allowed to open your saved passwords. Try again, and choose Always Allow when macOS asks.", canReset: false)
        }
    }

    /// Passwords that can never be opened move aside (kept, not deleted) and
    /// an empty vault starts in their place.
    public func resetUnreadable() {
        guard case .unavailable(_, true) = state else { return }
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(now().timeIntervalSince1970)
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).vault")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
        symmetricKey = nil
        logins = []
        neverSaved = []
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

    /// Imported rows never replace a saved password.
    @discardableResult
    public func importRows(_ rows: [PasswordCSV.Row], skipped: Int = 0) -> ImportSummary {
        var summary = ImportSummary(skipped: skipped)
        guard isReady else { return summary }
        let date = now()
        for row in rows {
            if let saved = logins.first(where: { $0.origin == row.origin && $0.username == row.username }) {
                if saved.password == row.password { summary.duplicates += 1 } else { summary.conflicts += 1 }
                continue
            }
            logins.append(SavedLogin(origin: row.origin, username: row.username, password: row.password,
                                     realm: row.realm, note: row.note, created: date))
            summary.added += 1
        }
        if summary.added > 0 { persist() }
        return summary
    }

    public func exportCSV() -> String { PasswordCSV.export(logins) }

    /// Deleting a profile: its file and key go.
    public func removeAll() {
        loading?.cancel()
        logins = []
        neverSaved = []
        symmetricKey = nil
        state = .ready
        Self.remove(fileURL: fileURL, key: key)
    }

    public nonisolated static func remove(fileURL: URL?, key: (any PasswordVaultKey)?) {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        guard let key else { return }
        Task.detached { try? key.remove() }
    }

    /// Waits for pending writes; tests and quitting use it.
    public func flush() async { await writing?.value }

    // MARK: Storage

    private func persist() {
        guard let fileURL, let key else { return }
        let contents = Contents(logins: logins, neverSaved: neverSaved)
        let previous = writing
        writing = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if self.symmetricKey == nil {
                // The first save: reuse a key left from before, or make one.
                let made = await Task.detached { () -> Data? in
                    if let saved = try? key.existing() { return saved }
                    let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    return (try? key.create(fresh)) == nil ? nil : fresh
                }.value
                guard let made else {
                    self.state = .unavailable("Early couldn’t save a key for your passwords in the Keychain, so new passwords aren’t kept after you quit.", canReset: false)
                    return
                }
                self.symmetricKey = SymmetricKey(data: made)
            }
            guard let symmetric = self.symmetricKey, let data = try? Self.encrypt(contents, key: symmetric) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func encrypt(_ contents: Contents, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sealed = try AES.GCM.seal(try encoder.encode(contents), using: key)
        guard let combined = sealed.combined else { throw KeyError(status: errSecInternalError) }
        return magic + combined
    }

    private static func decrypt(_ data: Data, key: SymmetricKey) throws -> Contents {
        guard data.starts(with: magic) else { throw KeyError(status: errSecDecode) }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Contents.self, from: try AES.GCM.open(box, using: key))
    }
}
