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

    /// `legacy` is a key an earlier build kept.
    init(_ key: Data? = nil, legacy: Data? = nil) {
        stored = key
        old = legacy
    }

    var readCount: Int { lock.withLock { reads } }
    var key: Data? { lock.withLock { stored } }
    var legacyKey: Data? { lock.withLock { old } }

    func existing() throws -> Data? {
        try lock.withLock {
            reads += 1
            if let _failure { throw PasswordVault.KeyError(status: _failure) }
            return stored
        }
    }

    func make() throws -> Data {
        lock.withLock {
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: url.path) && key.key == nil)
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
            let password = PasswordGenerator.strongPassword(rules: rules)
            #expect(password.count == 12, "\(password)")
            #expect(password.contains(where: \.isLowercase) && password.contains(where: \.isUppercase)
                    && password.contains(where: \.isNumber) && password.contains { "!#".contains($0) }, "\(password)")
            #expect(password.allSatisfy { $0.isLetter || $0.isNumber || "!#-".contains($0) }, "\(password)")
        }
        let short = PasswordGenerator.strongPassword(maxLength: 10)
        #expect(short.count == 10, "The field's maxlength: \(short)")
        let digits = PasswordGenerator.strongPassword(rules: .parse("required: digit; max-consecutive: 2"), maxLength: 6)
        #expect(digits.count == 6 && digits.allSatisfy(\.isNumber), "\(digits)")
        #expect(PasswordRules.parse("required: []-]").required == [["]", "-"]], "A leading ] is a character")
        #expect(PasswordRules.parse("nonsense; minlength: x").minLength == nil)
    }
}
