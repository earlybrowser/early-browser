// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI
import UniformTypeIdentifiers

struct BrowserImportCard: View {
    @Bindable var application: EarlyAppDelegate
    @State private var outcome: EarlyAppDelegate.ImportOutcome?
    @State private var undoing: UUID?
    @State private var confirmation: BrowserImportBatch?
    @State private var conflicts: [String] = []
    var body: some View {
        SettingsCard {
            Label("Bring your browser", systemImage: "square.and.arrow.down").font(.headline)
            Text("Choose bookmarks and browser organization, review their destinations, then import only what you want. Passwords use their separate CSV import in Passwords.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Import from Another Browser…") { application.showBrowserImport() }
                .disabled(!application.canEditProfiles).accessibilityIdentifier("settings.browserImport")
            if let error = application.browserImportError { Text(error).foregroundStyle(.red).font(.caption) }
            if let outcome { Text(outcome.message).font(.callout).foregroundStyle(outcome.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)) }
            ForEach(application.browserImportBatches) { batch in
                HStack {
                    VStack(alignment: .leading) {
                        Text(batch.source).font(.callout.weight(.medium))
                        Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(undoing == batch.id ? "Undoing…" : "Undo Import") {
                        guard let snapshot = application.browserImportSnapshot() else { return }
                        let input = application.browserImportValidation()
                        undoing = batch.id
                        Task {
                            do {
                                conflicts = try await Task.detached { try batch.undoConflicts(in: snapshot, using: input) }.value
                                confirmation = batch
                            } catch { outcome = .init(message: error.localizedDescription, succeeded: false) }
                            undoing = nil
                        }
                    }
                        .disabled(undoing != nil || !application.canEditProfiles)
                        .accessibilityIdentifier("browserImport.undo.\(batch.id)")
                }
            }
        }
        .confirmationDialog("Undo this import?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let batch = confirmation {
                Button("Undo Import") {
                    confirmation = nil; undoing = batch.id
                    Task { outcome = await application.undoBrowserImport(batch); undoing = nil }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("Only unchanged imported pages, empty imported folders, and visits from this import are removed. Edited or used pages, later additions, profiles, passwords and website data are kept.")
            if !conflicts.isEmpty {
                Text("\(conflicts.count) items will be kept:\n" + conflicts.prefix(6).joined(separator: "\n") + (conflicts.count > 6 ? "\n…and \(conflicts.count - 6) more." : ""))
            }
        }
    }
}

struct BrowserImportSheet: View {
    @Bindable var application: EarlyAppDelegate
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var document: BrowserImportDocument?
    @State private var tree: BrowserImportTree?
    @State private var selected = Set<String>()
    @State private var expanded = Set<String>()
    @State private var search = ""
    @State private var destinations: [String: BrowserImportDestination] = [:]
    @State private var rows: [BrowserImportTree.Row] = []
    @State private var step = 0
    @State private var reading: Task<BrowserImportDocument, Error>?
    @State private var reviewing = false
    @State private var reviewTask: Task<BrowserImportCandidate, Error>?
    @State private var importing = false
    @State private var flatten = false
    @State private var preview: BrowserImportCandidate?
    @State private var message: String?
    @State private var succeeded = false

    static let knownBrowsers: [(String, String)] = [
        ("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome"),
        ("Firefox", "org.mozilla.firefox"), ("Arc", "company.thebrowser.Browser"),
        ("Zen", "app.zen-browser.zen"),
        ("Brave", "com.brave.Browser"), ("Edge", "com.microsoft.edgemac"),
        ("Vivaldi", "com.vivaldi.Vivaldi"), ("Opera", "com.operasoftware.Opera")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(succeeded ? "Import complete" : "Import from Another Browser").font(.title2.weight(.semibold))
            Text("Your browser data stays on this Mac. Early reads only the file or folder you choose.")
                .font(.callout).foregroundStyle(.secondary)
            if document != nil, !succeeded {
                HStack(spacing: 16) {
                    ForEach(Array(["Choose contents", "Destinations", "Review"].enumerated()), id: \.offset) { index, title in
                        Text("\(index + 1). \(title)").font(.callout.weight(step == index ? .semibold : .regular))
                            .foregroundStyle(step == index ? .primary : .secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
            if let document, !succeeded {
                if step == 0 { selection(document) }
                else if step == 1 { destinationView(document) }
                else { reviewView(document) }
            } else if !succeeded { sourceView }
            if let message {
                Text(message).font(.callout).foregroundStyle(succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .textSelection(.enabled).accessibilityIdentifier("browserImport.message")
            }
            Spacer(minLength: 0)
            HStack {
                if reading != nil || reviewing || importing { ProgressView().controlSize(.small) }
                if document != nil && !succeeded && !importing {
                    Button(step == 0 ? "Choose Another Source" : "Back") {
                        message = nil; preview = nil
                        if step == 0 { document = nil; tree = nil } else { step -= 1 }
                    }.disabled(reviewing)
                }
                Spacer()
                Button(succeeded ? "Done" : "Cancel") { reading?.cancel(); reviewTask?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(importing)
                if document != nil, !succeeded {
                    Button(step == 2 ? "Import Selected Items" : step == 1 ? "Review" : "Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(importing || reviewing || selectedContentCount == 0)
                        .accessibilityIdentifier("browserImport.continue")
                }
            }
        }
        .padding(24).frame(width: 740, height: 650)
        .interactiveDismissDisabled(importing)
        .accessibilityIdentifier("browserImport.wizard")
        .onDisappear { reading?.cancel(); reviewTask?.cancel() }
        .onChange(of: search) { _, _ in updateRows() }
    }

    private var sourceView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: $source) {
                Text("Choose a browser…").tag("").disabled(true)
                ForEach(Self.knownBrowsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }, id: \.0) { browser in
                    Text(browser.0).tag(browser.0)
                }
                Text("Other Chromium browser").tag("Other Chromium browser")
                Text("Other Firefox browser").tag("Other Firefox browser")
                Text("Other browser").tag("Other browser")
            }.accessibilityIdentifier("browserImport.source")
            if source.isEmpty {
                Text("Choose the browser you’re importing from.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(exportInstructions)
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("browserImport.exportHelp")
                Button(source == "Arc" ? "Choose Sidebar File…" : source == "Safari" ? "Choose Bookmarks and History…" : chromiumHistoryOnly ? "Choose Bookmarks File…" : "Choose Exported File…") {
                    choose(folder: false)
                }.disabled(reading != nil)
                    .accessibilityIdentifier("browserImport.chooseFile")
                if source != "Safari", source != "Other browser" {
                    Divider()
                    Text(chromiumHistoryOnly ? "Import history from this Mac" : "Or use the browser’s data folder").font(.callout.weight(.medium))
                    Text(folderExplanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("browserImport.folderHelp")
                    Button(chromiumHistoryOnly ? "Choose History Folder…" : "Choose Browser Data Folder…") { choose(folder: true) }
                        .disabled(reading != nil)
                        .accessibilityIdentifier("browserImport.chooseFolder")
                }
                Text(source == "Safari" ? "Only bookmarks and history are imported here. For passwords, use Settings → Passwords." : "You’ll choose what to bring on the next screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var exportInstructions: String {
        switch source {
        case "Safari":
            "In Safari, choose File → Export Browsing Data to File. Export Bookmarks and History, then unzip the file. Select the bookmarks HTML and history JSON together here."
        case "Chrome":
            "Open Chrome’s Bookmark Manager, then choose ⋮ → Export bookmarks. Choose the saved HTML file here."
        case "Arc":
            "For Arc’s sidebar, choose StorableSidebar.json from Library → Application Support → Arc, or use the folder option below."
        case "Firefox", "Zen":
            "In \(source), open Bookmarks → Manage Bookmarks, then click the ↑↓ toolbar button → Export Bookmarks to HTML. Choose the saved file here."
        case "Brave":
            "In Brave, open Bookmarks → Bookmarks Manager, then choose ⋮ → Export. Choose the saved HTML file here."
        case "Edge":
            "In Edge, open Favorites, then choose ⋯ → Export favorites. Choose the saved HTML file here."
        case "Vivaldi":
            "In Vivaldi, choose File → Export Bookmarks. Choose the saved HTML file here."
        case "Opera":
            "Open Opera’s bookmark manager and export your bookmarks as HTML. Choose the saved file here."
        case "Other Firefox browser":
            "Open your browser’s bookmark library, then click the ↑↓ toolbar button → Export Bookmarks to HTML. Choose the saved file here."
        case "Other Chromium browser":
            "Open your browser’s bookmark manager, then choose its menu → Export bookmarks. Choose the saved HTML file here."
        default:
            "Export bookmarks as an HTML file from your browser, then choose the saved file here."
        }
    }

    private var chromiumHistoryOnly: Bool {
        ["Chrome", "Brave", "Edge", "Vivaldi", "Opera", "Other Chromium browser"].contains(source)
    }

    private var folderExplanation: String {
        switch source {
        case "Arc":
            "This folder holds Arc’s Spaces, Favorites, pins and folders. Early reads it without changing anything."
        case "Zen":
            "This folder holds Zen’s workspaces, Essentials, pins and folders. Early reads it without changing anything."
        case "Firefox", "Other Firefox browser":
            "Choose the browser’s saved-data folder to bring bookmarks, history and available tabs. Early reads it without changing anything."
        default:
            "Choose the browser’s saved-data folder to bring history only. Import bookmarks using the exported file above."
        }
    }

    private var selectedContentCount: Int {
        selected.count
    }

    private func selection(_ document: BrowserImportDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if tree?.selectableIDs.isEmpty == true {
                Text("No supported items were found. Choose another source or export bookmarks as HTML.").font(.callout)
                ForEach(document.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                TextField("Search names or addresses", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("browserImport.search")
                Button("Select All") { selected = tree?.selectableIDs ?? []; updateRows() }
                Button("Select None") { selected.removeAll(); updateRows() }
            }
            Text("\(selectedContentCount) items selected. Checking a folder includes its contents; searching does not change selection.")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("browserImport.selectionCount")
            List(rows) { row in
                HStack(spacing: 8) {
                    if row.hasChildren {
                        Button {
                            if !expanded.insert(row.id).inserted { expanded.remove(row.id) }; updateRows()
                        } label: { Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right").font(.caption) }
                            .buttonStyle(.plain).frame(width: 14)
                            .accessibilityLabel("\(expanded.contains(row.id) ? "Collapse" : "Expand") \(row.node.title)")
                    } else { Color.clear.frame(width: 14) }
                    ImportCheckbox(state: row.state, label: row.node.title) {
                        if let tree { selected = tree.toggling(row.id, selected: selected); updateRows() }
                    }.frame(width: 18, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.node.title).lineLimit(1)
                        if let url = row.node.url { Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(label(row.node.kind)).font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, CGFloat(min(row.depth, 12)) * 12)
                    .accessibilityElement(children: .contain)
            }.listStyle(.bordered).accessibilityIdentifier("browserImport.tree")
        }
    }

    private func destinationView(_ document: BrowserImportDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Source profiles remain separate by default. Choose an existing profile only when you intend to combine their website identities.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(document.destinationGroups(selecting: selected)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.headline)
                        Picker("Profile", selection: Binding(get: { destinations[group.id]?.profileID }, set: { id in
                            destinations[group.id]?.profileID = id; destinations[group.id]?.spaceID = nil
                        })) {
                            Text("Create a new profile").tag(UUID?.none)
                            ForEach(application.profiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if destinations[group.id]?.profileID == nil {
                            TextField("New profile name", text: field(group.id, \.profileName))
                                .accessibilityIdentifier("browserImport.profileName.\(group.id)")
                        }
                        Picker("Space", selection: Binding(get: { destinations[group.id]?.spaceID }, set: { destinations[group.id]?.spaceID = $0 })) {
                            Text("Create a new Space").tag(UUID?.none)
                            if let profile = destinations[group.id]?.profileID, let session = application.workspace?.session(for: profile) {
                                ForEach(session.spaces) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        if destinations[group.id]?.spaceID == nil { TextField("New Space name", text: field(group.id, \.spaceName)) }
                    }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                Toggle("Flatten selected folders deeper than eight nested levels", isOn: $flatten)
                Text("Without flattening, any affected branch is identified before importing. You can go back and deselect it. No Imported Bookmarks wrapper folder is added. Today tabs go to one destination window per profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reviewView(_ document: BrowserImportDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let preview {
                    Text("\(preview.batch.tabs.count) pages · \(preview.batch.folders.count) folders · \(preview.history.values.reduce(0) { $0 + $1.count }) known visits").font(.headline)
                    if preview.skippedHistoryCount > 0 { Text("\(preview.skippedHistoryCount) visits outside Early’s retention period or dated in the future are excluded.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(preview.workspace.profiles.filter { profile in
                        preview.batch.tabs.contains { $0.profileID == profile.id } || preview.batch.spaces.contains { $0.profileID == profile.id } || preview.history[profile.id] != nil
                    }) { profile in
                        Text("\(profile.name): \(preview.workspace.session(for: profile.id)?.spaces.filter { space in preview.batch.spaces.contains(space) || preview.batch.tabs.contains { $0.spaceID == space.id } }.map(\.name).joined(separator: ", ") ?? "")")
                    }
                    if !preview.flattened.isEmpty { Text("Flattened branches: \(Array(Set(preview.flattened)).sorted().joined(separator: ", "))").foregroundStyle(.secondary) }
                }
                ForEach(document.notices, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                Text("Existing items keep their order. Intentional URL copies in different folders are preserved. Repeated source visits are skipped and history older than Early’s retention period is not imported. Passwords, cookies, extensions, browser settings and signed-in sessions are excluded.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Early saves a recovery backup first. Pages remain unloaded until selected. Undo Import survives restart and keeps later edits and website data.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("browserImport.review")
    }

    private func field(_ id: String, _ key: WritableKeyPath<BrowserImportDestination, String>) -> Binding<String> {
        Binding(get: { destinations[id]?[keyPath: key] ?? "" }, set: { destinations[id]?[keyPath: key] = String($0.prefix(64)) })
    }
    private func updateRows() { rows = tree?.rows(selected: selected, expanded: expanded, search: search) ?? [] }
    private func label(_ kind: BrowserImportNode.Kind) -> String {
        switch kind {
        case .profile: "Profile"; case .space: "Space"; case .category: "Optional"; case .folder: "Folder"
        case .favorite: "Favorite"; case .pin, .bookmark: "Pin"; case .openTab: "Today"; case .history: "History"
        }
    }
    private func choose(folder: Bool) {
        guard !source.isEmpty else { return }
        let selectedSource = source
        let historyOnly = folder && chromiumHistoryOnly
        let safariFiles = !folder && selectedSource == "Safari"
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = safariFiles
        if safariFiles { panel.allowedContentTypes = [.html, .json] }
        panel.prompt = "Preview"
        panel.message = safariFiles ? "Select Safari’s bookmarks HTML and history JSON files together."
            : folder ? "Choose the folder where your browser saves its data."
            : selectedSource == "Arc" ? "Choose Arc’s saved sidebar file." : "Choose the file you exported from your browser."
        if folder || selectedSource == "Arc" {
            let paths = ["Chrome": "Google/Chrome", "Firefox": "Firefox/Profiles", "Zen": "zen/Profiles", "Arc": "Arc", "Brave": "BraveSoftware/Brave-Browser", "Edge": "Microsoft Edge", "Vivaldi": "Vivaldi", "Opera": "com.operasoftware.Opera"]
            let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            panel.directoryURL = paths[selectedSource].map { support.appendingPathComponent($0) } ?? support
        }
        panel.begin { response in
            let urls = panel.urls
            guard response == .OK, let url = urls.first else { return }
            message = nil
            let name = selectedSource == "Other browser" ? url.deletingPathExtension().lastPathComponent : selectedSource
            let task = Task.detached {
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                if safariFiles { return try BrowserImportFiles.readSafariExports(urls) }
                if historyOnly { return try BrowserImportFiles.readChromiumHistory(url, source: name) }
                return try BrowserImportFiles.read(url, source: name)
            }
            reading = task
            Task {
                do {
                    let value = try await task.value
                    try Task.checkCancellation()
                    document = value; tree = BrowserImportTree(value); selected = value.initiallySelected
                    expanded = Set(value.destinationGroups.map(\.id)); step = 0; search = ""
                    destinations = Dictionary(uniqueKeysWithValues: value.destinationGroups.map { group in
                        var owner = group
                        while owner.kind != .profile, let parent = owner.parentID, let next = value.nodes.first(where: { $0.id == parent }) { owner = next }
                        return (group.id, BrowserImportDestination(profileName: owner.title, spaceName: group.kind == .space ? group.title : "Personal"))
                    })
                    updateRows()
                } catch { if !(error is CancellationError) { message = error.localizedDescription } }
                reading = nil
            }
        }
    }
    private func advance() {
        guard let document else { return }
        message = nil
        if step == 0 { step = 1; return }
        if step == 1 {
            guard let current = application.browserImportSnapshot() else { return }
            reviewing = true
            let selected = selected, destinations = destinations, flatten = flatten
            let validationInput = application.browserImportValidation()
            let task = Task.detached {
                try document.candidate(into: current, selecting: selected, destinations: destinations, flattenDeepFolders: flatten, using: validationInput)
            }
            reviewTask = task
            Task {
                do {
                    preview = try await task.value
                    step = 2
                } catch { message = error.localizedDescription }
                reviewing = false; reviewTask = nil
            }
        } else {
            importing = true
            Task {
                let result = await application.importBrowser(document, selected: selected, destinations: destinations, flatten: flatten)
                message = result.message; succeeded = result.succeeded; importing = false
                if !result.succeeded { step = 1 }
            }
        }
    }
}

/// Native checkboxes expose the mixed state to keyboard navigation and VoiceOver.
private struct ImportCheckbox: NSViewRepresentable {
    let state: BrowserImportTree.CheckState
    let label: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = switch state { case .off: .off; case .mixed: .mixed; case .on: .on }
        button.setAccessibilityLabel(label)
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
