import EarlyCore
import SwiftUI

struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel
    @State private var sidebarAutoHides = false
    @State private var sidebarHovered = false
    private var sidebarVisible: Bool { !sidebarAutoHides || sidebarHovered }

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
                if model.coordinator.commandBar != nil {
                    CommandBarView(model: model)
                        .padding(32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.leading, sidebarAutoHides ? 0 : 266)
            sidebar
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(sidebarAutoHides && sidebarVisible ? 0.15 : 0), radius: 8, x: 3)
                .offset(x: sidebarVisible ? 0 : -280)
                .allowsHitTesting(sidebarVisible)
                .accessibilityHidden(!sidebarVisible)
                .onHover { inside in
                    // Only the window-edge target may reveal a hidden sidebar.
                    // Ignore enter events from the offset sidebar's tracking area.
                    if !inside { sidebarHovered = false }
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
        .focusedSceneValue(\.browserWindow, model)
        .onAppear { model.activateSelection() }
        .onDisappear { model.save(); model.webViews.discardAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                navigationControls
                addressBar.padding(.horizontal, -4)
            }
            Label("Personal", systemImage: "square.stack")
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Favorites")
                sectionLabel("Pinned")
                Divider()
                sectionLabel("Today")
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.openTabs) { tab in
                        HStack(spacing: 4) {
                            Button { model.selectTab(tab.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe").accessibilityHidden(true)
                                    Text(tab.title).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tab.\(tab.id)")
                            .accessibilityAddTraits(model.coordinator.activeTabID == tab.id ? .isSelected : [])
                            Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close \(tab.title)")
                        }
                        .padding(.horizontal, 8)
                        .background(model.coordinator.activeTabID == tab.id ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            Button {
                model.presentCommandBar(.newTab)
            } label: {
                HStack {
                    Label("New Tab", systemImage: "plus")
                    Spacer()
                    Text("⌘T").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.newTab")
            .help("Open the command bar (Command-T)")
            #if DEBUG
            if model.isTesting {
                Text("Tabs \(model.openTabs.count) · Views \(model.webViews.liveViewCount) · Created \(model.webViews.creationCount) · \(model.persistence.isSaving ? "Saving" : "Saved")")
                    .font(.caption2)
                    .accessibilityIdentifier("test.runtime")
            }
            #endif
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("browser.sidebar")
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
