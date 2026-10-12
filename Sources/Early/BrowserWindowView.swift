import AppKit
import EarlyCore
import SwiftUI

struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel
    @State private var sidebarAutoHides = false
    @State private var sidebarHovered = false
    private var sidebarVisible: Bool { !sidebarAutoHides || sidebarHovered }

    private enum SidebarItem: Identifiable {
        case pinnedHeading, divider, newTab
        case tab(BrowserTab)

        var id: String {
            switch self {
            case .pinnedHeading: "pinned-heading"
            case .divider: "divider"
            case .newTab: "new-tab"
            case .tab(let tab): "tab-\(tab.id)"
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        [.pinnedHeading] + model.pinnedTabs.map(SidebarItem.tab)
            + [.divider, .newTab] + model.todayTabs.map(SidebarItem.tab)
    }

    private static let windowCornerRadius: CGFloat = {
        guard let tf = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        ).contentView?.superview else {
            return 16
        }
        let sel = NSSelectorFromString("_getCachedDefaultWindowCornerRadius")
        guard let method = class_getInstanceMethod(type(of: tf), sel) else { return 16 }
        typealias FloatFunc = @convention(c) (AnyObject, Selector) -> CGFloat
        let fn = unsafeBitCast(method_getImplementation(method), to: FloatFunc.self)
        let r = fn(tf, sel)
        return r > 0 ? r : 16
    }()

    /// Root window padding is 6 pt. For the inner content border to be concentric
    /// with the window frame (constant 6 pt distance everywhere, including corner curves):
    private var contentCornerRadius: CGFloat {
        max(Self.windowCornerRadius - 6, 4)
    }

    /// When auto-hiding, the floating sidebar expands by 3 pt (sitting 3 pt from the window edge
    /// and 3 pt outside the content border). For the sidebar to be concentric with both
    /// the window frame (3 pt gap) and the content border (3 pt gap) everywhere around the corner:
    private var sidebarCornerRadius: CGFloat {
        sidebarAutoHides ? max(Self.windowCornerRadius - 3, 4) : contentCornerRadius
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                WebContentView(view: model.activePage?.view, focusRequest: model.contentFocusRequest,
                               canFocus: model.coordinator.commandBar == nil,
                               hasDialog: model.activePage?.hasDialog == true)
                    .accessibilityIdentifier("browser.content")
                if model.coordinator.activeTabID == nil {
                    Text("Open a new tab with ⌘T")
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("browser.emptyContent")
                        .allowsHitTesting(false)
                }
                if let error = model.activePage?.failure {
                    VStack(spacing: 12) {
                        Label("Unable to open this page", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(error).multilineTextAlignment(.center)
                        Button("Try Again") { model.reload() }
                            .accessibilityIdentifier("browser.retry")
                    }
                    .padding(24)
                    .frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("browser.error")
                }
                VStack {
                    if let error = model.persistence.error {
                        Text(error).font(.callout).padding(12)
                            .background(.regularMaterial)
                            .accessibilityIdentifier("browser.persistenceError")
                    }
                    if let notice = model.notice {
                        HStack {
                            Text(notice)
                            Button("Dismiss") { model.notice = nil }
                        }.font(.callout).padding(12).background(.regularMaterial)
                    }
                    if let page = model.activePage, page.isLoading {
                        GeometryReader { geometry in
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geometry.size.width * min(max(page.progress, 0), 1))
                        }
                            .frame(height: 2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Page loading")
                            .accessibilityValue("\(Int(page.progress * 100)) percent")
                            .accessibilityIdentifier("browser.loading")
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: contentCornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.leading, sidebarAutoHides ? 0 : 266)

            sidebar
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: sidebarCornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: sidebarCornerRadius))
                .overlay {
                    if sidebarAutoHides {
                        RoundedRectangle(cornerRadius: sidebarCornerRadius)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .shadow(color: .black.opacity(sidebarAutoHides && sidebarVisible ? 0.15 : 0), radius: 8, x: 3)
                .offset(x: sidebarVisible ? 0 : -280)
                .padding(.leading, sidebarAutoHides ? -3 : 0)
                .padding(.vertical, sidebarAutoHides ? -3 : 0)
                .allowsHitTesting(sidebarVisible)
                .accessibilityHidden(!sidebarVisible)
                .onHover { inside in
                    // Only the window-edge target may reveal a hidden sidebar.
                    // Ignore enter events from the offset sidebar's tracking area.
                    if !inside { sidebarHovered = false }
                }

            if model.coordinator.commandBar != nil {
                ZStack {
                    Color.black.opacity(0.001)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.dismissCommandBar()
                        }
                        .accessibilityHidden(true)
                    CommandBarView(model: model)
                        .padding(32)
                        .padding(.leading, sidebarAutoHides ? 0 : 266)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            if sidebarAutoHides && !sidebarVisible {
                Color.clear
                    .frame(width: 2)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { sidebarHovered = true } }
                    .onTapGesture { sidebarHovered = true }
                    .accessibilityLabel("Reveal sidebar")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("sidebar.reveal")
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            #if DEBUG
            if model.isTesting { TestWindowState().frame(width: 1, height: 1) }
            #endif
        }
        .focusedSceneValue(\.browserWindow, model)
        .sheet(isPresented: Binding(get: { model.renamingTabID != nil }, set: { if !$0 { model.renamingTabID = nil } })) {
            RenameTabSheet(model: model)
        }
        .onAppear { model.activateSelection() }
        .onDisappear { model.save(); model.webViews.discardAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                navigationControls
                addressBar.padding(.horizontal, -4)
            }
            favoritesSection
            Label("Personal", systemImage: "square.stack")
                .font(.headline)
            ScrollView {
                // Pins and Today share a scroll region: many persistent pins
                // must not push Today or New Tab outside the reachable sidebar.
                LazyVStack(alignment: .leading, spacing: 4) {
                    // One identity domain: moving the same UUID between two
                    // sibling ForEach collections can retain a stale lazy row.
                    ForEach(sidebarItems) { item in
                        switch item {
                        case .pinnedHeading:
                            sectionLabel("Pinned")
                                .padding(.bottom, 8)
                                .accessibilityIdentifier("sidebar.pinned.heading")
                        case .divider:
                            Divider().padding(.vertical, 8)
                        case .newTab:
                            newTabButton
                        case .tab(let tab):
                            tabRow(tab)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sidebar.tabs")
            #if DEBUG
            if model.isTesting {
                Text("Tabs \(model.openTabs.count) · Views \(model.webViews.liveViewCount) · Created \(model.webViews.creationCount) · \(model.persistence.isSaving ? "Saving" : "Saved")")
                    .font(.caption2)
                    .accessibilityIdentifier("test.runtime")
            }
            #endif
        }
        .padding(.horizontal, sidebarAutoHides ? 9 : 6)
        .padding(.top, sidebarAutoHides ? 7 : 4)
        .padding(.bottom, sidebarAutoHides ? 17 : 14)
        .frame(width: sidebarAutoHides ? 263 : 260)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("browser.sidebar")
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 4) {
            if tab.pinnedURL != nil {
                PinnedTabIcon(tab: tab, isActive: model.coordinator.activeTabID == tab.id,
                              select: { model.selectTab(tab.id) },
                              reset: { model.resetPinnedTab(tab.id) })
            }
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 8) {
                    if tab.pinnedURL == nil {
                        Image(systemName: "globe").accessibilityHidden(true)
                    }
                    Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tab.isOpen ? .primary : .secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab.\(tab.id)")
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(tab.pinnedURL == nil ? "Today" : (tab.isOpen ? "Pinned, open" : "Pinned, closed"))
            .accessibilityAddTraits(model.coordinator.activeTabID == tab.id ? .isSelected : [])
            .help(tab.pinnedURL.map { "Pinned URL: \($0.absoluteString)\nCurrent URL: \(tab.currentURL.absoluteString)\(tab.isOpen ? "" : "\nClick to reopen")" }
                  ?? tab.currentURL.absoluteString)
            if tab.isOpen {
                Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tabClose.\(tab.id)")
                    .accessibilityLabel("Close \(tab.displayTitle)")
                    .help(tab.pinnedURL == nil ? "Close tab" : "Close page and keep pin")
            }
        }
        .padding(.leading, tab.pinnedURL == nil ? 8 : 0)
        .padding(.trailing, 8)
        .background(Color.primary.opacity(model.coordinator.activeTabID == tab.id ? 0.08 : 0))
        .clipShape(RoundedRectangle(cornerRadius: tab.pinnedURL == nil ? 7 : 10))
        .contextMenu { tabActions(tab) }
    }

    @ViewBuilder
    private func tabActions(_ tab: BrowserTab) -> some View {
        Button("Rename Tab…") { model.requestRename(tab.id) }
        Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            model.setFavorite(tab.id, favorite: !tab.isFavorite)
        }
        if !tab.isFavorite {
            Button(tab.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                model.setPinned(tab.id, pinned: tab.pinnedURL == nil)
            }
        }
        if tab.pinnedURL != nil {
            Button("Reset to Pinned URL") { model.resetPinnedTab(tab.id) }
        }
        Divider()
        Button("Close Tab") { model.closeTab(tab.id) }
            .disabled(!tab.isOpen)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Favorites")
                Spacer()
                Button {
                    if let tab = model.activeTab { model.setFavorite(tab.id, favorite: true) }
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(model.activeTab == nil || model.activeTab?.isFavorite == true)
                .accessibilityIdentifier("favorites.add")
                .accessibilityLabel("Add current tab to Favorites")
                .help("Add current tab to Favorites")
            }
            if !model.favorites.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(model.favorites) { tab in
                            favoriteTile(tab)
                        }
                    }
                }
                // A large collection must not consume all room for space tabs.
                .frame(height: min(CGFloat((model.favorites.count + 3) / 4) * 60 - 6, 174))
                .accessibilityIdentifier("sidebar.favorites")
            }
        }
    }

    private func favoriteTile(_ tab: BrowserTab) -> some View {
        let name = tab.customTitle ?? tab.pinnedTitle ?? tab.pinnedURL?.host ?? tab.title
        let selected = model.coordinator.activeTabID == tab.id
        return Button { model.selectTab(tab.id) } label: {
            VStack(spacing: 3) {
                // Site favicons are a separate sidebar checkpoint. A local
                // monogram avoids external favicon services and network work.
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 19, weight: .semibold))
                Text(name).font(.caption2).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(tab.isOpen ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.primary.opacity(selected ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favorite.\(tab.id)")
        .accessibilityLabel(name)
        .accessibilityValue(tab.isOpen ? "Favorite, open" : "Favorite, closed")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(name)\n\((tab.pinnedURL ?? tab.currentURL).absoluteString)")
        .contextMenu { tabActions(tab) }
    }

    /// Only the active pin exposes Reset. An inactive icon selects/reopens its
    /// tab like the title, without unexpectedly resetting a background page.
    private struct PinnedTabIcon: View {
        let tab: BrowserTab
        let isActive: Bool
        let select: () -> Void
        let reset: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: isActive ? reset : select) {
                Image(systemName: isActive && hovered ? "arrow.uturn.backward" : "pin")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tab.isOpen ? .primary : .secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(isActive ? (hovered ? 0.16 : 0.07) : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityIdentifier("\(isActive ? "pinReset" : "pinSelect").\(tab.id)")
            .accessibilityLabel(isActive ? "Reset \(tab.customTitle ?? tab.pinnedTitle ?? tab.title) to pinned URL" : "Open \(tab.displayTitle)")
            .help(isActive ? "Reset pinned tab" : "Open pinned tab")
        }
    }

    private struct RenameTabSheet: View {
        @Bindable var model: BrowserWindowModel
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Tab").font(.headline)
                TextField("Name", text: $model.renameText)
                    .focused($focused).accessibilityIdentifier("rename.name")
                HStack {
                    Button("Use Page Title") { model.finishRename(usePageTitle: true) }
                    Spacer()
                    Button("Cancel") { model.renamingTabID = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") { model.finishRename() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 380)
            .onAppear { focused = true }
        }
    }

    private var newTabButton: some View {
        Button {
            model.presentCommandBar(.newTab)
        } label: {
            HStack {
                Label("New Tab", systemImage: "plus")
                Spacer()
                Text("⌘T").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.newTab")
        .help("Open the command bar (Command-T)")
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            WindowControls().frame(width: 60, height: 32)
            Button {
                sidebarAutoHides.toggle()
                sidebarHovered = false
            } label: {
                Image(systemName: "sidebar.left").frame(width: 26, height: 32)
            }
            .accessibilityLabel(sidebarAutoHides ? "Keep sidebar visible" : "Auto-hide sidebar")
            .accessibilityValue(sidebarAutoHides ? "Auto-hide enabled" : "Always visible")
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .accessibilityIdentifier("sidebar.toggle")
            .help("Toggle sidebar auto-hide (Command-Shift-S). Reveal at the left edge.")
            Spacer(minLength: 0)
            Button { model.back() } label: { Image(systemName: "arrow.left").frame(width: 26, height: 32) }
                .disabled(model.activePage?.canGoBack != true)
                .accessibilityLabel("Back").accessibilityIdentifier("navigation.back")
            Button { model.forward() } label: { Image(systemName: "arrow.right").frame(width: 26, height: 32) }
                .disabled(model.activePage?.canGoForward != true)
                .accessibilityLabel("Forward").accessibilityIdentifier("navigation.forward")
            if model.activePage?.isLoading == true {
                Button { model.stop() } label: { Image(systemName: "xmark").frame(width: 26, height: 32) }
                    .accessibilityLabel("Stop Loading").accessibilityIdentifier("navigation.stop")
            } else {
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 32) }
                    .disabled(model.activePage == nil)
                    .accessibilityLabel("Reload").accessibilityIdentifier("navigation.reload")
            }
        }
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .background(WindowDragRegion())
    }

    private var currentURL: String? {
        guard case .web(let id) = model.coordinator.content else { return nil }
        return model.coordinator.tabStore.tab(id: id)?.currentURL.absoluteString
    }

    private var addressBar: some View {
        Button {
            model.presentCommandBar(.navigateCurrentTab)
        } label: {
            HStack(spacing: 8) {
                if currentURL == nil {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(addressLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(currentURL == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if currentURL != nil {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Address bar")
        .accessibilityValue(currentURL ?? "No active tab")
        .accessibilityIdentifier("sidebar.addressBar")
        .help(currentURL.map { "\($0) — Open Location (Command-L)" }
              ?? "Search or enter a URL (Command-L)")
    }

    private var addressLabel: String {
        guard let currentURL, let url = URL(string: currentURL), let host = url.host else {
            return "Search…"
        }
        // Keep the complete URL in the editor, accessibility value and hover help.
        return (url.scheme == "http" ? "http://" : "") + host
            + (url.port.map { ":\($0)" } ?? "")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
