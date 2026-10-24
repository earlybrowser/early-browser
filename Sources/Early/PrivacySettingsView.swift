// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI
import WebKit

/// Settings › Privacy, for one profile: the permissions websites were given,
/// the websites that stored data, and clearing history.
struct PrivacySettingsSection: View {
    @Bindable var application: EarlyAppDelegate
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var loadingData = false
    @State private var dataSearch = ""
    @State private var confirmingPermissionsReset = false
    @State private var confirmingDataRemoval = false
    @State private var confirmingHistory = false
    @State private var dataRevision = 0

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
        .task(id: "\(profileID?.uuidString ?? "") \(dataRevision)") { await loadRecords() }
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
            Text("Camera, microphone and location choices you made for websites. Sites ask again once a choice is removed. You can also change them from a site’s controls in the address bar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private func loadRecords() async {
        guard let profileID else { return }
        loadingData = true
        records = await application.websiteData(for: profileID).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        loadingData = false
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
        let query = dataSearch.trimmingCharacters(in: .whitespaces)
        let shown = records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
        return SettingsCard {
            HStack {
                Label("Website data", systemImage: "externaldrive").font(.headline)
                Spacer()
                if loadingData { ProgressView().controlSize(.small) }
                Button("Remove All…") { confirmingDataRemoval = true }
                    .disabled(records.isEmpty)
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
                                    Task {
                                        await application.removeWebsiteData([record], profile: profileID)
                                        dataRevision += 1
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
        .confirmationDialog("Remove all website data in this profile?", isPresented: $confirmingDataRemoval) {
            Button("Remove All", role: .destructive) {
                Task {
                    await application.removeWebsiteData(records, profile: profileID)
                    dataRevision += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
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
                    .accessibilityIdentifier("privacy.clearHistory")
            }
            Text(ClearHistoryButtons.message)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Clear history and website data?", isPresented: $confirmingHistory) {
            ForEach(HistoryClearRange.allCases) { range in
                Button("Clear \(range.title)", role: range == .all ? .destructive : nil) {
                    Task {
                        await application.clearHistory(range, profile: profileID)
                        dataRevision += 1
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ClearHistoryButtons.message)
        }
    }
}
