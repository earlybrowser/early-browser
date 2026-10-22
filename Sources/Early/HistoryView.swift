// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

/// Show All History: this profile's visits by day, searchable, with deletion.
/// Opening a visit adds a Today tab; nothing here changes saved pages.
struct HistoryView: View {
    @Bindable var model: BrowserWindowModel
    @State private var query = ""
    @State private var visits: [HistoryVisit] = []
    @State private var selection = Set<Int64>()
    @State private var reachedEnd = false
    @State private var loading = false

    static let pageSize = 300

    /// Day sections, newest first, each titled Today, Yesterday or a date.
    static func sections(_ visits: [HistoryVisit], now: Date = Date(),
                         calendar: Calendar = .current) -> [(title: String, visits: [HistoryVisit])] {
        var order: [Date] = []
        var groups: [Date: [HistoryVisit]] = [:]
        for visit in visits {
            let day = calendar.startOfDay(for: visit.visitedAt)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(visit)
        }
        return order.map { day in
            let title = calendar.isDate(day, inSameDayAs: now) ? "Today"
                : calendar.isDate(day, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            return (title, groups[day] ?? [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("History").font(.title3.weight(.semibold))
                Spacer()
                TextField("Search History", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .accessibilityIdentifier("history.search")
                Button("Clear History…") { model.clearHistoryPresented = true }
                    .accessibilityIdentifier("history.clear")
                Button("Done") { model.historyPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if visits.isEmpty && !loading {
                ContentUnavailableView(query.isEmpty ? "No History" : "No Results",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(query.isEmpty ? "Pages you visit in this profile appear here." : "No visited pages match “\(query)”."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Self.sections(visits), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.visits) { visit in row(visit).tag(visit.id) }
                        }
                    }
                    if !reachedEnd && !visits.isEmpty {
                        Button("Show Older History") { Task { await load(appending: true) } }
                            .buttonStyle(.link)
                            .disabled(loading)
                    }
                }
                .contextMenu(forSelectionType: Int64.self) { ids in
                    let chosen = visits.filter { ids.contains($0.id) }
                    if let visit = chosen.first, chosen.count == 1 {
                        Button("Open in New Tab") { open([visit]) }
                        Button("Open in New Window") { model.onOpenWindow?(visit.url, visit.title) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(visit.url.absoluteString, forType: .string)
                        }
                        Divider()
                    } else if !chosen.isEmpty {
                        Button("Open \(chosen.count) Pages in New Tabs") { open(chosen) }
                        Divider()
                    }
                    Button("Delete") { delete(ids) }
                    Button("Delete All Visits to This Page") { deletePages(ids) }
                        .disabled(chosen.isEmpty)
                } primaryAction: { ids in
                    open(visits.filter { ids.contains($0.id) })
                }
                .onDeleteCommand { delete(selection) }
                .accessibilityIdentifier("history.list")
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .task(id: query) {
            // Search as you type, after a short pause.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await load(appending: false)
        }
        .onChange(of: model.historyRevision) { Task { await load(appending: false) } }
        .confirmationDialog("Clear history and website data?", isPresented: $model.clearHistoryPresented) {
            ClearHistoryButtons(model: model)
        } message: {
            Text(ClearHistoryButtons.message)
        }
    }

    private func row(_ visit: HistoryVisit) -> some View {
        let title = visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title
        let time = visit.visitedAt.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 10) {
            Group {
                if let icon = model.webViews.favicons.image(for: visit.url) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(visit.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(time)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // One element per visit: the title is read first, then where and when.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(visit.url.absoluteString), \(time)")
        .accessibilityIdentifier("history.visit")
    }

    private func load(appending: Bool) async {
        guard let history = model.history else { return }
        loading = true
        defer { loading = false }
        await model.flushHistory()
        let before = appending ? visits.last?.visitedAt : nil
        let page = (try? await history.visits(matching: query, before: before, limit: Self.pageSize)) ?? []
        if appending {
            let known = Set(visits.map(\.id))
            visits += page.filter { !known.contains($0.id) }
        } else {
            visits = page
            selection = selection.intersection(Set(page.map(\.id)))
        }
        reachedEnd = page.count < Self.pageSize
    }

    private func open(_ chosen: [HistoryVisit]) {
        guard !chosen.isEmpty else { return }
        model.historyPresented = false
        _ = model.openLocations(chosen.map(\.url))
    }

    private func delete(_ ids: Set<Int64>) {
        guard let history = model.history, !ids.isEmpty else { return }
        Task {
            try? await history.deleteVisits(Array(ids))
            selection.subtract(ids)
            await load(appending: false)
        }
    }

    private func deletePages(_ ids: Set<Int64>) {
        guard let history = model.history else { return }
        let urls = Array(Set(visits.filter { ids.contains($0.id) }.map(\.url)))
        Task {
            try? await history.deletePages(urls)
            selection.removeAll()
            await load(appending: false)
        }
    }
}

/// The Clear History choices, shared by the menu command and History.
struct ClearHistoryButtons: View {
    let model: BrowserWindowModel

    static let message = "Removes this profile’s history, cookies and other website data from the chosen period. "
        + "Open tabs stay open, and downloaded files are not deleted."

    var body: some View {
        ForEach(HistoryClearRange.allCases) { range in
            Button("Clear \(range.title)", role: range == .all ? .destructive : nil) {
                Task { await model.clearHistory(range) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }
}

// MARK: Private browsing

/// What private browsing does and does not do, in plain words.
enum PrivateBrowsing {
    static let title = "Private Browsing"
    static let explanation = "Early won’t add the pages you visit in private windows to History, and their cookies "
        + "and website data are erased when you close the last private window. Private browsing doesn’t make you "
        + "anonymous: websites, your network administrator and your internet provider can still see your activity. "
        + "Files you download and pages you save stay on your Mac."
}

/// Shown in an empty private window, below the command bar.
struct PrivateBrowsingNotice: View {
    var body: some View {
        VStack(spacing: 8) {
            Label(PrivateBrowsing.title, systemImage: "theatermasks.fill").font(.headline)
            Text(PrivateBrowsing.explanation)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("private.notice")
    }
}

/// The sidebar's private-window label, with the explanation on request.
struct PrivateBrowsingBadge: View {
    let name: String
    @State private var explained = false

    var body: some View {
        HStack(spacing: 6) {
            Label(name, systemImage: "theatermasks.fill")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Button { explained.toggle() } label: {
                Image(systemName: "info.circle").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .browserKeyboardFocus(cornerRadius: 6)
            .help("About Private Browsing")
            .accessibilityLabel("About Private Browsing")
            .accessibilityIdentifier("private.info")
            .popover(isPresented: $explained, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(PrivateBrowsing.title).font(.headline)
                    Text(PrivateBrowsing.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(width: 300)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("private.badge")
    }
}

/// Early's own light or dark appearance. Private windows draw their chrome
/// dark on the private gray, so their pages read it here, not from the window.
@MainActor @Observable final class ApplicationAppearance {
    static let shared = ApplicationAppearance()
    private(set) var colorScheme: ColorScheme
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let application = NSApplication.shared
        colorScheme = Self.colorScheme(of: application.effectiveAppearance)
        observation = application.observe(\.effectiveAppearance) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    private func update() {
        let next = Self.colorScheme(of: NSApplication.shared.effectiveAppearance)
        if colorScheme != next { colorScheme = next }
    }

    static func colorScheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// Gives a private window the dark appearance its gray chrome needs, in
/// light and dark mode alike, including its menus, popovers and controls.
struct PrivateWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) { view.apply() }

    final class AppearanceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, window.appearance?.name != .darkAqua else { return }
            window.appearance = NSAppearance(named: .darkAqua)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
