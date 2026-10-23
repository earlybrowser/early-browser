// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// Saved passwords are shown only after Touch ID or the Mac's password. They
/// lock again when Early goes to the background, when Passwords closes, and
/// five minutes after the last use. Filling a page never asks.
@MainActor @Observable
final class PasswordsLock {
    private(set) var isUnlocked = false
    @ObservationIgnored var authenticate: (String) async -> Bool = PasswordsLock.deviceOwner
    @ObservationIgnored private var relock: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Touch ID and Keychain prompts are other apps' windows: Early is
    /// briefly inactive while it asks, which must not lock Passwords.
    @ObservationIgnored private var prompts = 0
    static let timeout: Duration = .seconds(300)

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.prompts == 0 else { return }
                self.lock()
            }
        }
    }

    /// Runs work that may show a system prompt.
    @discardableResult
    func prompting<T>(_ work: () async -> T) async -> T {
        prompts += 1
        defer { prompts -= 1 }
        return await work()
    }

    @discardableResult
    func unlock() async -> Bool {
        if isUnlocked { touch(); return true }
        guard await prompting({ await authenticate("show your saved passwords") }) else { return false }
        isUnlocked = true
        touch()
        return true
    }

    /// Asks again even while unlocked, before passwords leave Early.
    func confirm(_ reason: String) async -> Bool {
        guard await prompting({ await authenticate(reason) }) else { return false }
        touch()
        return true
    }

    /// Any use keeps Passwords open for another five minutes.
    func touch() {
        relock?.cancel()
        relock = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.timeout) } catch { return }
            self?.lock()
        }
    }

    func lock() {
        relock?.cancel()
        relock = nil
        if isUnlocked { isUnlocked = false }
    }

    /// Touch ID, or the Mac's login password without it. A Mac without a
    /// login password has nothing to ask for.
    nonisolated static func deviceOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}

/// Settings › Passwords: the profile's saved passwords, behind the lock.
struct PasswordsSettingsSection: View {
    @Bindable var application: EarlyAppDelegate
    @Bindable var preferences: BrowserPreferences
    @Bindable var lock: PasswordsLock
    @State private var expanded: UUID?
    @State private var revealed: Set<UUID> = []
    @State private var editor: PasswordEditorRequest?
    @State private var deleting: SavedLogin?
    @State private var resetting = false
    @State private var notice: PasswordNotice?
    @State private var unlocking = false

    private var profileID: UUID? {
        let profiles = application.profiles
        if let id = application.passwordsProfileID, profiles.contains(where: { $0.id == id }) { return id }
        return application.workspace?.activeProfileID ?? profiles.first?.id
    }

    private var vault: PasswordVault? { profileID.flatMap { application.passwords(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsToggle("Fill passwords automatically",
                               detail: "When a sign-in page you’ve saved a password for opens, Early fills it in. Turn this off to choose from the list under the field instead.",
                               isOn: $preferences.fillsPasswordsAutomatically, identifier: "settings.fillPasswords")
            }
            if application.profiles.count > 1 { profilePicker }
            if !lock.isUnlocked { lockedCard }
            else if let vault { content(vault) }
        }
        .task(id: "\(lock.isUnlocked) \(profileID?.uuidString ?? "")") {
            guard lock.isUnlocked, let vault else { return }
            // Opening them may ask the Keychain, after each new build of Early.
            await lock.prompting { await vault.load() }
        }
        .onDisappear {
            lock.lock()
            revealed = []
        }
        .onChange(of: lock.isUnlocked) { _, unlocked in
            if !unlocked { revealed = []; editor = nil }
        }
        .sheet(item: $editor) { request in
            PasswordEditorSheet(request: request) { login in
                guard let vault else { return nil }
                lock.touch()
                if let login {
                    switch request {
                    case .new:
                        guard vault.login(origin: login.origin, username: login.username) == nil else {
                            return "A password for this user name on \(login.host) is already saved."
                        }
                        vault.save(origin: login.origin, username: login.username, password: login.password)
                        if !login.note.isEmpty, var saved = vault.login(origin: login.origin, username: login.username) {
                            saved.note = login.note
                            vault.update(saved)
                        }
                    case .edit:
                        guard vault.update(login) else { return "A password for this user name on \(login.host) is already saved." }
                    }
                }
                editor = nil
                return nil
            }
        }
        .alert("Delete the password for \(deleting?.host ?? "this website")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { login in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                vault?.delete([login.id])
                deleting = nil
            }
        } message: { login in
            Text("Early won’t fill “\(login.username.isEmpty ? "this login" : login.username)” on \(login.host) anymore. Your account on the website isn’t changed.")
        }
        .alert("Start over with empty passwords?", isPresented: $resetting) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive) { vault?.resetUnreadable() }
        } message: {
            Text("The unreadable passwords file is kept beside the new one, in case it can be opened again later.")
        }
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
               presenting: notice) { notice in
            if let file = notice.importedFile {
                Button("Keep File", role: .cancel) {}
                Button("Move to Trash") { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in Text(notice.message) }
    }

    private var profilePicker: some View {
        HStack {
            Text("Profile").font(.body.weight(.medium))
            Spacer()
            Picker("Profile", selection: Binding(get: { profileID }, set: {
                application.passwordsProfileID = $0
                expanded = nil
                revealed = []
            })) {
                ForEach(application.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("passwords.profile")
        }
    }

    private var lockedCard: some View {
        SettingsCard {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                Text("Passwords are locked").font(.headline)
                Text("Use Touch ID or enter your Mac’s password to see and change your saved passwords. Filling them in on websites doesn’t need this.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    unlocking = true
                    Task {
                        await lock.unlock()
                        unlocking = false
                    }
                } label: { Text("Unlock").frame(minWidth: 80) }
                .controlSize(.large)
                .disabled(unlocking)
                .accessibilityIdentifier("passwords.unlock")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder private func content(_ vault: PasswordVault) -> some View {
        switch vault.state {
        case .notLoaded, .loading:
            ProgressView("Opening your passwords…").frame(maxWidth: .infinity)
        case .unavailable(let message, let canReset):
            SettingsCard {
                Label("Passwords couldn’t be opened", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Try Again") { Task { await lock.prompting { await vault.load(retry: true) } } }
                    if canReset { Button("Start Over…") { resetting = true } }
                }
            }
        case .ready:
            ready(vault)
        }
    }

    private func ready(_ vault: PasswordVault) -> some View {
        let query = application.passwordSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let logins = vault.logins
            .filter { query.isEmpty || $0.host.lowercased().contains(query) || $0.username.lowercased().contains(query)
                || $0.note.lowercased().contains(query) }
            .sorted { ($0.host, $0.username.lowercased()) < ($1.host, $1.username.lowercased()) }
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                transferCard("Import Passwords", symbol: "square.and.arrow.down",
                             detail: "Add passwords exported as a CSV file from Chrome, Safari, Firefox, 1Password, or Bitwarden.",
                             button: "Import…", identifier: "passwords.import") { importPasswords(into: vault) }
                transferCard("Export Passwords", symbol: "square.and.arrow.up",
                             detail: "Save every password in this profile as a CSV file. Anyone who can open it can read them.",
                             button: "Export…", identifier: "passwords.export") { exportPasswords(from: vault) }
                    .disabled(vault.logins.isEmpty)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Search passwords", text: $application.passwordSearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("passwords.search")
                Button { editor = .new } label: { Label("Add Password", systemImage: "plus") }
                    .accessibilityIdentifier("passwords.add")
            }
            if logins.isEmpty {
                SettingsCard {
                    Text(vault.logins.isEmpty ? "No saved passwords" : "No passwords match “\(application.passwordSearch)”")
                        .font(.headline)
                    if vault.logins.isEmpty {
                        Text("When you sign in to a website, Early offers to save the password. You can also import passwords exported from another browser or password manager.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(logins) { login in row(login, vault: vault) }
                }
            }
            if !vault.neverSaved.isEmpty { neverSavedCard(vault) }
            Text("Passwords are encrypted on this Mac with a key kept in your Keychain. They aren’t synced, and private windows can fill them but never save new ones.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Import or export: what it does and one clear button.
    private func transferCard(_ title: String, symbol: String, detail: String, button: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        SettingsCard {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
            Button(button, action: action).accessibilityIdentifier(identifier)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ login: SavedLogin, vault: PasswordVault) -> some View {
        let isExpanded = expanded == login.id
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                lock.touch()
                withAnimation(.easeOut(duration: 0.15)) { expanded = isExpanded ? nil : login.id }
            } label: {
                HStack(spacing: 12) {
                    PasswordSiteIcon(image: URL(string: login.origin).flatMap { url in
                        profileID.flatMap { application.favicon(for: url, profileID: $0) }
                    }, host: login.host)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(login.host).font(.body.weight(.medium)).lineLimit(1)
                        Text(login.username.isEmpty ? "No user name" : login.username)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .browserKeyboardFocus()
            .accessibilityLabel("\(login.host), \(login.username.isEmpty ? "no user name" : login.username)")
            .accessibilityIdentifier("passwords.row.\(login.id)")
            if isExpanded { details(login, vault: vault) }
        }
        .padding(14)
        .background(.primary.opacity(isExpanded ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(isExpanded ? 0.14 : 0.07)) }
    }

    private func details(_ login: SavedLogin, vault: PasswordVault) -> some View {
        let shown = revealed.contains(login.id)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            detailLine("User name", value: login.username.isEmpty ? "None" : login.username) {
                if !login.username.isEmpty { copyButton("Copy User Name") { Self.copy(login.username, concealed: false) } }
            }
            detailLine("Password", value: shown ? login.password : String(repeating: "•", count: 10), monospaced: shown) {
                Button {
                    lock.touch()
                    if shown { revealed.remove(login.id) } else { revealed.insert(login.id) }
                } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(shown ? "Hide Password" : "Show Password")
                .accessibilityLabel(shown ? "Hide Password" : "Show Password")
                .accessibilityIdentifier("passwords.reveal")
                copyButton("Copy Password") { Self.copy(login.password, concealed: true) }
            }
            detailLine("Website", value: login.origin) { EmptyView() }
            if !login.note.isEmpty { detailLine("Note", value: login.note) { EmptyView() } }
            HStack(spacing: 12) {
                Button("Edit…") { lock.touch(); editor = .edit(login) }
                    .accessibilityIdentifier("passwords.edit")
                Button("Delete…", role: .destructive) { lock.touch(); deleting = login }
                    .accessibilityIdentifier("passwords.delete")
                Spacer()
                if let used = login.lastUsed {
                    Text("Last used \(used.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detailLine<Trailing: View>(_ title: String, value: String, monospaced: Bool = false,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value).font(monospaced ? .callout.monospaced() : .callout).textSelection(.enabled)
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }

    private func copyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            lock.touch()
            action()
        } label: { Image(systemName: "doc.on.doc") }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func neverSavedCard(_ vault: PasswordVault) -> some View {
        SettingsCard {
            Text("Never Saved").font(.headline)
            Text("Early doesn’t offer to save passwords on these websites.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(vault.neverSaved, id: \.self) { origin in
                HStack {
                    Text(URL(string: origin)?.host ?? origin)
                    Spacer()
                    Button("Remove") { lock.touch(); vault.allowSaving(origin) }
                        .accessibilityIdentifier("passwords.never.remove.\(origin)")
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Moving passwords

    /// Copied passwords are marked concealed, so clipboard managers skip them,
    /// and are cleared after a minute and a half unless something replaced them.
    static func copy(_ text: String, concealed: Bool, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if concealed { item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        pasteboard.writeObjects([item])
        guard concealed else { return }
        let change = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }

    private func importPasswords(into vault: PasswordVault) {
        lock.touch()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a passwords file exported from a browser or password manager."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            notice = Self.importFile(url, into: vault)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }

    static func importFile(_ url: URL, into vault: PasswordVault) -> PasswordNotice {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return PasswordNotice(title: "The file couldn’t be read", message: "Choose a CSV file of passwords.")
        }
        guard let parsed = try? PasswordCSV.parse(text) else {
            return PasswordNotice(title: "No passwords found",
                                  message: "This file doesn’t look like passwords exported from a browser or password manager.")
        }
        let summary = vault.importRows(parsed.rows, skipped: parsed.skipped)
        var lines = ["\(summary.added) \(summary.added == 1 ? "password was" : "passwords were") imported."]
        if summary.duplicates > 0 { lines.append("\(summary.duplicates) \(summary.duplicates == 1 ? "was" : "were") already saved.") }
        if summary.conflicts > 0 {
            lines.append("\(summary.conflicts) \(summary.conflicts == 1 ? "differs" : "differ") from a saved password; your saved \(summary.conflicts == 1 ? "one was" : "ones were") kept.")
        }
        if summary.skipped > 0 { lines.append("\(summary.skipped) without a website or password \(summary.skipped == 1 ? "was" : "were") skipped.") }
        lines.append("The file isn’t encrypted. You can move it to the Trash now.")
        return PasswordNotice(title: "Passwords imported", message: lines.joined(separator: " "), importedFile: url)
    }

    private func exportPasswords(from vault: PasswordVault) {
        Task {
            guard await lock.confirm("export your saved passwords") else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Early Passwords.csv"
            panel.message = "Anyone who can open this file can read your passwords. Delete it once you’ve imported it elsewhere."
            panel.prompt = "Export"
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Data(vault.exportCSV().utf8).write(to: url, options: .atomic)
                } catch {
                    notice = PasswordNotice(title: "The passwords couldn’t be exported", message: error.localizedDescription)
                }
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { completion(panel.runModal()) }
        }
    }
}

struct PasswordNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// An imported file, which can be moved to the Trash.
    var importedFile: URL?
}

enum PasswordEditorRequest: Identifiable {
    case new, edit(SavedLogin)
    var id: String {
        switch self { case .new: "new"; case .edit(let login): login.id.uuidString }
    }
}

/// Adds or edits a login. Its website must be a web address.
struct PasswordEditorSheet: View {
    let request: PasswordEditorRequest
    /// Returns an error to show, or nil when done; nil cancels.
    let finish: (SavedLogin?) -> String?
    @State private var website: String
    @State private var username: String
    @State private var password: String
    @State private var note: String
    @State private var showsPassword = false
    @State private var error: String?

    init(request: PasswordEditorRequest, finish: @escaping (SavedLogin?) -> String?) {
        self.request = request
        self.finish = finish
        var login: SavedLogin?
        if case .edit(let saved) = request { login = saved }
        _website = State(initialValue: login?.origin ?? "")
        _username = State(initialValue: login?.username ?? "")
        _password = State(initialValue: login?.password ?? "")
        _note = State(initialValue: login?.note ?? "")
    }

    static func origin(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed).flatMap(SitePermissions.origin(of:))
    }

    private var title: String {
        if case .new = request { return "Add Password" }
        return "Edit Password"
    }

    var body: some View {
        let origin = Self.origin(website)
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Website").foregroundStyle(.secondary)
                    TextField("example.com", text: $website).accessibilityIdentifier("passwordEditor.website")
                }
                GridRow {
                    Text("User name").foregroundStyle(.secondary)
                    TextField("Optional", text: $username).accessibilityIdentifier("passwordEditor.username")
                }
                GridRow {
                    Text("Password").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Group {
                            if showsPassword { TextField("Required", text: $password).font(.body.monospaced()) }
                            else { SecureField("Required", text: $password) }
                        }
                        .accessibilityIdentifier("passwordEditor.password")
                        Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .help(showsPassword ? "Hide Password" : "Show Password")
                            .accessibilityLabel(showsPassword ? "Hide Password" : "Show Password")
                        Button {
                            password = PasswordGenerator.strongPassword()
                            showsPassword = true
                        } label: { Image(systemName: "key.horizontal") }
                        .buttonStyle(.borderless)
                        .help("Use a Strong Password")
                        .accessibilityLabel("Use a Strong Password")
                    }
                }
                GridRow(alignment: .top) {
                    Text("Note").foregroundStyle(.secondary)
                    TextField("Optional", text: $note, axis: .vertical).lineLimit(2...5)
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            else if !website.isEmpty && origin == nil {
                Text("Enter a website address, such as example.com.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { _ = finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let origin else { return }
                    var login: SavedLogin
                    if case .edit(let saved) = request { login = saved } else { login = SavedLogin(origin: origin, username: "", password: "") }
                    login.origin = origin
                    login.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    login.password = password
                    login.note = note
                    error = finish(login)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(origin == nil || password.isEmpty)
                .accessibilityIdentifier("passwordEditor.save")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private extension View {
    /// The offer's buttons, shaped like Site Controls' Copy Link.
    func offerButton(_ fill: Color) -> some View {
        font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).frame(height: 26)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A site's icon, or its first letter until Early has one.
struct PasswordSiteIcon: View {
    let image: NSImage?
    let host: String

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 18, height: 18)
            } else {
                Text(host.trimmingPrefix("www.").first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// Offers to save a sign-in that just worked, or to update a changed
/// password, in the page's top corner. Nothing is saved until chosen.
struct PasswordOfferCard: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    let offer: PasswordOffer
    @State private var username: String
    @State private var showsPassword = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: BrowserWindowModel, tabID: UUID, offer: PasswordOffer) {
        self.model = model
        self.tabID = tabID
        self.offer = offer
        _username = State(initialValue: offer.username)
    }

    var body: some View {
        let tint = model.chromeTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(tint).accessibilityHidden(true)
                Text(offer.isUpdate ? "Update the password for \(offer.host)?" : "Save the password for \(offer.host)?")
                    .font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.webViews.dismissPasswordOffer(in: tabID) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Not Now").accessibilityLabel("Not Now")
            }
            VStack(alignment: .leading, spacing: 6) {
                if offer.isUpdate {
                    Text(offer.username.isEmpty ? "No user name" : offer.username).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    TextField("User name", text: $username).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .accessibilityIdentifier("passwordOffer.username")
                }
                HStack(spacing: 6) {
                    Text(showsPassword ? offer.password : String(repeating: "•", count: min(max(offer.password.count, 6), 14)))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(showsPassword ? "Hide Password" : "Show Password")
                        .accessibilityLabel(showsPassword ? "Hide Password" : "Show Password")
                }
            }
            HStack(spacing: 8) {
                if !offer.isUpdate {
                    Button("Never for This Site") { model.webViews.neverSavePasswords(in: tabID) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("passwordOffer.never")
                }
                Spacer(minLength: 0)
                Button { model.webViews.dismissPasswordOffer(in: tabID) } label: {
                    Text("Not Now").offerButton(Color.primary.opacity(0.08))
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus(cornerRadius: 7)
                .accessibilityIdentifier("passwordOffer.notNow")
                Button {
                    model.webViews.acceptPasswordOffer(in: tabID, username: username.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text(offer.isUpdate ? "Update" : "Save").fontWeight(.semibold).foregroundStyle(tint)
                        .offerButton(tint.opacity(0.22))
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus(cornerRadius: 7)
                .accessibilityIdentifier("passwordOffer.save")
            }
        }
        .padding(14)
        .frame(width: 300)
        .modifier(PageToolSurface(theme: model.chromeTheme, allowsTransparency: model.preferences.translucentChrome))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(offer.isUpdate ? "Update Password" : "Save Password")
        .accessibilityIdentifier("passwordOffer")
    }
}
