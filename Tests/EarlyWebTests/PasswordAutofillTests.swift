// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Foundation
import Network
import Testing
import WebKit

/// Sign-in forms on local fixture pages, driven through Early's isolated
/// password script. Nothing touches the network or the Keychain.
@Suite(.serialized) @MainActor
struct PasswordAutofillTests {
    static let login = """
        <title>Sign in</title>
        <form id="form" action="welcome" method="get">
            <input id="user" name="username" autocomplete="username">
            <input id="pass" type="password" autocomplete="current-password">
            <button id="go">Sign in</button>
        </form>
        <script>
            window.seen = [];
            for (const id of ['user', 'pass']) document.getElementById(id).addEventListener('input', e => seen.push(id + '=' + e.target.value));
        </script>
        """
    /// A single-page app: the form goes away once it is sent. Its user name
    /// must be an email address, or the browser doesn't send the form.
    static let app = """
        <title>App</title>
        <form id="form"><input id="user" type="email"><input id="pass" type="password"></form>
        <script>
            document.getElementById('form').addEventListener('submit', e => {
                e.preventDefault();
                setTimeout(() => e.target.remove(), 50);
            });
        </script>
        """
    static let signUp = """
        <title>Join</title>
        <form id="form"><input id="user" autocomplete="username">
            <input id="new" type="password" autocomplete="new-password" passwordrules="minlength: 12; required: lower; required: upper; required: digit">
            <input id="confirm" type="password" autocomplete="new-password"></form>
        <script>document.getElementById('form').addEventListener('submit', e => { e.preventDefault(); e.target.remove(); });</script>
        """

    private func makeFixture(_ pages: [String: String]) -> PageToolFixture {
        let fixture = PageToolFixture(pages: pages)
        fixture.manager.passwords = PasswordVault(fileURL: nil, key: nil)
        fixture.manager.passwordTestSchemes = ["early-tools"]
        // Filling as pages open has its own test; the others choose from the list.
        fixture.manager.fillsPasswordsAutomatically = { false }
        return fixture
    }

    /// Runs in Early's password world, where a script's focus counts as the person's.
    @discardableResult
    private func run(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.callAsyncJavaScript(script, contentWorld: PasswordFormObserver.world)
    }

    /// Focuses a field as a person's click would. The list opens only after a
    /// person's action; whether WebKit counts a test's script as one can differ
    /// between macOS versions, so the test says so itself.
    private func click(_ id: String, in view: WKWebView) async throws {
        try await run("""
            Object.defineProperty(navigator, 'userActivation', { value: { isActive: true }, configurable: true });
            const field = document.getElementById('\(id)');
            field.blur();
            field.focus();
            """, in: view)
    }

    private func focus(_ id: String, in view: WKWebView, _ fixture: PageToolFixture) async throws -> FocusedPasswordField {
        fixture.manager.focusedPasswordField = nil
        try await click(id, in: view)
        try await fixture.waitUntil("focus \(id)") { fixture.manager.focusedPasswordField != nil }
        return try #require(fixture.manager.focusedPasswordField)
    }

    @Test func savedLoginsAreOfferedForTheSiteAndFilledLikeTyping() async throws {
        let fixture = makeFixture(["login": Self.login])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        vault.save(origin: "early-tools://fixture", username: "ada", password: "first")
        vault.save(origin: "early-tools://fixture", username: "grace", password: "second")
        vault.save(origin: "https://elsewhere.example", username: "eve", password: "other")
        let tab = try await fixture.open("login")
        let view = try fixture.page(tab).view

        let field = try await focus("user", in: view, fixture)
        #expect(field.role == .username && field.origin == "early-tools://fixture")
        let suggestions = manager.passwordSuggestions(for: field)
        #expect(suggestions.count == 3 && suggestions.last == .manage)
        #expect(Set(suggestions.compactMap { if case .login(_, let name) = $0 { name } else { nil } }) == ["ada", "grace"],
                "Only this site's logins")
        var typed = field
        typed.typed = "GR"
        #expect(manager.passwordSuggestions(for: typed).count == 2, "Typing narrows the list")
        #expect((try await focus("pass", in: view, fixture)).role == .current)
        // A hidden field gets nothing, even when a page focuses it.
        _ = try await fixture.evaluate("document.body.insertAdjacentHTML('beforeend', '<input id=hidden type=password style=opacity:0>'); 1", in: tab)
        manager.focusedPasswordField = nil
        try await click("hidden", in: view)
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.focusedPasswordField == nil)
        _ = try await focus("pass", in: view, fixture)

        let grace = try #require(vault.login(origin: "early-tools://fixture", username: "grace"))
        manager.choosePasswordSuggestion(.login(grace.id, username: "grace"))
        try await fixture.waitUntil("filled") { vault.login(id: grace.id)?.lastUsed != nil }
        let values = try await fixture.evaluate("[user.value, pass.value, seen.join(',')]", in: tab) as? [String]
        #expect(values == ["grace", "second", "user=grace,pass=second"], "The page's own listeners see the values")
    }

    @Test func onlyFieldsThatLookLikeUserNamesGetSavedAccounts() async throws {
        let fixture = makeFixture([
            // No form: a password field elsewhere doesn't make every text field a user name.
            "setup": """
                <title>Setup</title>
                <label>Workspace name <input id="workspace"></label>
                <label>Team <input id="team" name="team_name"></label>
                <div><input id="secret" type="password"></div>
                """,
            "signup": """
                <title>Join</title><form><label>Email <input id="email" type="email"></label>
                <input id="new" type="password" autocomplete="new-password"></form>
                """,
            "plain": "<title>Plain</title><form><input id=\"j_id0\" name=\"j_id0\"><input id=\"pw\" type=\"password\"></form>",
            "labeled": "<title>Labeled</title><label>Email address <input id=\"mail\"></label><input id=\"pw\" type=\"password\">"
        ])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        vault.save(origin: "early-tools://fixture", username: "", password: "nameless")
        vault.save(origin: "early-tools://fixture", username: "ada", password: "pw")
        func ignored(_ id: String, in view: WKWebView) async throws -> Bool {
            manager.focusedPasswordField = nil
            try await click(id, in: view)
            try await Task.sleep(for: .milliseconds(250))
            return manager.focusedPasswordField == nil
        }

        let setup = try fixture.page(try await fixture.open("setup")).view
        #expect(try await ignored("workspace", in: setup), "“Workspace name” isn't a user name")
        #expect(try await ignored("team", in: setup))
        let secret = try await focus("secret", in: setup, fixture)
        #expect(secret.role == .current && manager.passwordSuggestions(for: secret).count == 3,
                "A password field lists every login, with or without a user name")

        let signup = try fixture.page(try await fixture.open("signup")).view
        #expect(try await ignored("email", in: signup), "A sign-up form's user name is new")

        let plain = try fixture.page(try await fixture.open("plain")).view
        let field = try await focus("j_id0", in: plain, fixture)
        #expect(field.role == .username, "In a sign-in form, the field before the password")
        #expect(manager.passwordSuggestions(for: field) == [.login(vault.logins[1].id, username: "ada"), .manage],
                "A login without a user name has nothing to fill there")

        let labeled = try fixture.page(try await fixture.open("labeled")).view
        #expect((try await focus("mail", in: labeled, fixture)).role == .username, "Its label says it's an email address")
    }

    @Test func signInPagesWithASavedPasswordAreFilledAsTheyOpen() async throws {
        let later = """
            <title>Later</title><div id="app"></div>
            <script>setTimeout(() => app.innerHTML = '<form><input id=user autocomplete=username><input id=pass type=password></form>', 300)</script>
            """
        let typed = Self.login.replacingOccurrences(of: "<input id=\"user\"", with: "<input id=\"user\" value=\"grace\"")
        // The framed page, from another site, reports its own fields.
        let framed = Self.login + "<script>setTimeout(() => parent.postMessage([user.value, pass.value].join(' '), '*'), 800)</script>"
        let fixture = makeFixture(["login": Self.login, "later": later, "typed": typed, "framed": framed,
            "outer": "<title>Outer</title><iframe src=\"early-tools://accounts/framed\"></iframe><script>addEventListener('message', e => window.framed = e.data)</script>"])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        var enabled = true
        manager.fillsPasswordsAutomatically = { enabled }
        vault.save(origin: "early-tools://fixture", username: "ada", password: "first")
        vault.save(origin: "early-tools://fixture", username: "grace", password: "second")
        vault.save(origin: "early-tools://accounts", username: "frame", password: "framed")
        vault.markUsed(try #require(vault.login(origin: "early-tools://fixture", username: "grace")).id)
        func values(_ tab: BrowserTab) async throws -> [String] {
            var result: [String] = []
            for _ in 0..<400 {
                result = try await fixture.evaluate("['user', 'pass'].map(id => document.getElementById(id)?.value ?? '')", in: tab) as? [String] ?? []
                if result.last?.isEmpty == false { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            return result
        }

        let login = try await fixture.open("login")
        #expect(try await values(login) == ["grace", "second"], "The account used last")
        #expect(try await fixture.evaluate("seen.join(',')", in: login) as? String == "user=grace,pass=second",
                "Filled like typing")
        #expect(vault.logins.allSatisfy { $0.username != "ada" || $0.lastUsed == nil }, "Filling isn't using it yet")
        // Clicking the field still lists every account, and choosing one replaces what was filled.
        let field = try await focus("user", in: try fixture.page(login).view, fixture)
        #expect(manager.passwordSuggestions(for: field).count == 3, "Both accounts, not only the filled-in one")
        manager.choosePasswordSuggestion(.login(try #require(vault.login(origin: "early-tools://fixture", username: "ada")).id,
                                                username: "ada"))
        var chosen: [String] = []
        for _ in 0..<400 where chosen != ["ada", "first"] {
            try await Task.sleep(for: .milliseconds(25))
            chosen = try await fixture.evaluate("[user.value, pass.value]", in: login) as? [String] ?? []
        }
        #expect(chosen == ["ada", "first"])
        #expect(try await values(try await fixture.open("typed")) == ["grace", "second"], "The user name already in the form")
        #expect(try await values(try await fixture.open("later")) == ["ada", "first"],
                "A form that appears later, with the account chosen last")

        // Never in another site's frame.
        let outer = try await fixture.open("outer")
        var framedValues: String?
        for _ in 0..<400 where framedValues == nil {
            try await Task.sleep(for: .milliseconds(25))
            framedValues = try await fixture.evaluate("window.framed ?? null", in: outer) as? String
        }
        #expect(framedValues == " ", "Nothing filled in the framed page: \(framedValues ?? "nil")")

        // Turned off: the list under the field only.
        enabled = false
        let off = try await fixture.open("login")
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await fixture.evaluate("[user.value, pass.value]", in: off) as? [String] == ["", ""])

        #expect(WebViewManager.allowsAutomaticFill(origin: "https://example.com", testSchemes: []))
        #expect(!WebViewManager.allowsAutomaticFill(origin: "http://example.com", testSchemes: []), "Not on insecure pages")
        #expect(WebViewManager.allowsAutomaticFill(origin: "http://localhost:8080", testSchemes: []))
    }

    @Test func aSentSignInIsOfferedOnceItWorksAndUpdatedWhenItChanges() async throws {
        let fixture = makeFixture(["app": Self.app, "login": Self.login,
                               "welcome": "<title>Welcome</title><p>Signed in"])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        let tab = try await fixture.open("app")
        let page = try fixture.page(tab)

        // The form disappears after it is sent.
        _ = try await fixture.evaluate("user.value = 'ada@example.com'; pass.value = 'secret'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("offer") { page.passwordOffer != nil }
        let offer = try #require(page.passwordOffer)
        #expect(offer.origin == "early-tools://fixture" && offer.username == "ada@example.com" && offer.password == "secret" && !offer.isUpdate)
        manager.acceptPasswordOffer(in: tab.id, username: "ada")
        #expect(page.passwordOffer == nil)
        #expect(vault.login(origin: "early-tools://fixture", username: "ada")?.password == "secret", "The edited user name is kept")

        // A form sent to the next page: offered when that page loads.
        fixture.manager.load(fixture.url("login"), in: tab)
        try await fixture.waitUntil("login") { page.view.url == fixture.url("login") && !page.isLoading }
        _ = try await fixture.evaluate("user.value = 'ada'; pass.value = 'changed'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("update") { page.passwordOffer != nil }
        #expect(page.passwordOffer?.isUpdate == true && page.passwordOffer?.password == "changed")
        manager.acceptPasswordOffer(in: tab.id)
        #expect(vault.login(origin: "early-tools://fixture", username: "ada")?.password == "changed" && vault.logins.count == 1)

        // The same password again: nothing to offer, it's just used.
        fixture.manager.load(fixture.url("login"), in: tab)
        try await fixture.waitUntil("login again") { page.view.url == fixture.url("login") && !page.isLoading }
        _ = try await fixture.evaluate("user.value = 'ada'; pass.value = 'changed'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("used") { vault.logins.first?.lastUsed != nil }
        #expect(page.passwordOffer == nil)

        // A refused sign-in comes back to a password form: nothing is offered.
        fixture.manager.load(fixture.url("login"), in: tab)
        try await fixture.waitUntil("login refused") { page.view.url == fixture.url("login") && !page.isLoading }
        _ = try await fixture.evaluate("form.action = 'login'; user.value = 'ada'; pass.value = 'wrong'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("reloaded") { page.view.url?.query != nil && !page.isLoading }
        // The new page asks for the password again, so the sign-in is dropped.
        try await fixture.waitUntil("refused sign-in dropped") { page.pendingLogin == nil }
        #expect(page.passwordOffer == nil)

        // Never for this site.
        fixture.manager.load(fixture.url("app"), in: tab)
        try await fixture.waitUntil("app") { page.view.url == fixture.url("app") && !page.isLoading }
        _ = try await fixture.evaluate("user.value = 'grace@example.com'; pass.value = 'pw'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("offer for grace") { page.passwordOffer != nil }
        manager.neverSavePasswords(in: tab.id)
        #expect(vault.isNeverSaved("early-tools://fixture") && vault.logins.count == 1)
        fixture.manager.load(fixture.url("app"), in: tab)
        try await fixture.waitUntil("app again") { page.view.url == fixture.url("app") && !page.isLoading }
        _ = try await fixture.evaluate("user.value = 'hedy@example.com'; pass.value = 'pw'; form.requestSubmit(); 1", in: tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(page.passwordOffer == nil)
    }

    @Test func newPasswordFieldsGetAStrongPasswordKeptAsADraft() async throws {
        let fixture = makeFixture(["join": Self.signUp])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        let tab = try await fixture.open("join")
        let view = try fixture.page(tab).view
        let field = try await focus("new", in: view, fixture)
        #expect(field.role == .new && field.rules.minLength == 12)
        let suggestions = manager.passwordSuggestions(for: field)
        guard case .strongPassword(let password) = suggestions.first else { Issue.record("\(suggestions)"); return }
        #expect(suggestions.count == 2 && password.count >= 12)
        manager.focusedPasswordField = nil
        try await click("user", in: view)
        try await Task.sleep(for: .milliseconds(250))
        #expect(manager.focusedPasswordField == nil, "A new account's user name gets no saved accounts")

        _ = try await focus("new", in: view, fixture)
        _ = try await fixture.evaluate("user.value = ''; 1", in: tab)
        manager.choosePasswordSuggestion(.strongPassword(password))
        try await fixture.waitUntil("kept as a draft") { vault.drafts.count == 1 }
        let values = try await fixture.evaluate("[document.getElementById('new').value, document.getElementById('confirm').value]", in: tab) as? [String]
        #expect(values == [password, password], "Both fields")
        #expect(vault.logins.isEmpty && vault.drafts.first?.password == password, "Not a login until the website accepts it")
        // The form tried again gets the same strong password.
        let again = try await focus("new", in: view, fixture)
        #expect(manager.passwordSuggestions(for: again).first == .strongPassword(password))

        // Sending the form saves the new account, without asking.
        _ = try await fixture.evaluate("user.value = 'ada'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("saved") { vault.logins.count == 1 }
        #expect(vault.logins.first?.username == "ada" && vault.logins.first?.password == password && vault.drafts.isEmpty)
        #expect(try fixture.page(tab).passwordOffer == nil)
    }

    @Test func aStrongPasswordReplacesAWorkingOneOnlyWhenTheChangeIsAccepted() async throws {
        let change = """
            <title>Change password</title>
            <form id="form"><input id="user" autocomplete="username" value="ada">
                <input id="current" type="password" autocomplete="current-password">
                <input id="new" type="password" autocomplete="new-password">
                <input id="confirm" type="password" autocomplete="new-password"></form>
            <script>document.getElementById('form').addEventListener('submit', e => { e.preventDefault(); setTimeout(() => e.target.remove(), 50); });</script>
            """
        let fixture = makeFixture(["change": change])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        vault.save(origin: "early-tools://fixture", username: "ada", password: "working")
        var tab = try await fixture.open("change")
        let field = try await focus("new", in: try fixture.page(tab).view, fixture)
        guard case .strongPassword(let password) = manager.passwordSuggestions(for: field).first else { Issue.record("No strong password"); return }
        manager.choosePasswordSuggestion(.strongPassword(password))
        try await fixture.waitUntil("draft") { vault.drafts.count == 1 }
        #expect(vault.login(origin: "early-tools://fixture", username: "ada")?.password == "working",
                "Choosing it doesn't touch the saved password")

        // The website accepts the change: Early asks before replacing it.
        _ = try await fixture.evaluate("current.value = 'working'; form.requestSubmit(); 1", in: tab)
        var page = try fixture.page(tab)
        try await fixture.waitUntil("update offer") { page.passwordOffer != nil }
        #expect(page.passwordOffer?.isUpdate == true && page.passwordOffer?.password == password)
        manager.dismissPasswordOffer(in: tab.id)
        #expect(vault.login(origin: "early-tools://fixture", username: "ada")?.password == "working" && vault.drafts.count == 1,
                "Not Now keeps both: the working password and the draft")

        // Another try uses the same draft; Update replaces it at last.
        tab = try await fixture.open("change")
        page = try fixture.page(tab)
        let retry = try await focus("new", in: page.view, fixture)
        #expect(manager.passwordSuggestions(for: retry).first == .strongPassword(password))
        manager.choosePasswordSuggestion(.strongPassword(password))
        try await Task.sleep(for: .milliseconds(200))
        _ = try await fixture.evaluate("current.value = 'working'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("update offer again") { page.passwordOffer != nil }
        manager.acceptPasswordOffer(in: tab.id)
        #expect(vault.login(origin: "early-tools://fixture", username: "ada")?.password == password && vault.drafts.isEmpty)
    }

    @Test func aWebsitesHugePasswordRulesOfferNothing() async throws {
        let huge = """
            <title>Huge</title><form><input id="user" autocomplete="username">
            <input id="new" type="password" autocomplete="new-password" passwordrules="minlength: 999999999; required: digit"></form>
            """
        let fixture = makeFixture(["huge": huge])
        defer { fixture.cleanup() }
        let field = try await focus("new", in: try fixture.page(try await fixture.open("huge")).view, fixture)
        let start = ContinuousClock.now
        #expect(fixture.manager.passwordSuggestions(for: field).isEmpty)
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    /// A key kept in memory; tests never use the Keychain.
    final class TestKey: PasswordVaultKey, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        func existing() throws -> Data? { lock.withLock { stored } }
        func make() throws -> Data {
            lock.withLock {
                if let stored { return stored }
                let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                stored = fresh
                return fresh
            }
        }
        func remove() throws { lock.withLock { stored = nil } }
    }

    @Test func aPasswordThatCantBeSavedIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EarlyPasswordWrite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appending(path: "Passwords")
        try Data().write(to: blocker)
        let fixture = makeFixture(["app": Self.app])
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let vault = PasswordVault(fileURL: blocker.appending(path: "profile.vault"), key: TestKey())
        manager.passwords = vault
        var notices: [String] = []
        manager.onNotice = { notices.append($0) }
        let tab = try await fixture.open("app")
        let page = try fixture.page(tab)
        _ = try await fixture.evaluate("user.value = 'ada@example.com'; pass.value = 'secret'; form.requestSubmit(); 1", in: tab)
        try await fixture.waitUntil("offer") { page.passwordOffer != nil }
        manager.acceptPasswordOffer(in: tab.id)
        try await fixture.waitUntil("reported") { !notices.isEmpty }
        #expect(notices == ["The password for fixture couldn’t be saved. Try again in Settings › Passwords."])
        #expect(vault.logins.count == 1 && vault.saveError != nil, "Kept in memory for Try Again")
    }

    @Test func privateWindowsFillButNeverSave() async throws {
        let fixture = makeFixture(["login": Self.login, "app": Self.app, "join": Self.signUp])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        manager.savesPasswords = false
        vault.save(origin: "early-tools://fixture", username: "ada", password: "pw")
        let login = try await fixture.open("login")
        let field = try await focus("user", in: try fixture.page(login).view, fixture)
        #expect(manager.passwordSuggestions(for: field).count == 2)
        manager.choosePasswordSuggestion(.login(vault.logins[0].id, username: "ada"))
        var filled: String?
        for _ in 0..<500 where filled != "pw" {
            try await Task.sleep(for: .milliseconds(20))
            filled = try await fixture.evaluate("pass.value", in: login) as? String
        }
        #expect(filled == "pw")
        #expect(vault.logins[0].lastUsed == nil, "Nothing about the visit is recorded")

        let app = try await fixture.open("app")
        _ = try await fixture.evaluate("user.value = 'grace@example.com'; pass.value = 'new'; form.requestSubmit(); 1", in: app)
        try await Task.sleep(for: .milliseconds(800))
        #expect(try fixture.page(app).passwordOffer == nil && vault.logins.count == 1)

        let join = try await fixture.open("join")
        let new = try await focus("new", in: try fixture.page(join).view, fixture)
        #expect(manager.passwordSuggestions(for: new).isEmpty, "A strong password couldn't be kept")
    }

    @Test func aFrameSavesForItsOwnWebsite() async throws {
        // The framed page, from another origin, sends its form once loaded.
        let framed = Self.app + "<script>onload = () => { user.value = 'ada@example.com'; pass.value = 'framed'; form.requestSubmit(); };</script>"
        let fixture = makeFixture([
            "outer": "<title>Outer</title><iframe src=\"early-tools://accounts/framed\" width=400 height=200></iframe>",
            "framed": framed
        ])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("outer")
        let page = try fixture.page(tab)
        try await fixture.waitUntil("offer") { page.passwordOffer != nil }
        #expect(page.passwordOffer?.origin == "early-tools://accounts" && page.passwordOffer?.username == "ada@example.com",
                "The frame's own origin, from WebKit, not the page's")
    }

    @Test func httpSignInPromptsAreFilledFromAndSavedToPasswords() async throws {
        let server = try BasicAuthServer(username: "ada", password: "open sesame", realm: "Early Staff")
        defer { server.stop() }
        let fixture = makeFixture([:])
        defer { fixture.cleanup() }
        let manager = fixture.manager, vault = try #require(manager.passwords)
        var requests: [SignInRequest] = []
        var answers: [SignInResponse?] = [SignInResponse(username: "ada", password: "wrong", save: true),
                                          SignInResponse(username: "ada", password: "open sesame", save: true)]
        manager.askForSignIn = { request, _, answer in
            requests.append(request)
            answer(answers.isEmpty ? nil : answers.removeFirst())
        }
        let tab = try await fixture.open("staff", url: server.url)
        let page = try fixture.page(tab)
        try await fixture.waitUntil("signed in") { page.view.title == "Welcome" }
        #expect(requests.count == 2)
        #expect(requests.first?.host == "127.0.0.1" && requests.first?.realm == "Early Staff" && requests.first?.failed == false)
        #expect(requests.last?.failed == true && requests.last?.canSave == true && requests.last?.password == "")
        let saved = try #require(vault.login(origin: "http://127.0.0.1:\(server.port)", username: "ada"))
        #expect(saved.password == "open sesame" && saved.realm == "Early Staff")

        // A new session asks again, already filled in; Cancel shows the site's page.
        let other = makeFixture(["": ""])
        defer { other.cleanup() }
        other.manager.passwords = vault
        var filled: SignInRequest?
        other.manager.askForSignIn = { request, _, answer in
            filled = request
            answer(nil)
        }
        let again = try await other.open("staff", url: server.url)
        #expect(filled?.username == "ada" && filled?.password == "open sesame")
        let refused = try other.page(again)
        try await other.waitUntil("the site's page") { refused.view.title == "Sign in required" }
    }

    @Test func theListMovesItsHighlightAndChoosesWithReturn() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let panel = PasswordSuggestionPanel()
        var chosen: [PasswordSuggestion] = []
        panel.onChoose = { chosen.append($0) }
        let id = UUID()
        let items: [PasswordSuggestion] = [.login(id, username: "ada"), .login(UUID(), username: ""), .manage]
        panel.show(items, title: "Passwords for example.com", below: NSRect(x: 150, y: 300, width: 200, height: 24), in: window)
        #expect(panel.isVisible && panel.highlighted == nil)
        #expect(window.childWindows?.isEmpty != false, "Nothing appears over a window that isn't on screen")
        #expect(!panel.chooseHighlighted(), "Return without a highlight sends the form")
        panel.moveHighlight(-1)
        #expect(panel.highlighted == 2, "Up from nothing is the last row")
        panel.moveHighlight(1)
        #expect(panel.highlighted == 0, "And it wraps around")
        #expect(panel.chooseHighlighted())
        #expect(chosen == [.login(id, username: "ada")] && !panel.isVisible && window.childWindows?.isEmpty != false)

        // It wears the window's Space theme, and its edge never blocks a click.
        window.appearance = NSAppearance(named: .darkAqua)
        panel.show(items, title: "Passwords for example.com", below: NSRect(x: 150, y: 300, width: 200, height: 24), in: window,
                   style: PasswordListStyle(theme: .space(.blue), allowsTransparency: true))
        let surface = try #require(panel.surface), list = try #require(panel.list)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.isDark, "A child window takes its parent's appearance")
        let blue = WindowTheme.space(.blue).focusBorder(isDark: true, increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        #expect(surface.tint == PasswordSuggestionPanel.SurfaceView.color(blue) && list.tint == surface.tint)
        let point = surface.convert(NSPoint(x: surface.bounds.midX, y: PasswordSuggestionPanel.ListView.headerHeight + 10), from: list)
        #expect(surface.hitTest(point) is PasswordSuggestionPanel.RowView, "\(String(describing: surface.hitTest(point)))")
        panel.close()
    }

    @Test func fieldsAreFoundInTheWindowAtThePagesScale() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        // A 125% zoomed page: 640 CSS pixels across 800 points.
        let rect = try #require(WebViewManager.screenRect(of: ["x": 100, "y": 40, "width": 200, "height": 20, "viewport": 640], in: view))
        let windowRect = window.convertFromScreen(rect)
        let local = view.convert(windowRect, from: nil)
        #expect(abs(local.minX - 125) < 0.5 && abs(local.width - 250) < 0.5 && abs(local.height - 25) < 0.5, "\(local)")
        let top = view.isFlipped ? local.minY : view.bounds.height - local.maxY
        #expect(abs(top - 50) < 0.5, "\(local)")
    }
}

/// A loopback server behind HTTP Basic authentication.
final class BasicAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.early.tests.basic-auth")
    private let expected: String
    private let realm: String
    private(set) var port: UInt16 = 0

    init(username: String, password: String, realm: String) throws {
        expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.realm = realm
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/staff")! }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [expected, realm] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let authorized = request.components(separatedBy: "\r\n").contains { $0.lowercased() == "authorization: \(expected.lowercased())" }
            let body = authorized ? "<title>Welcome</title><p>Staff only" : "<title>Sign in required</title><p>401"
            var response = authorized ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"\(realm)\"\r\n"
            response += "Content-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
