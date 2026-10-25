// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Security
import Testing
@testable import EarlyCore

/// A vault key kept in memory, counting how often it is read; the Keychain
/// is never used by tests.
final class MemoryVaultKey: PasswordVaultKey, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var reads = 0
    /// Reading fails with this status, like a denied Keychain prompt.
    var failure: OSStatus? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    private var _failure: OSStatus?
    private var old: Data?
    /// Making a key fails, like a refused Keychain.
    var makeFails: Bool {
        get { lock.withLock { _makeFails } }
        set { lock.withLock { _makeFails = newValue } }
    }
    private var _makeFails = false
    /// The Keychain takes this long, so work can still be under way.
    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }
    private var _delay: TimeInterval = 0

    /// `legacy` is a key an earlier build kept.
    init(_ key: Data? = nil, legacy: Data? = nil) {
        stored = key
        old = legacy
    }

    var readCount: Int { lock.withLock { reads } }
    var key: Data? { lock.withLock { stored } }
    var legacyKey: Data? { lock.withLock { old } }

    func existing() throws -> Data? {
        Thread.sleep(forTimeInterval: delay)
        return try lock.withLock {
            reads += 1
            if let _failure { throw PasswordVault.KeyError(status: _failure) }
            return stored
        }
    }

    func make() throws -> Data {
        Thread.sleep(forTimeInterval: delay)
        return try lock.withLock {
            if _makeFails { throw PasswordVault.KeyError(status: errSecAuthFailed) }
            if let stored { return stored }
            let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            stored = fresh
            return fresh
        }
    }

    func remove() throws { lock.withLock { stored = nil } }
    func legacy() throws -> Data? { lock.withLock { old } }
    func removeLegacy() throws { lock.withLock { old = nil } }
}

@Suite @MainActor
struct PasswordVaultTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "EarlyPasswords-\(UUID())/profile.vault")
    }

    @Test func loginsAreSavedPerOriginAndHTTPSPagesAlsoGetTheirHTTPLogins() async {
        let vault = PasswordVault(fileURL: nil, key: nil)
        #expect(vault.isReady, "Without a file the vault is in memory and ready")
        #expect(vault.save(origin: "https://example.com", username: "ada", password: "one") == .added)
        #expect(vault.save(origin: "https://example.com", username: "ada", password: "one") == .unchanged)
        #expect(vault.save(origin: "https://example.com", username: "ada", password: "two") == .updated)
        #expect(vault.save(origin: "http://example.com", username: "old", password: "plain") == .added)
        #expect(vault.save(origin: "https://example.com:8443", username: "port", password: "p") == .added)
        #expect(vault.save(origin: "https://other.com", username: "x", password: "") == nil, "Empty passwords aren't saved")
        #expect(vault.logins.count == 3)
        #expect(Set(vault.logins(for: "https://example.com").map(\.username)) == ["ada", "old"])
        #expect(vault.logins(for: "http://example.com").map(\.username) == ["old"], "Never an https login on an http page")
        #expect(vault.logins(for: "https://example.com:8443").map(\.username) == ["port"])
        #expect(vault.logins(for: "https://sub.example.com").isEmpty, "Only the exact host")

        // Most recently used first.
        let old = vault.login(origin: "http://example.com", username: "old")!
        vault.markUsed(old.id)
        #expect(vault.logins(for: "https://example.com").first?.username == "old")

        var edited = vault.login(origin: "https://example.com", username: "ada")!
        edited.username = "old"
        edited.origin = "http://example.com"
        #expect(!vault.update(edited), "Two logins can't share an origin and username")
        edited.username = "ada.lovelace"
        edited.note = "Work"
        #expect(vault.update(edited))
        #expect(vault.login(id: edited.id)?.note == "Work")
        vault.delete([edited.id, old.id])
        #expect(vault.logins.map(\.username) == ["port"])

        vault.neverSave("https://never.example")
        #expect(vault.isNeverSaved("https://never.example"))
        #expect(vault.save(origin: "https://never.example", username: "a", password: "b") == .added)
        #expect(!vault.isNeverSaved("https://never.example"), "Saving by choice lifts Never")
    }

    @Test func passwordsAreEncryptedOnDiskAndReopenWithTheirKey() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = MemoryVaultKey()
        let vault = PasswordVault(fileURL: url, key: key)
        #expect(vault.state == .notLoaded)
        #expect(await vault.load())
        #expect(key.readCount == 0 && key.key == nil, "Nothing saved yet: the Keychain isn't touched")
        vault.save(origin: "https://example.com", username: "ada@example.com", password: "correct horse battery")
        vault.neverSave("https://never.example")
        await vault.flush()
        #expect(key.key?.count == 32, "A 256-bit key is made on the first save")
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("EARLYPW1".utf8)))
        #expect(data.range(of: Data("correct horse battery".utf8)) == nil && data.range(of: Data("ada@example.com".utf8)) == nil)

        let reopened = PasswordVault(fileURL: url, key: key)
        #expect(reopened.logins.isEmpty, "Nothing is read until needed")
        #expect(await reopened.load())
        #expect(reopened.logins.map(\.password) == ["correct horse battery"])
        #expect(reopened.neverSaved == ["https://never.example"])
    }

    @Test func passwordsThatCantBeOpenedAreNeverOverwritten() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = MemoryVaultKey()
        let vault = PasswordVault(fileURL: url, key: key)
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "ada", password: "secret")
        await vault.flush()
        let saved = try Data(contentsOf: url)

        // A denied Keychain prompt: nothing is written, and it isn't asked again by itself.
        key.failure = errSecAuthFailed
        let denied = PasswordVault(fileURL: url, key: key)
        #expect(await denied.load() == false)
        guard case .unavailable(_, let canReset) = denied.state else { Issue.record("\(denied.state)"); return }
        #expect(!canReset)
        #expect(denied.save(origin: "https://example.com", username: "eve", password: "x") == nil)
        let reads = key.readCount
        #expect(await denied.load() == false && key.readCount == reads)
        key.failure = nil
        #expect(await denied.load(retry: true))
        #expect(denied.logins.map(\.username) == ["ada"])
        #expect(try Data(contentsOf: url) == saved)

        // Another key can't open them; they move aside when reset.
        let wrong = PasswordVault(fileURL: url, key: MemoryVaultKey(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }))
        #expect(await wrong.load() == false)
        #expect(wrong.state == .unavailable("Your saved passwords couldn’t be read.", canReset: true))
        let missing = PasswordVault(fileURL: url, key: MemoryVaultKey())
        #expect(await missing.load() == false)
        guard case .unavailable(_, true) = missing.state else { Issue.record("\(missing.state)"); return }
        missing.resetUnreadable()
        #expect(missing.isReady && missing.logins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(kept.count == 1 && kept[0].hasPrefix("profile.unreadable-"), "\(kept)")

        // Deleting a profile removes the file and its key.
        let fresh = PasswordVault(fileURL: url, key: key)
        #expect(await fresh.load())
        fresh.save(origin: "https://a.example", username: "a", password: "b")
        await fresh.flush()
        fresh.removeAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The key goes in the background.
        for _ in 0..<200 where key.key != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(key.key == nil)
    }

    @Test func passwordsFromAnEarlierBuildsKeyMoveToTheSharedOne() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // An earlier build: one Keychain item per profile.
        let earlier = MemoryVaultKey()
        let saved = PasswordVault(fileURL: url, key: earlier)
        #expect(await saved.load())
        saved.save(origin: "https://example.com", username: "ada", password: "kept")
        await saved.flush()
        let old = try #require(earlier.key)

        let key = MemoryVaultKey(legacy: old)
        let vault = PasswordVault(fileURL: url, key: key)
        #expect(await vault.load())
        #expect(vault.logins.map(\.password) == ["kept"])
        await vault.flush()
        let current = try #require(key.key)
        // The old key goes in the background once the file is re-encrypted.
        for _ in 0..<200 where key.legacyKey != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(current != old && key.legacyKey == nil, "Re-encrypted with the current key; the old one is gone")
        let reopened = PasswordVault(fileURL: url, key: MemoryVaultKey(current))
        #expect(await reopened.load() && reopened.logins.map(\.username) == ["ada"])
    }

    @Test func eachProfilesKeyIsDerivedFromTheOneInTheKeychain() {
        let shared = Data((0..<32).map { UInt8($0) })
        let one = UUID(), two = UUID()
        let first = KeychainVaultKey.derive(shared, profile: one)
        #expect(first.count == 32 && first == KeychainVaultKey.derive(shared, profile: one), "The same key every time")
        #expect(first != KeychainVaultKey.derive(shared, profile: two), "Profiles are encrypted separately")
        #expect(first != shared && first != KeychainVaultKey.derive(Data(repeating: 7, count: 32), profile: one))
    }

    @Test func developmentBuildsKeepTheKeyInAPrivateFileSharedByProfiles() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyFile = url.deletingLastPathComponent().appending(path: "Development Key")
        let one = UUID(), two = UUID()
        #expect(try FileVaultKey(file: keyFile, profile: one).existing() == nil, "Nothing is made until the first save")
        let made = try FileVaultKey(file: keyFile, profile: one).make()
        let shared = try Data(contentsOf: keyFile)
        #expect(shared.count == 32 && made == KeychainVaultKey.derive(shared, profile: one))
        let permissions = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "Only this user can read it")
        #expect(try FileVaultKey(file: keyFile, profile: two).make() == KeychainVaultKey.derive(shared, profile: two),
                "Another profile derives its own key from the same file")
        try FileVaultKey(file: keyFile, profile: one).remove()
        #expect(FileManager.default.fileExists(atPath: keyFile.path), "Removing a profile keeps the shared key")

        let vault = PasswordVault(fileURL: url, key: FileVaultKey(file: keyFile, profile: one))
        #expect(await vault.load())
        _ = vault.save(origin: "https://example.com", username: "ada", password: "pw")
        await vault.flush()
        let reopened = PasswordVault(fileURL: url, key: FileVaultKey(file: keyFile, profile: one))
        #expect(await reopened.load() && reopened.logins.map(\.username) == ["ada"])

        try Data("short".utf8).write(to: keyFile)
        #expect(throws: (any Error).self) { try FileVaultKey(file: keyFile, profile: one).existing() }
    }

    @Test func deletingPasswordsStopsSavesAndOpensStillUnderWay() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A save still waiting for its Keychain key when the profile goes.
        let slow = MemoryVaultKey()
        let vault = PasswordVault(fileURL: url, key: slow)
        #expect(await vault.load())
        slow.delay = 0.3
        vault.save(origin: "https://example.com", username: "ada", password: "deleted")
        vault.removeAll()
        try await Task.sleep(for: .milliseconds(600))
        #expect(await vault.flush())
        #expect(!FileManager.default.fileExists(atPath: url.path), "The save can't bring the file back")
        #expect(vault.logins.isEmpty && !vault.isReady)
        #expect(vault.save(origin: "https://example.com", username: "ada", password: "again") == nil, "Nothing more is kept")
        #expect(await vault.load() == false)

        // Passwords still being opened when the profile goes don't come back.
        let key = MemoryVaultKey()
        let saved = PasswordVault(fileURL: url, key: key)
        #expect(await saved.load())
        saved.save(origin: "https://example.com", username: "ada", password: "old")
        await saved.flush()
        key.delay = 0.3
        let opening = PasswordVault(fileURL: url, key: key)
        let load = Task { await opening.load() }
        try await Task.sleep(for: .milliseconds(50))
        opening.removeAll()
        #expect(await load.value == false)
        #expect(opening.logins.isEmpty, "Nothing is restored")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Saves are encrypted and written off the main actor. Whenever the
    /// profile goes, before, during or after a write, no file is left behind.
    @Test func deletingWhileAWriteIsUnderWayLeavesNoFile() async throws {
        for yields in 0..<12 {
            let url = file()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let vault = PasswordVault(fileURL: url, key: MemoryVaultKey())
            #expect(await vault.load())
            for index in 0..<2_000 { vault.save(origin: "https://site\(index).example", username: "ada", password: "pw\(index)") }
            for _ in 0..<yields { await Task.yield() }
            vault.removeAll()
            #expect(await vault.flush())
            try await Task.sleep(for: .milliseconds(20))
            #expect(!FileManager.default.fileExists(atPath: url.path), "No file after \(yields) yields")
        }
    }

    @Test func failedSavesAreReportedAndCanBeTriedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EarlyPasswords-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the passwords' folder should be: nothing can be written.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "Passwords")
        try Data().write(to: blocker)
        let url = blocker.appending(path: "profile.vault")
        let vault = PasswordVault(fileURL: url, key: MemoryVaultKey())
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "ada", password: "kept")
        #expect(await vault.flush() == false)
        #expect(vault.saveError?.contains("couldn’t be written") == true, "\(vault.saveError ?? "nil")")
        #expect(vault.logins.count == 1 && vault.isReady, "Still in memory, still usable")
        try FileManager.default.removeItem(at: blocker)
        vault.retrySaving()
        #expect(await vault.flush() && vault.saveError == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A refused Keychain key: reported, the passwords kept for another try.
        let refusing = MemoryVaultKey()
        refusing.makeFails = true
        let other = PasswordVault(fileURL: directory.appending(path: "other.vault"), key: refusing)
        #expect(await other.load())
        other.save(origin: "https://example.com", username: "grace", password: "pw")
        #expect(await other.flush() == false && other.saveError?.contains("Keychain") == true)
        #expect(other.isReady && other.logins.count == 1)
        refusing.makeFails = false
        other.retrySaving()
        #expect(await other.flush())
        #expect(await PasswordVault(fileURL: directory.appending(path: "other.vault"), key: refusing).load())
    }

    @Test func strongPasswordDraftsNeverReplaceASavedPassword() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = MemoryVaultKey()
        let vault = PasswordVault(fileURL: url, key: key)
        #expect(await vault.load())
        vault.save(origin: "https://example.com", username: "ada", password: "working")
        vault.saveDraft(origin: "https://example.com", username: "ada", password: "generated")
        #expect(vault.login(origin: "https://example.com", username: "ada")?.password == "working")
        #expect(vault.drafts.map(\.password) == ["generated"] && vault.recentDraft(origin: "https://example.com")?.password == "generated")
        let draft = try #require(vault.draft(origin: "https://example.com", password: "generated"))
        #expect(vault.commitDraft(draft.id) == nil, "A login with that user name needs the person's say")
        #expect(vault.login(origin: "https://example.com", username: "ada")?.password == "working" && vault.drafts.count == 1)

        // Kept on disk with the logins, and opened again.
        await vault.flush()
        let reopened = PasswordVault(fileURL: url, key: key)
        #expect(await reopened.load())
        #expect(reopened.drafts.map(\.password) == ["generated"] && reopened.logins.map(\.password) == ["working"])
        let login = try #require(reopened.login(origin: "https://example.com", username: "ada"))
        #expect(reopened.replace(login.id, with: draft.id), "Replacing is the person's choice")
        #expect(reopened.login(id: login.id)?.password == "generated" && reopened.drafts.isEmpty)

        // A new account's draft becomes a login of its own.
        reopened.saveDraft(origin: "https://new.example", username: "", password: "fresh")
        reopened.saveDraft(origin: "https://new.example", username: "grace", password: "fresh")
        #expect(reopened.drafts.count == 1 && reopened.drafts[0].username == "grace", "One draft per password")
        #expect(reopened.commitDraft(reopened.drafts[0].id) == .added)
        #expect(reopened.login(origin: "https://new.example", username: "grace")?.password == "fresh" && reopened.drafts.isEmpty)
    }

    @Test func passwordsSavedBeforeDraftsExistedStillOpen() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // The format before drafts: version, logins and neverSaved only.
        let json = """
            {"version":1,"logins":[{"id":"\(UUID().uuidString)","origin":"https://example.com","username":"ada",
            "password":"old","note":"","created":"2026-10-20T10:00:00Z","modified":"2026-10-20T10:00:00Z"}],"neverSaved":[]}
            """
        let sealed = try AES.GCM.seal(Data(json.utf8), using: SymmetricKey(data: keyData))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data("EARLYPW1".utf8) + sealed.combined!).write(to: url)
        let vault = PasswordVault(fileURL: url, key: MemoryVaultKey(keyData))
        #expect(await vault.load())
        #expect(vault.logins.map(\.password) == ["old"] && vault.drafts.isEmpty)
    }

    @Test func importsKeepSavedPasswordsAndExportsReadBackTheSame() async throws {
        let vault = PasswordVault(fileURL: nil, key: nil)
        vault.save(origin: "https://github.com", username: "ada", password: "kept")
        let parsed = try PasswordCSV.parse("""
            name,url,username,password,note
            GitHub,https://github.com/login,ada,imported,
            GitHub,https://github.com/,ada,kept,
            Example,https://example.com/signin?next=/,"lovelace, ada","p""a,ss","line one
            line two"
            Phone app,android://hash@com.example.app/,me,pw,
            Empty,https://empty.example,me,,
            """)
        #expect(parsed.skipped == 2)
        let summary = vault.importRows(parsed.rows, skipped: parsed.skipped)
        #expect(summary == PasswordVault.ImportSummary(added: 1, duplicates: 1, conflicts: 1, skipped: 2))
        #expect(vault.login(origin: "https://github.com", username: "ada")?.password == "kept")
        let example = try #require(vault.login(origin: "https://example.com", username: "lovelace, ada"))
        #expect(example.password == "p\"a,ss" && example.note == "line one\nline two")

        let exported = vault.exportCSV()
        #expect(exported.hasPrefix("name,url,username,password,note\nexample.com,https://example.com/,"))
        let again = try PasswordCSV.parse(exported)
        #expect(Set(again.rows.map { "\($0.origin) \($0.username) \($0.password) \($0.note)" })
                == Set(vault.logins.map { "\($0.origin) \($0.username) \($0.password) \($0.note)" }))
    }
}

@Suite
struct PasswordCSVTests {
    @Test func otherBrowsersAndPasswordManagersExportsAreRead() throws {
        let safari = try PasswordCSV.parse("\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\nApple,https://appleid.apple.com/,ada@icloud.com,pw1,,\r\n")
        #expect(safari.rows == [.init(origin: "https://appleid.apple.com", username: "ada@icloud.com", password: "pw1")])

        let firefox = try PasswordCSV.parse("""
            "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
            "https://intranet.example","ada","pw2","Staff Only","","{1}","1","1","1"
            """)
        #expect(firefox.rows == [.init(origin: "https://intranet.example", username: "ada", password: "pw2", realm: "Staff Only")])

        let bitwarden = try PasswordCSV.parse("""
            folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
            ,,login,Example,A note,,0,https://example.com/login,ada,pw3,
            ,,note,Secret note,Text,,0,,,,
            """)
        #expect(bitwarden.rows == [.init(origin: "https://example.com", username: "ada", password: "pw3", note: "A note")])
        #expect(bitwarden.skipped == 1)

        let onePassword = try PasswordCSV.parse("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nShop,shop.example.com,ada,pw4,,false,false,,Gift card\n")
        #expect(onePassword.rows == [.init(origin: "https://shop.example.com", username: "ada", password: "pw4", note: "Gift card")],
                "A bare host is taken as https")

        let lastPass = try PasswordCSV.parse("url,username,password,totp,extra,name,grouping,fav\nhttp://sn,,,,Note body,Secure note,,0\nhttp://old.example:8080/,ada,pw5,,,Old,,0\n")
        #expect(lastPass.rows == [.init(origin: "http://old.example:8080", username: "ada", password: "pw5")])
        #expect(lastPass.skipped == 1, "Secure notes have no website")

        #expect(throws: PasswordCSV.Failure.unrecognized) { try PasswordCSV.parse("name,phone\nAda,123\n") }
        #expect(throws: PasswordCSV.Failure.unrecognized) { try PasswordCSV.parse("") }
    }

    @Test func fieldsAreQuotedOnlyWhenNeeded() {
        #expect(PasswordCSV.field("plain") == "plain")
        #expect(PasswordCSV.field("a,b") == "\"a,b\"")
        #expect(PasswordCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(PasswordCSV.field(" padded") == "\" padded\"")
        #expect(PasswordCSV.records("a,\"b\nc\",d\n\ne,f") == [["a", "b\nc", "d"], ["e", "f"]])
    }
}

@Suite
struct PasswordGeneratorTests {
    @Test func strongPasswordsAreReadableGroupsWhereSitesAllowThem() {
        for _ in 0..<50 {
            let password = PasswordGenerator.strongPassword()
            let groups = password.split(separator: "-")
            #expect(password.count == 20 && groups.count == 3 && groups.allSatisfy { $0.count == 6 }, "\(password)")
            #expect(password.contains(where: \.isUppercase) && password.contains(where: \.isNumber)
                    && password.contains(where: \.isLowercase), "\(password)")
            #expect(Set(password).isDisjoint(with: "lIO01"), "No look-alike characters: \(password)")
        }
        #expect(Set((0..<20).map { _ in PasswordGenerator.strongPassword() }).count == 20)
    }

    @Test func sitesRulesAndLengthLimitsAreFollowed() {
        let rules = PasswordRules.parse("minlength: 8; maxlength: 12; required: lower; required: upper; required: digit; required: [!#]; allowed: [-]")
        #expect(rules.minLength == 8 && rules.maxLength == 12 && rules.required.count == 4)
        #expect(rules.required[3] == ["!", "#"] && rules.allowed == ["-"])
        for _ in 0..<50 {
            guard let password = PasswordGenerator.strongPassword(rules: rules, maxLength: nil) else {
                Issue.record("No password for possible rules")
                return
            }
            #expect(password.count == 12, "\(password)")
            #expect(password.contains(where: \.isLowercase) && password.contains(where: \.isUppercase)
                    && password.contains(where: \.isNumber) && password.contains { "!#".contains($0) }, "\(password)")
            #expect(password.allSatisfy { $0.isLetter || $0.isNumber || "!#-".contains($0) }, "\(password)")
        }
        let short = PasswordGenerator.strongPassword(rules: PasswordRules(), maxLength: 10)
        #expect(short?.count == 10, "The field's maxlength: \(short ?? "nil")")
        let digits = PasswordGenerator.strongPassword(rules: .parse("required: digit; max-consecutive: 2"), maxLength: 12)
        #expect(digits?.count == 12 && digits?.allSatisfy(\.isNumber) == true, "\(digits ?? "nil")")
        #expect(PasswordRules.parse("required: []-]").required == [["]", "-"]], "A leading ] is a character")
        #expect(PasswordRules.parse("nonsense; minlength: x").minLength == nil)
    }

    @Test func websitesCantAskForHugeOrImpossiblePasswords() {
        let start = ContinuousClock.now
        // A site asking for a billion characters gets nothing, at once.
        #expect(PasswordGenerator.strongPassword(rules: .parse("minlength: 999999999"), maxLength: nil) == nil)
        #expect(PasswordGenerator.strongPassword(rules: .parse("minlength: 200"), maxLength: nil) == nil,
                "Longer than Early generates")
        #expect(PasswordGenerator.strongPassword(rules: .parse("minlength: 128"), maxLength: nil)?.count == 128)
        #expect(PasswordGenerator.strongPassword(rules: .parse("minlength: 30; maxlength: 12"), maxLength: nil) == nil,
                "Contradictory")
        #expect(PasswordGenerator.strongPassword(rules: PasswordRules(), maxLength: 6) == nil, "Too short to be strong")
        #expect(PasswordGenerator.strongPassword(rules: .parse("required: [a]; allowed: [a]; max-consecutive: 1"), maxLength: nil) == nil,
                "Impossible: one character that can't repeat")
        // Huge field limits are bounded by Early's own maximum.
        #expect((PasswordGenerator.strongPassword(rules: .parse("minlength: 100"), maxLength: Int(Int32.max))?.count ?? 0) <= 128)
        #expect(ContinuousClock.now - start < .seconds(1), "Bounded work")
    }
}
