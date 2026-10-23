// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import WebKit

/// A sign-in Early offers to save, or a changed password it offers to update.
public struct PasswordOffer: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let origin: String
    public let username: String
    public let password: String
    /// The saved login whose password this replaces; nil saves a new one.
    public let replaces: UUID?

    public var host: String { URL(string: origin)?.host ?? origin }
    public var isUpdate: Bool { replaces != nil }
}

/// A sign-in form was submitted; it is offered for saving once the sign-in
/// seems to have worked (the form went away or the page moved on).
struct PendingLogin {
    enum Kind: String { case login, new, change }
    let origin: String
    let kind: Kind
    let username: String
    let password: String
    /// The current password in a change-password form.
    let current: String
    let date: Date
}

/// A user name entered on its own, for sites that ask for the password next.
struct RecentUsername {
    let origin: String
    let value: String
    let date: Date
}

/// The sign-in field the suggestions list belongs to.
struct FocusedPasswordField {
    enum Role: String { case username, current, new }
    let tabID: UUID
    let token: String
    let role: Role
    let origin: String
    let frame: WKFrameInfo
    weak var view: WKWebView?
    let rect: [String: Any]
    var typed: String
    let rules: PasswordRules
    let maxLength: Int?
}

/// An HTTP (Basic, Digest or NTLM) sign-in request, for the sign-in sheet.
public struct SignInRequest: Equatable, Sendable {
    public let host: String
    public let realm: String?
    public let isSecure: Bool
    /// The previous attempt was refused.
    public let failed: Bool
    public let username: String
    public let password: String
    public let canSave: Bool
}

public struct SignInResponse: Equatable, Sendable {
    public let username: String
    public let password: String
    public let save: Bool

    public init(username: String, password: String, save: Bool) {
        self.username = username
        self.password = password
        self.save = save
    }
}

/// Finds sign-in forms in an isolated world, which page scripts cannot see
/// or call. It reports focused sign-in fields and submitted sign-ins, and
/// fills only what Early asks it to, in the frame whose origin owns the login.
@MainActor
final class PasswordFormObserver: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewManager?
    static let name = "earlyPasswords"
    static let world = WKContentWorld.world(name: "Early.Passwords")
    static let script = """
    (() => {
        if (window.__earlyPasswords) return;
        const post = message => {
            try { window.webkit.messageHandlers.earlyPasswords.postMessage(message); } catch (_) {}
        };
        const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        const tokens = new WeakMap();
        const fields = new Map();
        const newToken = () => typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
            : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        const tokenFor = node => {
            let token = tokens.get(node);
            if (!token) {
                token = newToken();
                tokens.set(node, token);
                fields.set(token, new WeakRef(node));
            }
            return token;
        };
        const fieldFor = token => {
            const node = fields.get(token)?.deref();
            return node && node.isConnected ? node : null;
        };
        const isInput = node => node instanceof HTMLInputElement;
        const isPassword = node => isInput(node) && node.type === 'password';
        const isText = node => isInput(node) && ['text', 'email', 'tel'].includes(node.type);
        const autocomplete = node => (node.getAttribute('autocomplete') || '').toLowerCase();
        const shown = node => {
            if (!node.isConnected || node.disabled) return false;
            const rect = node.getBoundingClientRect();
            if (rect.width < 2 || rect.height < 2) return false;
            const style = getComputedStyle(node);
            return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0.05;
        };
        const usable = node => shown(node) || node.value !== '';
        const scopeOf = node => node.form || node.getRootNode();
        const signUp = /sign.?up|regist|create|join|enrol|new.?account/i;
        // What a field says it is: its name, id, placeholder and labels.
        const hint = node => [node.name, node.id, node.getAttribute('placeholder'), node.getAttribute('aria-label'),
            ...Array.from(node.labels || [], label => label.textContent)].join(' ').slice(0, 500);
        const userWords = /user|e-?mail|log-?in|sign-?in|account|identifier|phone|mobile|handle/i;
        const otherWords = /name|company|workspace|organi[sz]|team|project|title|search|query|address|street|city|postal|zip|code|coupon|promo|captcha|amount|comment|message|url|website/i;
        const otherAutocomplete = /\\b(name|given-name|additional-name|family-name|nickname|organization|organization-title|street-address|address-line\\d|address-level\\d|postal-code|country|country-name|one-time-code|cc-[a-z-]+|bday[a-z-]*|url|search)\\b/;
        // "Email address" is a user name; "Workspace name" or "Account name" isn't.
        const userLike = node => {
            if (/\\b(username|email)\\b/.test(autocomplete(node)) || node.type === 'email') return true;
            const text = hint(node);
            return userWords.test(text) && (/user|e-?mail/i.test(text) || !otherWords.test(text));
        };
        const otherLike = node => otherAutocomplete.test(autocomplete(node)) || (otherWords.test(hint(node)) && !userLike(node));

        // The form's sign-in fields: a user name, then its password fields.
        const describe = scope => {
            const inputs = Array.from(scope instanceof HTMLFormElement ? scope.elements : scope.querySelectorAll('input'))
                .filter(isInput);
            const passwords = inputs.filter(node => isPassword(node) && usable(node));
            const first = passwords[0];
            let username = null;
            if (first) {
                // The nearest field before the password that looks like a user
                // name; in a real form, the field right before it unless it's
                // clearly something else.
                const before = inputs.slice(0, inputs.indexOf(first)).filter(node => isText(node) && usable(node)
                    && !otherAutocomplete.test(autocomplete(node)));
                const last = before[before.length - 1];
                username = before.filter(userLike).pop()
                    || (scope instanceof HTMLFormElement && last && !otherLike(last) ? last : null);
            } else {
                const texts = inputs.filter(node => isText(node) && shown(node) && !otherAutocomplete.test(autocomplete(node)));
                username = texts.find(node => /\\busername\\b/.test(autocomplete(node)))
                    || (texts.length <= 2 ? texts.find(userLike) : null)
                    || null;
            }
            const marked = passwords.find(node => autocomplete(node).includes('current-password'));
            const fresh = passwords.filter(node => autocomplete(node).includes('new-password'));
            let kind = 'login', current = first || null, created = [];
            if (passwords.length >= 3 || (passwords.length === 2 && marked)) {
                kind = 'change';
                current = marked || first;
                created = passwords.filter(node => node !== current);
            } else if (passwords.length === 2 || fresh.length
                       || (first && !marked && scope instanceof HTMLFormElement
                           && signUp.test([scope.id, scope.name, scope.getAttribute('action'), scope.className].join(' ')))) {
                kind = 'new';
                current = null;
                created = passwords;
            }
            return { passwords, username, kind, current, created };
        };

        const roleOf = (node, form) => {
            if (isPassword(node)) return form.created.includes(node) ? 'new' : 'current';
            return node === form.username ? 'username' : null;
        };

        // Where the field is in the top page's viewport. Across another
        // origin's frame it cannot be known exactly (viewport 0).
        const rectOf = node => {
            const rect = node.getBoundingClientRect();
            let x = rect.left, y = rect.top, exact = true, view = window;
            try {
                while (view !== view.top) {
                    const frame = view.frameElement;
                    if (!frame) { exact = false; break; }
                    const outer = frame.getBoundingClientRect();
                    x += outer.left + frame.clientLeft;
                    y += outer.top + frame.clientTop;
                    view = view.parent;
                }
            } catch (_) { exact = false; }
            let viewport = 0;
            try { viewport = window.top.innerWidth; } catch (_) { exact = false; }
            return { x, y, width: rect.width, height: rect.height, viewport: exact ? viewport : 0 };
        };

        let menuToken = null, menuSelected = false, filling = false, watching = null;
        const report = node => {
            // Never under a field the person can't see.
            if (!shown(node)) return;
            const form = describe(scopeOf(node));
            const role = roleOf(node, form);
            // A sign-up form's user name is new: no saved accounts for it.
            if (!role || (role === 'username' && form.kind !== 'login')) return;
            post({ type: 'focus', token: tokenFor(node), role, rect: rectOf(node),
                   maxLength: node.maxLength > 0 ? node.maxLength : 0, rules: node.getAttribute('passwordrules') || '' });
        };
        const editable = node => isPassword(node) || isText(node);
        // Only a person's click or key shows the list, not a page focusing a field.
        document.addEventListener('focusin', event => {
            const node = event.composedPath()[0];
            if (!filling && editable(node) && navigator.userActivation?.isActive !== false) report(node);
        }, true);
        document.addEventListener('mousedown', event => {
            const node = event.composedPath()[0];
            if (event.isTrusted && editable(node) && node.getRootNode().activeElement === node) report(node);
        }, true);
        document.addEventListener('focusout', event => {
            const token = tokens.get(event.composedPath()[0]);
            if (token && token === menuToken) post({ type: 'blur', token });
        }, true);
        document.addEventListener('input', event => {
            if (filling) return;
            const node = event.composedPath()[0];
            const token = tokens.get(node);
            if (token && isText(node)) post({ type: 'input', token, value: node.value.slice(0, 256) });
        }, true);

        // A sign-in that went through: the form disappeared or the address changed.
        const watch = node => {
            const address = location.href;
            watching = node;
            for (const delay of [400, 1200, 2500, 5000]) {
                setTimeout(() => {
                    if (watching !== node) return;
                    if (!node.isConnected || !shown(node) || location.href !== address) {
                        watching = null;
                        post({ type: 'submitted' });
                    }
                }, delay);
            }
        };
        const capture = scope => {
            const form = describe(scope);
            if (!form.passwords.length) {
                if (form.username && form.username.value) post({ type: 'username', value: form.username.value.slice(0, 256) });
                return;
            }
            const created = form.created.map(node => node.value);
            const password = form.kind === 'login' ? form.current.value : created[0] || '';
            if (!password || (created.length >= 2 && created[0] !== created[1])) return;
            post({ type: 'pending', kind: form.kind, username: form.username ? form.username.value.slice(0, 256) : '',
                   password: password.slice(0, 1024),
                   current: form.kind === 'change' && form.current ? form.current.value.slice(0, 1024) : '' });
            watch(form.current || form.created[0]);
        };
        document.addEventListener('submit', event => {
            const form = event.composedPath()[0];
            if (form instanceof HTMLFormElement) capture(form);
        }, true);
        document.addEventListener('click', event => {
            if (!event.isTrusted) return;
            const button = event.composedPath().find(node => node instanceof Element
                && node.matches('button, input[type=submit], input[type=image], input[type=button], [role=button]'));
            if (button) capture(button.form || scopeOf(button));
        }, true);
        document.addEventListener('keydown', event => {
            if (!event.isTrusted) return;
            const node = event.composedPath()[0];
            const token = tokens.get(node);
            if (menuToken && token === menuToken) {
                if (['ArrowDown', 'ArrowUp', 'Escape'].includes(event.key) || (event.key === 'Enter' && menuSelected)) {
                    event.preventDefault();
                    event.stopImmediatePropagation();
                    post({ type: 'key', token, key: event.key });
                    return;
                }
                if (event.key === 'Tab') post({ type: 'key', token, key: 'Tab' });
            } else if (event.key === 'ArrowDown' && editable(node) && !event.altKey) {
                report(node);
            }
            if (event.key === 'Enter' && editable(node)) capture(scopeOf(node));
        }, true);
        // A sign-in form as it appears, for filling it in automatically: each
        // password field once, while it's empty.
        const announced = new WeakSet();
        const announce = () => {
            for (const field of document.querySelectorAll('input[type=password]')) {
                if (announced.has(field) || !shown(field)) continue;
                const form = describe(scopeOf(field));
                if (form.kind !== 'login' || form.current !== field) continue;
                announced.add(field);
                if (field.value) continue;
                post({ type: 'form', token: tokenFor(field), username: form.username ? form.username.value.slice(0, 256) : '' });
            }
        };
        let announcing = null;
        const soon = () => {
            if (announcing) return;
            announcing = setTimeout(() => { announcing = null; announce(); }, 250);
        };
        document.addEventListener('DOMContentLoaded', soon);
        window.addEventListener('load', soon);
        new MutationObserver(soon).observe(document, { childList: true, subtree: true, attributes: true,
            attributeFilter: ['class', 'style', 'hidden', 'type'] });
        const moved = () => { if (menuToken) post({ type: 'move' }); };
        window.addEventListener('scroll', moved, true);
        window.addEventListener('resize', moved);
        window.addEventListener('pagehide', moved);
        window.addEventListener('blur', moved);

        window.__earlyPasswords = Object.freeze({
            // Fills like typing, so the page's own scripts see the values.
            fill(token, username, password, mode) {
                const node = fieldFor(token);
                if (!node) return null;
                const form = describe(scopeOf(node));
                const set = (input, value) => {
                    if (!input || input.readOnly || input.disabled) return;
                    setValue.call(input, value);
                    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
                    input.dispatchEvent(new Event('change', { bubbles: true }));
                };
                filling = true;
                try {
                    if (mode === 'new') {
                        (form.created.length ? form.created : [node]).forEach(input => set(input, password));
                    } else if (mode === 'auto') {
                        // Never over something typed in the meantime.
                        const target = form.current;
                        if (!target || target.value || (form.username && form.username.value && form.username.value !== username)) return null;
                        if (username && form.username && !form.username.value) set(form.username, username);
                        set(target, password);
                    } else {
                        if (username !== null && form.username) set(form.username, username);
                        set(form.current || (isPassword(node) ? node : form.passwords[0]), password);
                    }
                } finally { filling = false; }
                return { username: form.username ? form.username.value.slice(0, 256) : '' };
            },
            menu(token, selected) { menuToken = token; menuSelected = !!selected; },
            hasLoginForm() {
                return Array.from(document.querySelectorAll('input[type=password]')).some(shown);
            },
        });
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world === Self.world, let view = message.webView,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        owner?.handlePasswordMessage(type, body: body, frame: message.frameInfo, in: view)
    }
}

@MainActor
extension WebViewManager {
    /// A pending sign-in older than this is not offered for saving.
    static let pendingLoginLifetime: TimeInterval = 30
    /// A user name entered alone is used by a password step this soon after.
    static let recentUsernameLifetime: TimeInterval = 600

    /// `scheme://host[:port]` of the frame a message came from: the page
    /// never says which website it is.
    func passwordOrigin(_ frame: WKFrameInfo) -> String? {
        let origin = frame.securityOrigin
        let scheme = origin.protocol.lowercased()
        if passwordTestSchemes.contains(scheme), !origin.host.isEmpty { return "\(scheme)://\(origin.host.lowercased())" }
        return SitePermissions.origin(scheme: scheme, host: origin.host, port: origin.port)
    }

    func handlePasswordMessage(_ type: String, body: [String: Any], frame: WKFrameInfo, in view: WKWebView) {
        guard passwords != nil, let id = tabID(for: view), let page = pages[id], let origin = passwordOrigin(frame) else { return }
        let text = { (key: String, limit: Int) -> String in String((body[key] as? String ?? "").prefix(limit)) }
        switch type {
        case "focus":
            guard let role = (body["role"] as? String).flatMap(FocusedPasswordField.Role.init(rawValue:)),
                  let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 128,
                  visibleTabIDs.contains(id), view.window?.isKeyWindow != false else { return }
            let maxLength = body["maxLength"] as? Int
            focusedPasswordField = FocusedPasswordField(tabID: id, token: token, role: role, origin: origin, frame: frame,
                // Only typing narrows the list: a filled-in user name still
                // lists every account, to switch to another.
                view: view, rect: body["rect"] as? [String: Any] ?? [:], typed: "",
                rules: PasswordRules.parse(text("rules", 512)), maxLength: maxLength.flatMap { $0 > 0 ? $0 : nil })
            showPasswordSuggestions()
        case "input":
            guard var field = focusedPasswordField, field.token == body["token"] as? String, field.view === view else { return }
            field.typed = text("value", 256)
            focusedPasswordField = field
            showPasswordSuggestions()
        case "key":
            guard focusedPasswordField?.token == body["token"] as? String else { return }
            switch body["key"] as? String {
            case "ArrowDown": passwordPanel.moveHighlight(1)
            case "ArrowUp": passwordPanel.moveHighlight(-1)
            case "Enter": passwordPanel.chooseHighlighted()
            default: hidePasswordSuggestions()
            }
        case "blur", "move":
            guard focusedPasswordField?.view === view else { return }
            hidePasswordSuggestions()
        case "form":
            guard let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 128 else { return }
            fillAutomatically(token: token, typed: text("username", 256), origin: origin, frame: frame, in: view)
        case "username":
            let value = text("value", 256)
            guard !value.isEmpty else { return }
            page.recentUsername = RecentUsername(origin: origin, value: value, date: Date())
        case "pending":
            let password = text("password", 1024)
            guard savesPasswords, !password.isEmpty,
                  let kind = (body["kind"] as? String).flatMap(PendingLogin.Kind.init(rawValue:)) else { return }
            var username = text("username", 256)
            if username.isEmpty, let recent = page.recentUsername, recent.origin == origin,
               Date().timeIntervalSince(recent.date) < Self.recentUsernameLifetime { username = recent.value }
            page.pendingLogin = PendingLogin(origin: origin, kind: kind, username: username, password: password,
                                             current: text("current", 1024), date: Date())
        case "submitted":
            guard let pending = page.pendingLogin, Date().timeIntervalSince(pending.date) < Self.pendingLoginLifetime else { return }
            page.pendingLogin = nil
            offerToSave(pending, in: id)
        default:
            return
        }
    }

    // MARK: Suggestions

    /// The saved logins for the field's website, or a strong password for a
    /// new-password field. Nothing is filled until one is chosen.
    func passwordSuggestions(for field: FocusedPasswordField) -> [PasswordSuggestion] {
        guard let vault = passwords, vault.isReady else { return [] }
        var items: [PasswordSuggestion] = []
        switch field.role {
        case .new:
            // Never in a private window, where it could not be kept.
            guard savesPasswords, !vault.isNeverSaved(field.origin),
                  let password = PasswordGenerator.strongPassword(rules: field.rules, maxLength: field.maxLength) else { return [] }
            items = [.strongPassword(password)]
        case .username, .current:
            let typed = field.role == .username ? field.typed.lowercased() : ""
            // A login without a user name has nothing to fill in a user name field.
            items = vault.logins(for: field.origin)
                .filter { field.role == .current || !$0.username.isEmpty }
                .filter { typed.isEmpty || $0.username.lowercased().hasPrefix(typed) }
                .prefix(8).map { .login($0.id, username: $0.username) }
        }
        return items.isEmpty ? [] : items + [.manage]
    }

    func showPasswordSuggestions() {
        guard let field = focusedPasswordField, let vault = passwords, let view = field.view else { return }
        guard vault.isReady else {
            // The first sign-in field opens the saved passwords.
            Task { @MainActor [weak self] in
                guard await vault.load(), let self, self.focusedPasswordField?.token == field.token else { return }
                self.showPasswordSuggestions()
            }
            return
        }
        // A strong password stays the same while its list is open.
        var items = passwordSuggestions(for: field)
        if field.role == .new, passwordPanel.isVisible, let shown = passwordPanel.items.first, case .strongPassword = shown {
            items[0] = shown
        }
        guard !items.isEmpty, let window = view.window, let rect = Self.screenRect(of: field.rect, in: view) else {
            hidePasswordSuggestions(keepingField: true)
            return
        }
        let host = URL(string: field.origin)?.host ?? field.origin
        passwordPanel.onChoose = { [weak self] in self?.choosePasswordSuggestion($0) }
        passwordPanel.onHighlight = { [weak self] index in self?.setPageMenu(open: true, selected: index != nil) }
        passwordPanel.show(items, title: field.role == .new ? "Strong password for \(host)" : "Passwords for \(host)",
                           below: rect, in: window, style: passwordListStyle())
        setPageMenu(open: true, selected: passwordPanel.highlighted != nil)
    }

    func hidePasswordSuggestions(keepingField: Bool = false) {
        if passwordPanel.isVisible { setPageMenu(open: false, selected: false) }
        passwordPanel.onChoose = nil
        passwordPanel.close()
        if !keepingField { focusedPasswordField = nil }
    }

    /// While the list is open the page forwards arrows, Return and Escape.
    private func setPageMenu(open: Bool, selected: Bool) {
        guard let field = focusedPasswordField, let view = field.view else { return }
        view.callAsyncJavaScript("globalThis.__earlyPasswords?.menu(token, selected)",
                                 arguments: ["token": open ? field.token : NSNull(), "selected": selected],
                                 in: field.frame, in: PasswordFormObserver.world) { _ in }
    }

    /// The field's frame in screen coordinates. Inside another origin's frame
    /// its position is unknown, so the list opens at the pointer instead.
    static func screenRect(of rect: [String: Any], in view: WKWebView) -> NSRect? {
        guard let window = view.window else { return nil }
        let value = { (key: String) -> CGFloat in CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
        let viewport = value("viewport")
        guard viewport > 0, view.bounds.width > 0 else {
            let pointer = NSEvent.mouseLocation
            return NSRect(x: pointer.x - 1, y: pointer.y - 12, width: 2, height: 24)
        }
        let scale = view.bounds.width / viewport
        var local = NSRect(x: value("x") * scale, y: value("y") * scale, width: value("width") * scale, height: value("height") * scale)
        if !view.isFlipped { local.origin.y = view.bounds.height - local.maxY }
        return window.convertToScreen(view.convert(local, to: nil))
    }

    func choosePasswordSuggestion(_ item: PasswordSuggestion) {
        guard let field = focusedPasswordField, let vault = passwords else { return }
        switch item {
        case .login(let id, _):
            guard let login = vault.login(id: id) else { return }
            Task { @MainActor [weak self] in
                guard let self, await self.fillPasswordField(field, username: login.username, password: login.password, mode: "login") != nil
                else { return }
                if self.savesPasswords { vault.markUsed(id) }
            }
        case .strongPassword(let password):
            Task { @MainActor [weak self] in
                guard let self, let username = await self.fillPasswordField(field, username: nil, password: password, mode: "new"),
                      self.savesPasswords else { return }
                // Kept at once, so it can't be lost if the form fails; the user
                // name is added when the form is sent.
                vault.save(origin: field.origin, username: username, password: password)
            }
        case .manage:
            onManagePasswords?(URL(string: field.origin)?.host)
        }
    }

    /// Returns the form's user name after filling, or nil if the field is gone.
    func fillPasswordField(_ field: FocusedPasswordField, username: String?, password: String, mode: String) async -> String? {
        guard let view = field.view, tabID(for: view) == field.tabID else { return nil }
        return await fillPasswordField(token: field.token, frame: field.frame, in: view, username: username, password: password, mode: mode)
    }

    func fillPasswordField(token: String, frame: WKFrameInfo, in view: WKWebView, username: String?, password: String,
                           mode: String) async -> String? {
        let result = try? await view.callAsyncJavaScript(
            "return globalThis.__earlyPasswords?.fill(token, username, password, mode) ?? null",
            arguments: ["token": token, "username": username ?? NSNull(), "password": password, "mode": mode],
            in: frame, contentWorld: PasswordFormObserver.world)
        return (result as? [String: Any])?["username"] as? String
    }

    // MARK: Filling as the page opens

    /// Like Chrome: only on a secure page, in the page itself or a frame of
    /// the same site, never over typing. With several accounts, the one used
    /// last, or the one whose user name is already in the form.
    func fillAutomatically(token: String, typed: String, origin: String, frame: WKFrameInfo, in view: WKWebView) {
        guard fillsPasswordsAutomatically(), let vault = passwords, let id = tabID(for: view), let page = pages[id],
              Self.allowsAutomaticFill(origin: origin, testSchemes: passwordTestSchemes),
              frame.isMainFrame || view.url.flatMap(passwordOrigin(of:)) == origin else { return }
        guard vault.isReady else {
            Task { @MainActor [weak self, weak view] in
                guard await vault.load(), let self, let view else { return }
                self.fillAutomatically(token: token, typed: typed, origin: origin, frame: frame, in: view)
            }
            return
        }
        let logins = vault.logins(for: origin)
        var chosen: SavedLogin?
        if !typed.isEmpty {
            chosen = logins.first { $0.username == typed }
        } else if let recent = page.recentUsername, recent.origin == origin,
                  Date().timeIntervalSince(recent.date) < Self.recentUsernameLifetime,
                  let match = logins.first(where: { $0.username == recent.value }) {
            // The user name step of a two-step sign-in.
            chosen = match
        } else {
            chosen = logins.max { ($0.lastUsed ?? .distantPast, $0.modified) < ($1.lastUsed ?? .distantPast, $1.modified) }
        }
        guard let chosen else { return }
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, self.tabID(for: view) == id else { return }
            _ = await self.fillPasswordField(token: token, frame: frame, in: view, username: chosen.username,
                                             password: chosen.password, mode: "auto")
        }
    }

    /// Secure pages only: https, or this Mac itself.
    nonisolated static func allowsAutomaticFill(origin: String, testSchemes: Set<String>) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" || testSchemes.contains(scheme) { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// A page address's password origin, matching `passwordOrigin(_:)` for frames.
    func passwordOrigin(of url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if passwordTestSchemes.contains(scheme), let host = url.host?.lowercased(), !host.isEmpty { return "\(scheme)://\(host)" }
        return SitePermissions.origin(of: url)
    }

    // MARK: Saving

    /// A pending sign-in after its page finished loading: offered unless the
    /// new page asks for a password again, which means it was refused.
    func checkPendingLogin(_ id: UUID) {
        guard let page = pages[id], let pending = page.pendingLogin else { return }
        guard Date().timeIntervalSince(pending.date) < Self.pendingLoginLifetime else { page.pendingLogin = nil; return }
        let generation = page.navigationGeneration
        Task { @MainActor [weak self, weak page] in
            let refused = (try? await page?.view.callAsyncJavaScript("return globalThis.__earlyPasswords?.hasLoginForm() ?? false",
                in: nil, contentWorld: PasswordFormObserver.world)) as? Bool ?? false
            guard let self, let page, self.pages[id] === page, page.navigationGeneration == generation,
                  page.pendingLogin?.date == pending.date else { return }
            page.pendingLogin = nil
            if !refused { self.offerToSave(pending, in: id) }
        }
    }

    func offerToSave(_ pending: PendingLogin, in id: UUID) {
        guard savesPasswords, let vault = passwords, let page = pages[id] else { return }
        guard vault.isReady else {
            Task { @MainActor [weak self] in if await vault.load() { self?.offerToSave(pending, in: id) } }
            return
        }
        guard !vault.isNeverSaved(pending.origin) else { return }
        let offer: (String, UUID?) -> Void = { username, replaces in
            page.passwordOffer = PasswordOffer(origin: pending.origin, username: username, password: pending.password, replaces: replaces)
        }
        let saved = vault.logins.filter { $0.origin == pending.origin }
        // A changed password: the current one tells which login it was.
        if pending.kind == .change, !pending.current.isEmpty,
           let login = saved.first(where: { $0.password == pending.current && (pending.username.isEmpty || $0.username == pending.username) }) {
            if login.password != pending.password { offer(login.username, login.id) }
            return
        }
        if let login = saved.first(where: { $0.username == pending.username }) {
            if login.password == pending.password {
                if pending.kind == .login { vault.markUsed(login.id) }
            } else {
                offer(login.username, login.id)
            }
            return
        }
        // A strong password kept before its user name was known.
        if !pending.username.isEmpty, var generated = saved.first(where: { $0.username.isEmpty && $0.password == pending.password }) {
            generated.username = pending.username
            vault.update(generated)
            return
        }
        offer(pending.username, nil)
    }

    /// Save or Update: the offer's password goes into the profile's passwords.
    public func acceptPasswordOffer(in id: UUID, username: String? = nil) {
        guard let page = pages[id], let offer = page.passwordOffer, let vault = passwords else { return }
        page.passwordOffer = nil
        if let replaces = offer.replaces, var login = vault.login(id: replaces) {
            login.password = offer.password
            vault.update(login)
        } else {
            vault.save(origin: offer.origin, username: username ?? offer.username, password: offer.password)
        }
    }

    public func neverSavePasswords(in id: UUID) {
        guard let page = pages[id], let offer = page.passwordOffer else { return }
        page.passwordOffer = nil
        passwords?.neverSave(offer.origin)
    }

    public func dismissPasswordOffer(in id: UUID) { pages[id]?.passwordOffer = nil }

    // MARK: HTTP sign-in

    static let signInMethods: Set<String> = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                             NSURLAuthenticationMethodNTLM]

    /// A website's own sign-in prompt, filled from a saved login. Server
    /// certificates and everything else keep WebKit's default handling.
    func handleAuthentication(_ challenge: URLAuthenticationChallenge, in view: WKWebView,
                              completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard Self.signInMethods.contains(space.authenticationMethod), !space.isProxy(), tabID(for: view) != nil,
              let scheme = space.protocol?.lowercased(), ["http", "https"].contains(scheme) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let origin = SitePermissions.origin(scheme: scheme, host: space.host, port: space.port)
        let failed = challenge.previousFailureCount > 0
        let proposed = challenge.proposedCredential?.user
        Task { @MainActor [weak self, weak view] in
            guard let self, let view else { completionHandler(.performDefaultHandling, nil); return }
            var saved: SavedLogin?
            if let vault = self.passwords, let origin, await vault.load() {
                let logins = vault.logins(for: origin)
                saved = logins.first { $0.realm == space.realm } ?? logins.first
            }
            let request = SignInRequest(host: space.host, realm: space.realm, isSecure: space.receivesCredentialSecurely, failed: failed,
                                        username: proposed ?? saved?.username ?? "", password: failed ? "" : saved?.password ?? "",
                                        canSave: self.savesPasswords && self.passwords != nil && origin != nil)
            let answer: @MainActor (SignInResponse?) -> Void = { [weak self] response in
                guard let response, !(response.username.isEmpty && response.password.isEmpty) else {
                    // Cancel shows the website's own page for a refused sign-in.
                    completionHandler(.performDefaultHandling, nil)
                    return
                }
                if let self, let vault = self.passwords, let origin {
                    if response.save, request.canSave {
                        vault.save(origin: origin, username: response.username, password: response.password, realm: space.realm)
                    }
                    if self.savesPasswords, let login = vault.login(origin: origin, username: response.username),
                       login.password == response.password { vault.markUsed(login.id) }
                }
                completionHandler(.useCredential, URLCredential(user: response.username, password: response.password, persistence: .forSession))
            }
            if let askForSignIn = self.askForSignIn { askForSignIn(request, view, answer) }
            else { self.presentSignInSheet(request, in: view, complete: answer) }
        }
    }

    func presentSignInSheet(_ request: SignInRequest, in view: WKWebView, complete: @escaping @MainActor (SignInResponse?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in to “\(request.host)”"
        var lines: [String] = []
        if let realm = request.realm, !realm.isEmpty { lines.append("The website says: “\(realm.prefix(200))”") }
        if request.failed { lines.append("The user name or password wasn’t accepted. Try again.") }
        if !request.isSecure { lines.append("Your password will be sent without encryption.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let width: CGFloat = 260
        let save = NSButton(checkboxWithTitle: "Save in Early Passwords", target: nil, action: nil)
        save.state = .on
        let height: CGFloat = request.canSave ? 84 : 56
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let user = NSTextField(frame: NSRect(x: 0, y: height - 24, width: width, height: 24))
        user.placeholderString = "User Name"
        user.stringValue = request.username
        user.setAccessibilityIdentifier("signIn.username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: height - 56, width: width, height: 24))
        password.placeholderString = "Password"
        password.stringValue = request.password
        password.setAccessibilityIdentifier("signIn.password")
        user.nextKeyView = password
        fields.addSubview(user)
        fields.addSubview(password)
        if request.canSave {
            save.frame = NSRect(x: 0, y: 0, width: width, height: 18)
            fields.addSubview(save)
        }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = request.username.isEmpty ? user : password
        presentAlert(alert, in: view) { response, _ in
            guard response == .alertFirstButtonReturn else { complete(nil); return }
            complete(SignInResponse(username: user.stringValue, password: password.stringValue,
                                    save: request.canSave && save.state == .on))
        }
    }
}
