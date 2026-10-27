// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

/// Profile choices are shared by their Spaces. Collections have separate,
/// explicit routing so a file never masquerades as a browser profile.
struct BrowserImportDestinations: View {
    let document: BrowserImportDocument
    let selected: Set<String>
    let workspace: BrowserWorkspace?
    @Binding var destinations: [String: BrowserImportDestination]
    @Binding var collectionTargets: [String: Set<String>]
    private let profiles: [BrowserImportNode]
    private let byID: [String: BrowserImportNode]
    private let allGroups: [BrowserImportNode]
    private let groupOwners: [String: String]
    private let selectedGroups: [String: [BrowserImportNode]]
    private let collections: [BrowserImportCollection]
    private let foldersByCollection: [String: [BrowserImportNode]]

    init(document: BrowserImportDocument, selected: Set<String>, workspace: BrowserWorkspace?,
         destinations: Binding<[String: BrowserImportDestination]>, collectionTargets: Binding<[String: Set<String>]>) {
        self.document = document; self.selected = selected; self.workspace = workspace
        _destinations = destinations; _collectionTargets = collectionTargets
        profiles = document.nodes.filter { $0.kind == .profile }
        let index = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        byID = index
        allGroups = document.destinationGroups
        var owners: [String: String] = [:]
        for group in allGroups {
            var current: BrowserImportNode? = group
            while let node = current {
                if node.kind == .profile { owners[group.id] = node.id; break }
                current = node.parentID.flatMap { index[$0] }
            }
        }
        groupOwners = owners
        selectedGroups = Dictionary(grouping: document.destinationGroups(selecting: selected), by: { owners[$0.id] ?? "" })
        collections = document.selectedCollections(selected)
        foldersByCollection = document.collectionFolders(selecting: selected)
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Keep website contexts separate, or explicitly combine them. Combined destinations will share future website sign-ins. Passwords use their separate import.")
                .font(.callout).foregroundStyle(.secondary)
            if document.source == "Safari" {
                Text("Profile names are suggested from filenames. Confirm their names, and combine files only when they belong to the same profile.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(collections) { collection in
                VStack(alignment: .leading, spacing: 8) {
                    Text(byID[collection.id]?.title ?? "Shared data").font(.headline)
                    Text(collection.explanation).font(.callout).foregroundStyle(.secondary)
                    if collection.allowsCopies {
                        ForEach(profiles.filter { collection.profileIDs.contains($0.id) }) { profile in
                            Toggle(destinationName(profile), isOn: Binding(get: {
                                (collectionTargets[collection.id] ?? collection.defaultProfileIDs).contains(profile.id)
                            }, set: { checked in
                                var targets = collectionTargets[collection.id] ?? collection.defaultProfileIDs
                                if checked { targets.insert(profile.id) } else { targets.remove(profile.id) }
                                collectionTargets[collection.id] = targets
                            })).toggleStyle(.checkbox)
                                .accessibilityIdentifier("browserImport.collection.\(collection.id).\(profile.id)")
                        }
                    } else {
                        Picker("History destination", selection: Binding(get: {
                            (collectionTargets[collection.id] ?? collection.defaultProfileIDs).first ?? ""
                        }, set: { collectionTargets[collection.id] = $0.isEmpty ? [] : [$0] })) {
                            Text("Choose a destination…").tag("")
                            ForEach(profiles.filter { collection.profileIDs.contains($0.id) }) { Text(destinationName($0)).tag($0.id) }
                        }.accessibilityIdentifier("browserImport.collection.\(collection.id)")
                    }
                    if collection.allowsCopies, let folders = foldersByCollection[collection.id], !folders.isEmpty {
                        DisclosureGroup("Choose destinations for individual folders") {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(folders) { folder in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(folderPath(folder, collection: collection)).font(.callout.weight(.medium))
                                        Toggle("Use inherited destinations", isOn: Binding(get: { collectionTargets[folder.id] == nil }, set: { inherited in
                                            collectionTargets[folder.id] = inherited ? nil : inheritedTargets(folder, collection: collection)
                                        })).toggleStyle(.checkbox)
                                        if collectionTargets[folder.id] != nil {
                                            ForEach(profiles.filter { collection.profileIDs.contains($0.id) }) { profile in
                                                Toggle(destinationName(profile), isOn: Binding(get: { collectionTargets[folder.id]?.contains(profile.id) == true }, set: { checked in
                                                    if checked { collectionTargets[folder.id, default: []].insert(profile.id) }
                                                    else { collectionTargets[folder.id]?.remove(profile.id) }
                                                })).toggleStyle(.checkbox)
                                                    .accessibilityIdentifier("browserImport.folderDestination.\(folder.id).\(profile.id)")
                                            }
                                        }
                                    }
                                }
                            }.padding(.top, 8)
                        }
                    }
                    Text("Copies are independent after import.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(profiles) { profile in
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.title).font(.headline)
                    if let detail = profile.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    Picker("Early profile", selection: Binding(get: { profileChoice(profile.id) }, set: { chooseProfile($0, for: profile.id) })) {
                        Text("Create a separate profile").tag("new")
                        ForEach(workspace?.profiles ?? []) { Text("Use \($0.name)").tag("existing:" + $0.id.uuidString) }
                        ForEach(profiles.filter { $0.id != profile.id && destinations[$0.id]?.profileID == nil && destinations[$0.id]?.newProfileGroup == nil }) { other in
                            Text("Combine with new \(destinations[other.id]?.profileName ?? other.title) (\(other.detail ?? sourceName(other)))").tag("source:" + other.id)
                        }
                    }.accessibilityIdentifier("browserImport.destinationProfile.\(profile.id)")
                    if destinations[profile.id]?.profileID == nil && destinations[profile.id]?.newProfileGroup == nil {
                        TextField("New profile name", text: Binding(get: { destinations[profile.id]?.profileName ?? profile.title }, set: { name in
                            updateProfile(profile.id) { $0.profileName = String(name.prefix(64)) }
                        })).accessibilityIdentifier("browserImport.profileName.\(profile.id)")
                    }
                    ForEach(groups(for: profile)) { group in
                        if group.kind == .space { Text(group.title).font(.callout.weight(.medium)) }
                        Picker("Space", selection: Binding(get: { destinations[group.id]?.spaceID }, set: { destinations[group.id]?.spaceID = $0 })) {
                            Text("Create a new Space").tag(UUID?.none)
                            if let id = destinations[group.id]?.profileID, let session = workspace?.session(for: id) {
                                ForEach(session.spaces) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        if destinations[group.id]?.spaceID == nil {
                            TextField("New Space name", text: Binding(get: { destinations[group.id]?.spaceName ?? "Personal" }, set: {
                                destinations[group.id]?.spaceName = String($0.prefix(64))
                            }))
                        }
                    }
                }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func destinationName(_ source: BrowserImportNode) -> String {
        let target = destinations[source.id]
        let name = target?.profileID.flatMap { id in workspace?.profiles.first { $0.id == id }?.name } ?? target?.profileName ?? source.title
        let label = sourceName(source)
        return source.title == name ? label : label + " → " + name
    }
    private func sourceName(_ source: BrowserImportNode) -> String {
        guard profiles.contains(where: { $0.id != source.id && $0.title == source.title }) else { return source.title }
        let hint = source.detail ?? "Source \((profiles.firstIndex(where: { $0.id == source.id }) ?? 0) + 1)"
        return source.title + " (" + hint + ")"
    }
    private func groups(for profile: BrowserImportNode) -> [BrowserImportNode] {
        var groups = selectedGroups[profile.id] ?? []
        let receivesCollection = collections.contains { collection in
            (collectionTargets[collection.id] ?? collection.defaultProfileIDs).contains(profile.id)
                || (foldersByCollection[collection.id] ?? []).contains { collectionTargets[$0.id]?.contains(profile.id) == true }
        }
        if receivesCollection, !groups.contains(where: { $0.id == profile.id }) {
            groups.insert(profile, at: 0)
        }
        return groups
    }
    private func folderPath(_ folder: BrowserImportNode, collection: BrowserImportCollection) -> String {
        var path = [folder.title], parent = folder.parentID
        while let id = parent, id != collection.id, let node = byID[id] {
            if node.kind == .folder { path.append(node.title) }; parent = node.parentID
        }
        return path.reversed().joined(separator: " › ")
    }
    private func inheritedTargets(_ folder: BrowserImportNode, collection: BrowserImportCollection) -> Set<String> {
        var parent = folder.parentID
        while let id = parent, id != collection.id {
            if let targets = collectionTargets[id] { return targets }
            parent = byID[id]?.parentID
        }
        return collectionTargets[collection.id] ?? collection.defaultProfileIDs
    }
    private func profileChoice(_ id: String) -> String {
        if let profile = destinations[id]?.profileID { return "existing:" + profile.uuidString }
        if let group = destinations[id]?.newProfileGroup { return "source:" + group }
        return "new"
    }
    private func updateProfile(_ id: String, _ change: (inout BrowserImportDestination) -> Void) {
        let affected = Set([id] + profiles.filter { destinations[$0.id]?.newProfileGroup == id }.map(\.id))
        for group in allGroups where groupOwners[group.id].map({ affected.contains($0) }) == true {
            if var value = destinations[group.id] { change(&value); destinations[group.id] = value }
        }
    }
    private func chooseProfile(_ choice: String, for id: String) {
        let previousName = destinations[id]?.profileName ?? "Imported"
        let existing = choice.hasPrefix("existing:") ? UUID(uuidString: String(choice.dropFirst(9))) : nil
        let alias = choice.hasPrefix("source:") ? String(choice.dropFirst(7)) : nil
        let name = alias.flatMap { destinations[$0]?.profileName } ?? previousName
        updateProfile(id) { value in
            value.profileID = existing; value.newProfileGroup = alias; value.profileName = name; value.spaceID = nil
        }
    }
}
