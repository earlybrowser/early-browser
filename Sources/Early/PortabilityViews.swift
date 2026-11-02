// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › General: whether links from other apps open in Early.
struct DefaultBrowserCard: View {
    @Bindable var application: EarlyAppDelegate
    @State private var asking = false

    var body: some View {
        SettingsCard {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Default browser").font(.body.weight(.medium))
                    Text(application.isDefaultBrowser ? "Links you open in other apps open in Early."
                         : "Links you open in other apps open in another browser. macOS asks before changing it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if application.isDefaultBrowser {
                    Label("Early is your default", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.defaultBrowser.status")
                } else {
                    Button("Make Default…") {
                        asking = true
                        Task {
                            await application.makeDefaultBrowser()
                            asking = false
                        }
                    }
                    .disabled(asking)
                    .accessibilityIdentifier("settings.defaultBrowser")
                }
            }
        }
        .onAppear { application.refreshDefaultBrowser() }
    }
}

/// A file chosen for import, waiting for the person to confirm.
struct StateImportPreview: Identifiable {
    let id = UUID()
    let archive: EarlyStateArchive
    let fileName: String
}

/// Settings › Sessions: saving Early's state to a file, and bringing one in.
struct StatePortabilityCard: View {
    @Bindable var application: EarlyAppDelegate
    @State private var preview: StateImportPreview?
    @State private var outcome: EarlyAppDelegate.ImportOutcome?
    @State private var transfer: Task<Void, Never>?
    @State private var transferID: UUID?

    var body: some View {
        SettingsCard {
            Label("Export and import", systemImage: "square.and.arrow.up.on.square").font(.headline)
            Text("Save your profiles, Spaces, folders, pins, Favorites, windows and open tabs, with your settings, to a file you can import on another Mac or keep as a copy. Passwords, cookies, history, website data and private windows are never included.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("The file lists the websites in your tabs, so keep it somewhere private.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Export…", action: export)
                    .disabled(application.workspace == nil || transfer != nil)
                    .accessibilityIdentifier("settings.exportState")
                Button("Import…", action: chooseFile)
                    .disabled(!application.canEditProfiles || transfer != nil)
                    .accessibilityIdentifier("settings.importState")
            }
            if transfer != nil {
                HStack {
                    ProgressView("Preparing file…").controlSize(.small)
                    Spacer()
                    Button("Cancel") { cancelTransfer() }.accessibilityIdentifier("settings.cancelStateTransfer")
                }
            }
            if let outcome {
                Text(outcome.message).font(.caption).foregroundStyle(outcome.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.portabilityMessage")
                if let backup = outcome.backup {
                    Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .sheet(item: $preview) { preview in
            StateImportSheet(application: application, preview: preview) { result in
                self.preview = nil
                if let result { outcome = result }
            }
        }
        .onDisappear { cancelTransfer() }
    }

    static func fileName(on date: Date = Date()) -> String {
        "Early \(date.formatted(.iso8601.year().month().day())).json"
    }

    private func export() {
        guard application.workspace != nil else {
            outcome = .init(message: "Early couldn’t prepare an export. Try again in a moment.", succeeded: false)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "The file lists the websites in your tabs. Passwords and cookies aren’t included."
        present(panel) { url in
            let request = UUID()
            transferID = request
            transfer = Task {
                let result: EarlyAppDelegate.ImportOutcome
                do {
                    try await application.exportState(to: url)
                    result = .init(message: "Exported to “\(url.lastPathComponent)”.", succeeded: true)
                } catch is CancellationError { return }
                catch { result = .init(message: "Couldn’t export. \(error.localizedDescription)", succeeded: false) }
                guard transferID == request else { return }
                outcome = result; transfer = nil; transferID = nil
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Review"
        panel.message = "Choose a file exported from Early. You’ll see what it contains before anything changes."
        present(panel) { url in
            let request = UUID()
            transferID = request
            transfer = Task {
                do {
                    let archive = try await application.readStateArchive(at: url)
                    guard transferID == request else { return }
                    preview = StateImportPreview(archive: archive, fileName: url.lastPathComponent)
                    outcome = nil
                } catch is CancellationError { return }
                catch {
                    guard transferID == request else { return }
                    outcome = .init(message: (error as? EarlyStateArchive.Problem ?? .notAnArchive).message, succeeded: false)
                }
                transfer = nil; transferID = nil
            }
        }
    }

    private func cancelTransfer() {
        transfer?.cancel(); transfer = nil; transferID = nil
    }

    private func present(_ panel: NSSavePanel, chosen: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { [weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            chosen(url)
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }
}

/// What an import will do, before it does it.
struct StateImportSheet: View {
    let application: EarlyAppDelegate
    let preview: StateImportPreview
    let onFinish: (EarlyAppDelegate.ImportOutcome?) -> Void
    @State private var mode: EarlyStateArchive.ImportMode = .addProfiles
    @State private var includeSettings = true
    /// Off unless the person turns it on: passwords, privacy and updates.
    @State private var includeSensitive = false
    @State private var importing = false
    @State private var committing = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?

    var body: some View {
        let summaries = preview.archive.summary(against: application.workspace ?? BrowserWorkspace())
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import “\(preview.fileName)”?").font(.title3.weight(.semibold))
                Text("Exported \(preview.archive.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summaries) { profile in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.body.weight(.medium))
                            Text(Self.contents(profile)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Self.result(profile, mode: mode)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Picker("Profiles", selection: $mode) {
                Text("Add as new profiles").tag(EarlyStateArchive.ImportMode.addProfiles)
                Text("Replace matching profiles").tag(EarlyStateArchive.ImportMode.replaceMatching)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("import.mode")
            .disabled(importing)
            Text(mode == .addProfiles
                 ? "Each profile is added beside yours. Nothing you have now changes."
                 : "A profile that’s already here, or has the same name, gets the file’s Spaces, tabs and windows instead of its own, and keeps its passwords and website data. Other profiles are added.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let settings = preview.archive.settings {
                Toggle("Also use the file’s settings, such as the search engine, shortcuts and appearance", isOn: $includeSettings)
                    .accessibilityIdentifier("import.settings")
                    .disabled(importing)
                let changes = application.sensitiveImportChanges(from: settings)
                if includeSettings, !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Also change these password, privacy and update settings", isOn: $includeSensitive)
                            .accessibilityIdentifier("import.sensitiveSettings")
                            .disabled(importing)
                        ForEach(changes, id: \.title) { change in
                            Text("\(change.title): \(change.value ? "On" : "Off")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            Text("Tabs don’t load until you choose them, and websites will ask you to sign in again, because cookies and passwords aren’t in the file. Early saves a backup of what you have now before importing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    operationID = nil; operation?.cancel(); operation = nil
                    onFinish(nil)
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(committing)
                    .accessibilityIdentifier("import.cancel")
                Button("Import") {
                    importing = true
                    let request = UUID()
                    operationID = request
                    operation = Task {
                        let outcome = await application.importState(preview.archive, mode: mode, includeSettings: includeSettings,
                                                                    includeSensitiveSettings: includeSensitive,
                                                                    onCommitting: { committing = true })
                        guard operationID == request else { return }
                        importing = false; operation = nil; operationID = nil
                        onFinish(outcome)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importing || !application.canEditProfiles)
                .accessibilityIdentifier("import.confirm")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onDisappear { operationID = nil; operation?.cancel() }
        .interactiveDismissDisabled(importing)
    }

    static func contents(_ profile: EarlyStateArchive.ProfileSummary) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String? { value == 0 ? nil : "\(value) \(value == 1 ? one : many)" }
        let parts = [count(profile.spaces, "Space", "Spaces"), count(profile.favorites, "Favorite", "Favorites"),
                     count(profile.pins, "pin", "pins"), count(profile.folders, "folder", "folders"),
                     count(profile.openTabs, "open tab", "open tabs"), profile.windows > 1 ? "\(profile.windows) windows" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    static func result(_ profile: EarlyStateArchive.ProfileSummary, mode: EarlyStateArchive.ImportMode) -> String {
        if mode == .replaceMatching, let match = profile.match { return "Replaces \(match.name)" }
        return "New profile"
    }
}
