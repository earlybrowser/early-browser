// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import Observation
import SwiftUI
import WebKit

/// A fetched list and every removal belong to one profile and one request.
/// Generic records let controller tests finish requests in any order without
/// relying on WebKit to manufacture a particular website's stored data.
@MainActor @Observable final class ProfileWebsiteData<Record> {
    struct Snapshot {
        let id: UUID
        let profile: UUID
        let records: [Record]
    }
    private(set) var profile: UUID?
    private(set) var snapshot: Snapshot?
    private(set) var isLoading = false
    private(set) var isRemoving = false
    private var generation = UUID()

    func select(_ profile: UUID?) {
        guard self.profile != profile else { return }
        invalidate()
        self.profile = profile
    }

    func invalidate() {
        generation = UUID()
        profile = nil
        snapshot = nil
        isLoading = false
        isRemoving = false
    }

    func records(for profile: UUID) -> Snapshot? {
        guard self.profile == profile, snapshot?.profile == profile, !isLoading, !isRemoving else { return nil }
        return snapshot
    }

    func load(for profile: UUID?, fetch: @MainActor (UUID) async -> [Record]) async {
        guard self.profile != profile || !isRemoving else { return }
        select(profile)
        guard let profile else { return }
        let request = UUID()
        generation = request
        snapshot = nil
        isLoading = true
        isRemoving = false
        let records = await fetch(profile)
        guard generation == request, self.profile == profile else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        snapshot = Snapshot(id: request, profile: profile, records: records)
    }

    func remove(_ records: [Record], from source: Snapshot,
                using remove: @MainActor ([Record], UUID) async -> Void, fetch: @MainActor (UUID) async -> [Record]) async {
        guard let current = self.records(for: source.profile), current.id == source.id, !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        snapshot = nil
        isRemoving = true
        await remove(records, source.profile)
        guard generation == request, profile == source.profile else { return }
        isRemoving = false
        guard !Task.isCancelled else { return }
        await load(for: source.profile, fetch: fetch)
    }
}

/// Settings › Privacy, for one profile: the permissions websites were given,
/// the websites that stored data, and clearing history.
struct PrivacySettingsSection: View {
    @Bindable var application: EarlyAppDelegate
    @State private var data = ProfileWebsiteData<WKWebsiteDataRecord>()
    @State private var dataSearch = ""
    @State private var confirmingPermissionsReset = false
    @State private var dataRemoval: ProfileWebsiteData<WKWebsiteDataRecord>.Snapshot?
    @State private var confirmingHistory = false

    private var profileID: UUID? {
        let profiles = application.profiles
        if let id = application.privacyProfileID, profiles.contains(where: { $0.id == id }) { return id }
        return application.workspace?.activeProfileID ?? profiles.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if application.profiles.count > 1 { profilePicker }
            if let profileID {
                permissionsCard(application.sitePermissions(for: profileID))
                websiteDataCard(profileID)
                historyCard(profileID)
            }
            SettingsCard {
                Label(PrivateBrowsing.title, systemImage: "eye.slash").font(.headline)
                Text(PrivateBrowsing.explanation)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: profileID) { await data.load(for: profileID, fetch: fetchRecords) }
        .onChange(of: profileID) {
            data.select(profileID)
            dataRemoval = nil
            confirmingHistory = false
            confirmingPermissionsReset = false
        }
        .onDisappear { data.invalidate(); dataRemoval = nil }
    }

    private var profilePicker: some View {
        HStack {
            Text("Profile").font(.body.weight(.medium))
            Spacer()
            Picker("Profile", selection: Binding(get: { profileID }, set: { application.privacyProfileID = $0 })) {
                ForEach(application.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("privacy.profile")
        }
    }

    // MARK: Permissions

    /// Saved choices, one row per website, in alphabetical order.
    static func permissionRows(_ decisions: [String: [SitePermission: SitePermissionDecision]])
        -> [(origin: String, choices: [(SitePermission, SitePermissionDecision)])] {
        decisions.keys.sorted { host(of: $0) < host(of: $1) }.map { origin in
            (origin, SitePermission.allCases.compactMap { permission in decisions[origin]?[permission].map { (permission, $0) } })
        }
    }

    static func host(of origin: String) -> String { URL(string: origin)?.host ?? origin }

    private func permissionsCard(_ permissions: SitePermissions) -> some View {
        let rows = Self.permissionRows(permissions.decisions)
        return SettingsCard {
            HStack {
                Label("Website permissions", systemImage: "hand.raised").font(.headline)
                Spacer()
                Button("Reset All…") { confirmingPermissionsReset = true }
                    .disabled(rows.isEmpty)
                    .accessibilityIdentifier("privacy.resetPermissions")
            }
            Text("Camera, microphone, location and download choices you made for websites. Downloads are the ones a site starts without your click. Sites ask again once a choice is removed. You can also change them from a site’s controls in the address bar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = permissions.saveError {
                SaveFailureNotice(message: error, compact: true, identifier: "privacy.retrySavePermissions") { permissions.retrySaving() }
            }
            if rows.isEmpty {
                Text("No website has a saved permission.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.origin) { row in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.host(of: row.origin)).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        ForEach(row.choices, id: \.0) { permission, decision in
                            Picker(permission.title, selection: Binding(get: { decision }, set: {
                                permissions.set($0, for: [permission], origin: row.origin)
                            })) {
                                ForEach(SitePermissionDecision.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .fixedSize()
                            .accessibilityIdentifier("privacy.permission.\(permission.rawValue).\(Self.host(of: row.origin))")
                        }
                        Button {
                            permissions.set(.ask, for: SitePermission.allCases, origin: row.origin)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Forget this website’s choices")
                        .accessibilityLabel("Forget \(Self.host(of: row.origin))’s choices")
                    }
                }
            }
        }
        .confirmationDialog("Reset every website’s permissions?", isPresented: $confirmingPermissionsReset) {
            Button("Reset All", role: .destructive) { permissions.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Websites will ask again before using your camera, microphone or location.")
        }
    }

    // MARK: Website data

    private func fetchRecords(_ profileID: UUID) async -> [WKWebsiteDataRecord] {
        await application.websiteData(for: profileID).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// "Cookies, local storage" for a record.
    static func kinds(_ types: Set<String>) -> String {
        var kinds: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { kinds.append("cookies") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases,
                                    WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem]) { kinds.append("stored data") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache,
                                    WKWebsiteDataTypeFetchCache]) { kinds.append("cache") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeServiceWorkerRegistrations]) { kinds.append("offline support") }
        let text = kinds.isEmpty ? "website data" : kinds.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func websiteDataCard(_ profileID: UUID) -> some View {
        let snapshot = data.records(for: profileID)
        let records = snapshot?.records ?? []
        let loadingData = data.profile != profileID || data.isLoading || data.isRemoving
        let query = dataSearch.trimmingCharacters(in: .whitespaces)
        let shown = records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
        return SettingsCard {
            HStack {
                Label("Website data", systemImage: "externaldrive").font(.headline)
                Spacer()
                if loadingData { ProgressView().controlSize(.small) }
                Button("Remove All…") { dataRemoval = snapshot }
                    .disabled(records.isEmpty || loadingData)
                    .accessibilityIdentifier("privacy.removeAllData")
            }
            Text("Websites that stored cookies, data or a cache in this profile. Removing a website signs you out of it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if records.count > 6 {
                TextField("Search websites", text: $dataSearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("privacy.dataSearch")
            }
            if shown.isEmpty, !loadingData {
                Text(records.isEmpty ? "No website has stored data." : "No websites match “\(dataSearch)”")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown, id: \.displayName) { record in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.displayName).lineLimit(1)
                                    Text(Self.kinds(record.dataTypes)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Remove") {
                                    guard let snapshot else { return }
                                    Task {
                                        await data.remove([record], from: snapshot, using: application.removeWebsiteData, fetch: fetchRecords)
                                    }
                                }
                                .accessibilityIdentifier("privacy.removeData.\(record.displayName)")
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .confirmationDialog("Remove all website data in this profile?",
                            isPresented: Binding(get: { dataRemoval != nil }, set: { if !$0 { dataRemoval = nil } }),
                            presenting: dataRemoval) { source in
            Button("Remove All", role: .destructive) {
                Task {
                    await data.remove(source.records, from: source, using: application.removeWebsiteData, fetch: fetchRecords)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You’ll be signed out of websites in this profile. History, passwords and downloaded files aren’t removed.")
        }
    }

    // MARK: History

    private func historyCard(_ profileID: UUID) -> some View {
        SettingsCard {
            HStack {
                Label("History", systemImage: "clock").font(.headline)
                Spacer()
                Button("Clear History…") { confirmingHistory = true }
                    .disabled(application.historyRemoval(for: profileID).isWorking)
                    .accessibilityIdentifier("privacy.clearHistory")
            }
            Text(ClearHistoryButtons.message)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HistoryRemovalNotice(removal: application.historyRemoval(for: profileID))
        }
        .confirmationDialog("Clear history and website data?", isPresented: $confirmingHistory) {
            ForEach(HistoryClearRange.allCases) { range in
                Button("Clear \(range.title)", role: range == .all ? .destructive : nil) {
                    Task {
                        await application.clearHistory(range, profile: profileID)
                        if self.profileID == profileID { await data.load(for: profileID, fetch: fetchRecords) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ClearHistoryButtons.message)
        }
    }
}
