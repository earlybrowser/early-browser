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

    var body: some View {
        SettingsCard {
            Label("Export and import", systemImage: "square.and.arrow.up.on.square").font(.headline)
            Text("Save your profiles, Spaces, folders, pins, Favorites, windows and open tabs, with your settings, to a file you can import on another Mac or keep as a copy. Passwords, cookies, history, website data and private windows are never included.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("The file lists the websites in your tabs, so keep it somewhere private.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Export…", action: export)
                    .disabled(application.workspace == nil)
                    .accessibilityIdentifier("settings.exportState")
                Button("Import…", action: chooseFile)
                    .disabled(!application.canEditProfiles)
                    .accessibilityIdentifier("settings.importState")
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
    }

    static func fileName(on date: Date = Date()) -> String {
        "Early \(date.formatted(.iso8601.year().month().day())).json"
    }

    private func export() {
        guard let data = try? application.stateArchive()?.encoded() else {
            outcome = .init(message: "Early couldn’t prepare an export. Try again in a moment.", succeeded: false)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "The file lists the websites in your tabs. Passwords and cookies aren’t included."
        present(panel) { url in
            do {
                try data.write(to: url, options: .atomic)
                outcome = .init(message: "Exported to “\(url.lastPathComponent)”.", succeeded: true)
            } catch {
                outcome = .init(message: "Couldn’t export. \(error.localizedDescription)", succeeded: false)
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
            do {
                preview = StateImportPreview(archive: try application.readStateArchive(at: url), fileName: url.lastPathComponent)
                outcome = nil
            } catch {
                outcome = .init(message: (error as? EarlyStateArchive.Problem ?? .notAnArchive).message, succeeded: false)
            }
        }
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
    @State private var importing = false

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
            Text(mode == .addProfiles
                 ? "Each profile is added beside yours. Nothing you have now changes."
                 : "A profile that’s already here, or has the same name, gets the file’s Spaces, tabs and windows instead of its own, and keeps its passwords and website data. Other profiles are added.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if preview.archive.settings != nil {
                Toggle("Also use the file’s settings, such as the search engine, shortcuts and appearance", isOn: $includeSettings)
                    .accessibilityIdentifier("import.settings")
            }
            Text("Tabs don’t load until you choose them, and websites will ask you to sign in again, because cookies and passwords aren’t in the file. Early saves a backup of what you have now before importing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if importing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    importing = true
                    Task {
                        let outcome = await application.importState(preview.archive, mode: mode, includeSettings: includeSettings)
                        importing = false
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
