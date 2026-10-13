import AppKit
import EarlyCore
import SwiftUI

struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel
    @State private var sidebarAutoHides = false
    @State private var sidebarHovered = false
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var sectionFrames: [Bool: CGRect] = [:]
    @State private var dropAreas: [String: CGRect] = [:]
    @GestureState private var draggingTab: UUID?
    @State private var dragLayout: SidebarReorderLayout?
    @State private var dragPoint: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var dragSourceFrame: CGRect = .zero
    @State private var frozenFrames: [UUID: CGRect] = [:]
    @State private var dropFolder: UUID?
    @State private var pendingFolder: UUID?
    @State private var folderHoverTask: Task<Void, Never>?
    @State private var hoverExpanded: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folderEditor = false
    @State private var editingFolder: UUID?
    @State private var folderParent: UUID?
    @State private var folderName = ""
    private var sidebarVisible: Bool { !sidebarAutoHides || sidebarHovered }

    private enum SidebarItem: Identifiable {
        case pinnedHeading, divider, newTab
        case tab(BrowserTab, Int)
        case folder(BrowserFolder, Int)

        var id: String {
            switch self {
            case .pinnedHeading: "pinned-heading"
            case .divider: "divider"
            case .newTab: "new-tab"
            case .tab(let tab, _): "tab-\(tab.id)"
            case .folder(let folder, _): "folder-\(folder.id)"
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        [.pinnedHeading] + folderItems(parent: nil, depth: 0)
            + [.divider, .newTab] + model.todayTabs.map { .tab($0, 0) }
    }

    private func folderItems(parent: UUID?, depth: Int) -> [SidebarItem] {
        guard depth <= 32 else { return [] }
        return model.coordinator.tabStore.pinnedItems(in: model.coordinator.activeSpaceID, parentID: parent).flatMap { item -> [SidebarItem] in
            switch item {
            case .tab(let tab):
                return [.tab(tab, depth)]
            case .folder(let folder):
                var items: [SidebarItem] = [.folder(folder, depth)]
                if folder.isExpanded || hoverExpanded.contains(folder.id) { items += folderItems(parent: folder.id, depth: depth + 1) }
                return items
            }
        }
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
        .sheet(isPresented: $folderEditor) {
          VStack(alignment: .leading, spacing: 16) {
            Text(editingFolder == nil ? "New Folder" : "Rename Folder").font(.headline)
            TextField("Folder name", text: $folderName).accessibilityIdentifier("folder.name")
            HStack {
            Button("Cancel") { folderEditor = false }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") {
                let success: Bool
                if let editingFolder { success = model.coordinator.renameFolder(editingFolder, to: folderName) }
                else { success = model.coordinator.createFolder(name: folderName, parentID: folderParent) != nil }
                if success { model.save() } else { model.notice = "Could not save folder. Use a name and a valid parent (maximum 32 levels)." }
                folderEditor = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }.padding(24).frame(width: 340)
        }
        .onDisappear { endDrag(); model.save(); model.webViews.discardAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                navigationControls
                addressBar.padding(.horizontal, -4)
            }
            favoritesSection
                .background(dropArea("favorites"))
                .background(dropHighlight(.favorites))
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
                                .accessibilityIdentifier("sidebar.pinned.heading")
                                .padding(.bottom, 8)
                                .background(dropArea("pinned"))
                                .background(dropHighlight(.pinned))
                        case .divider:
                            Divider().padding(.vertical, 8)
                                .offset(y: insertionOverflow(at: dropAreas["regular"]?.minY ?? 0))
                        case .newTab:
                            newTabButton
                                .offset(y: insertionOverflow(at: dropAreas["regular"]?.minY ?? 0))
                                .background(dropArea("regular"))
                                .background(dropHighlight(.regular))
                        case .tab(let tab, let depth):
                            tabRow(tab).padding(.leading, CGFloat(min(depth, 8)) * 12)
                        case .folder(let folder, let depth):
                            folderRow(folder).padding(.leading, CGFloat(min(depth, 8)) * 12)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sidebar.tabs")
            .background(sectionFrame(favorites: false))
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
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Tab") { model.presentCommandBar(.newTab) }
            Button("New Folder") { editFolder(nil, parent: nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("browser.sidebar")
        .coordinateSpace(name: "sidebarReordering")
        .overlay(alignment: .topLeading) { crossSectionPreview }
        .onPreferenceChange(TabFrames.self) { frames in
            tabFrames = frames
            guard draggingTab != nil else { return }
            // Measurements are outside the preview offsets, so expansion can
            // refresh every baseline without feeding animated positions back in.
            frozenFrames = frames
            if let tab = draggingTab.flatMap({ model.coordinator.tabStore.tab(id: $0) }) {
                refreshDragLayout(for: tab, at: dragPoint)
            }
        }
        .onPreferenceChange(SectionFrames.self) { sectionFrames = $0 }
        .onPreferenceChange(DropAreas.self) { dropAreas = $0 }
        .onChange(of: draggingTab) { _, id in
            if id == nil { endDrag() }
        }
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
            .highPriorityGesture(reorderGesture(tab))
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
        .background(draggingTab == tab.id ? Color(nsColor: .windowBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(draggingTab == tab.id ? 0.18 : 0), radius: 6, y: 3)
        .offset(previewOffset(tab.id))
        .opacity(draggingTab == tab.id ? 0 : 1)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .animation(draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(tab.id))
        .background(tabFrame(tab.id))
        .contextMenu { tabActions(tab) }
    }

    @ViewBuilder
    private func tabActions(_ tab: BrowserTab) -> some View {
        Button("Rename Tab…") { model.requestRename(tab.id) }
        if !tab.isFavorite {
            Menu("Move to Folder") {
                Button("Top Level") { _ = model.coordinator.moveTab(tab.id, toFolder: nil); model.save() }
                    .disabled(tab.folderID == nil)
                ForEach(model.coordinator.folders) { folder in
                    Button(folderPath(folder)) { _ = model.coordinator.moveTab(tab.id, toFolder: folder.id); model.save() }
                        .disabled(tab.folderID == folder.id)
                }
            }
        }
        Button("Move Up") { model.moveTab(tab.id, direction: -1) }
            .disabled(model.coordinator.tabStore.siblingIDs(of: tab).first == tab.id)
        Button("Move Down") { model.moveTab(tab.id, direction: 1) }
            .disabled(model.coordinator.tabStore.siblingIDs(of: tab).last == tab.id)
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
            if !model.favorites.isEmpty || receivingFavorite {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(model.favorites) { tab in
                            favoriteTile(tab)
                        }
                        if receivingFavorite { Color.clear.frame(height: 54).accessibilityHidden(true) }
                    }
                }
                // A large collection must not consume all room for space tabs.
                .frame(height: min(CGFloat((model.favorites.count + (receivingFavorite ? 1 : 0) + 3) / 4) * 60 - 6, 174))
                .accessibilityIdentifier("sidebar.favorites")
                .background(sectionFrame(favorites: true))
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
        .highPriorityGesture(reorderGesture(tab))
        .offset(previewOffset(tab.id))
        .opacity(draggingTab == tab.id ? 0 : 1)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .animation(draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(tab.id))
        .background(tabFrame(tab.id))
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

    private func editFolder(_ folder: BrowserFolder?, parent: UUID?) {
        editingFolder = folder?.id
        folderParent = parent
        folderName = folder?.name ?? ""
        folderEditor = true
    }

    private func folderPath(_ folder: BrowserFolder) -> String {
        var names = [folder.name]
        var parent = folder.parentID
        var seen: Set<UUID> = [folder.id]
        while let id = parent, seen.insert(id).inserted,
              let ancestor = model.coordinator.folders.first(where: { $0.id == id }) {
            names.insert(ancestor.name, at: 0)
            parent = ancestor.parentID
        }
        return names.joined(separator: " / ")
    }

    private func folderRow(_ folder: BrowserFolder) -> some View {
        Button { model.coordinator.toggleFolder(folder.id); model.save() } label: {
            HStack(spacing: 6) {
                Image(systemName: folder.isExpanded || hoverExpanded.contains(folder.id) ? "chevron.down" : "chevron.right").font(.caption2)
                Image(systemName: "folder")
                Text(folder.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("folder.\(folder.id)")
        .accessibilityLabel(folder.name)
        .accessibilityValue(folder.isExpanded || hoverExpanded.contains(folder.id) ? "Expanded" : "Collapsed")
        .background(Color.accentColor.opacity(dropFolder == folder.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
        .offset(previewOffset(folder.id))
        .animation(draggingTab == nil || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(folder.id))
        .background(tabFrame(folder.id))
        .contextMenu {
            Button("New Subfolder…") { editFolder(nil, parent: folder.id) }
            Button("Rename Folder…") { editFolder(folder, parent: folder.parentID) }
            Menu("Move Folder") {
                Button("Top Level") { _ = model.coordinator.moveFolder(folder.id, to: nil); model.save() }
                    .disabled(folder.parentID == nil)
                ForEach(model.coordinator.folders) { parent in
                    Button(folderPath(parent)) { _ = model.coordinator.moveFolder(folder.id, to: parent.id); model.save() }
                        .disabled(!model.coordinator.tabStore.canMoveFolder(folder.id, to: parent.id) || parent.id == folder.parentID)
                }
            }
        }
    }

    private struct TabFrames: PreferenceKey {
        static let defaultValue: [UUID: CGRect] = [:]
        static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func tabFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TabFrames.self,
                                   value: [id: geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }

    private struct SectionFrames: PreferenceKey {
        static let defaultValue: [Bool: CGRect] = [:]
        static func reduce(value: inout [Bool: CGRect], nextValue: () -> [Bool: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func sectionFrame(favorites: Bool) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SectionFrames.self,
                                   value: [favorites: geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }

    private func itemFrame(_ id: UUID) -> CGRect? {
        frozenFrames[id] ?? tabFrames[id]
    }

    private func beginDrag(_ tab: BrowserTab) {
        guard let frame = tabFrames[tab.id] else { return }
        frozenFrames = tabFrames
        dragSourceFrame = frame
        refreshDragLayout(for: tab, at: dragPoint)
    }

    private func endDrag() {
        folderHoverTask?.cancel()
        folderHoverTask = nil
        pendingFolder = nil
        dropFolder = nil
        hoverExpanded = []
        dragLayout = nil
        dragTranslation = .zero
        frozenFrames = [:]
    }

    private func refreshDragLayout(for tab: BrowserTab, at point: CGPoint) {
        let destination = destinationSection(at: point) ?? section(of: tab)
        let folderID = destination == .pinned ? containerFolder(at: point) : nil
        var slots = destinationSlots(in: destination, folderID: folderID)
        let bounds = destinationBounds(in: destination, folderID: folderID, slots: slots)
        let foreign = !slots.contains(where: { $0.id == tab.id })
        if foreign {
            let size = CGSize(width: destination == .favorites ? max(1, (bounds.width - 18) / 4) : bounds.width,
                              height: destination == .favorites ? 54 : (destination == .pinned ? 34 : 32))
            let preceding = slots.last?.frame ?? (destination == .pinned
                ? (folderID.flatMap { itemFrame($0) } ?? dropAreas["pinned"]) : nil)
            slots.append(.init(id: tab.id, frame: SidebarReorderLayout.placeholderFrame(
                after: preceding, bounds: bounds, grid: destination == .favorites, size: size)))
        }
        guard bounds.width > 0, bounds.height > 0, slots.contains(where: { $0.id == tab.id }) else { dragLayout = nil; return }
        dragLayout = SidebarReorderLayout(source: tab.id, slots: slots, bounds: bounds,
                                          grid: destination == .favorites, foreign: foreign)
    }

    private func destinationSlots(in destination: TabStore.Section, folderID: UUID?) -> [SidebarReorderLayout.Slot] {
        let ids: [UUID]
        switch destination {
        case .favorites:
            ids = model.favorites.map(\.id)
        case .regular:
            ids = model.todayTabs.map(\.id)
        case .pinned:
            ids = model.coordinator.tabStore.pinnedItems(in: model.coordinator.activeSpaceID, parentID: folderID).map(\.id)
        }
        return ids.compactMap { id in
            guard let header = itemFrame(id) else { return nil }
            var block = header
            if destination == .pinned, let index = pinnedOutline.firstIndex(where: { $0.id == id && $0.isFolder }) {
                for child in pinnedOutline.dropFirst(index + 1) {
                    if child.depth <= pinnedOutline[index].depth { break }
                    if let frame = itemFrame(child.id) { block = block.union(frame) }
                }
            }
            return SidebarReorderLayout.Slot(id: id, frame: block, hitFrame: header)
        }
    }

    private func destinationBounds(in destination: TabStore.Section, folderID: UUID?, slots: [SidebarReorderLayout.Slot]) -> CGRect {
        switch destination {
        case .favorites:
            return sectionFrames[true] ?? dropAreas["favorites"] ?? .null
        case .regular:
            guard let viewport = sectionFrames[false], let regular = dropAreas["regular"] else { return .null }
            return CGRect(x: viewport.minX, y: regular.minY, width: viewport.width,
                          height: max(0, viewport.maxY - regular.minY))
        case .pinned:
            guard let viewport = sectionFrames[false], let regular = dropAreas["regular"] else { return .null }
            let bottom = min(regular.minY, viewport.maxY)
            if let folderID, let header = itemFrame(folderID) {
                let next = nextPinnedSiblingFrame(of: folderID)
                let maxY = next?.minY ?? bottom
                return CGRect(x: viewport.minX, y: header.minY, width: viewport.width, height: max(0, maxY - header.minY))
            }
            let top = slots.map(\.frame.minY).min().map { min($0, viewport.minY + 12) } ?? viewport.minY
            return CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: max(0, bottom - min(top, viewport.minY)))
        }
    }

    private func nextPinnedSiblingFrame(of folderID: UUID) -> CGRect? {
        let items = pinnedOutline
        guard let index = items.firstIndex(where: { $0.id == folderID }) else { return nil }
        return items.dropFirst(index + 1).first { $0.depth <= items[index].depth }.flatMap { itemFrame($0.id) }
    }

    private var pinnedOutline: [(id: UUID, depth: Int, isFolder: Bool)] {
        sidebarItems.compactMap { item in
            switch item {
            case .tab(let tab, let depth) where tab.pinnedURL != nil && !tab.isFavorite:
                return (tab.id, depth, false)
            case .folder(let folder, let depth):
                return (folder.id, depth, true)
            default:
                return nil
            }
        }
    }

    private func containerFolder(at point: CGPoint) -> UUID? {
        if let dropFolder {
            if itemFrame(dropFolder)?.contains(point) == true { return dropFolder }
        }
        let expanded = model.coordinator.folders.filter { $0.isExpanded || hoverExpanded.contains($0.id) }
        let enclosing = expanded.filter { folder in
            guard let header = itemFrame(folder.id) else { return false }
            let next = nextPinnedSiblingFrame(of: folder.id)?.minY
                ?? dropAreas["regular"]?.minY
                ?? sectionFrames[false]?.maxY
            guard let next else { return false }
            // The left gutter remains a way to insert at the parent level.
            return point.x >= header.minX + 12 && point.y >= header.maxY && point.y < next
        }
        return enclosing.max(by: { depth(of: $0) < depth(of: $1) })?.id
    }

    private func depth(of folder: BrowserFolder) -> Int {
        var depth = 0, parent = folder.parentID, seen: Set<UUID> = [folder.id]
        while let id = parent, seen.insert(id).inserted,
              let ancestor = model.coordinator.folders.first(where: { $0.id == id }) {
            depth += 1
            parent = ancestor.parentID
        }
        return depth
    }

    private func nestTarget(at point: CGPoint) -> UUID? {
        let folders = model.coordinator.folders.compactMap { folder -> (UUID, CGRect)? in
            guard let frame = itemFrame(folder.id), frame.contains(point) else { return nil }
            return (folder.id, frame)
        }
        guard let match = folders.min(by: { $0.1.height < $1.1.height }) else { return nil }
        // Top/bottom edges stay sibling insertion; the middle dwells to nest.
        if point.y < match.1.minY + 8 || point.y > match.1.maxY - 8 { return nil }
        return match.0
    }

    private func updateFolderHover(at point: CGPoint) {
        guard destinationSection(at: point) == .pinned else {
            pendingFolder = nil
            dropFolder = nil
            folderHoverTask?.cancel()
            return
        }
        if let dropFolder {
            let bounds = destinationBounds(in: .pinned, folderID: dropFolder,
                                           slots: destinationSlots(in: .pinned, folderID: dropFolder))
            if !bounds.contains(point), itemFrame(dropFolder)?.contains(point) != true {
                self.dropFolder = nil
            }
        }
        let target = nestTarget(at: point)
        guard target != pendingFolder else { return }
        pendingFolder = target
        folderHoverTask?.cancel()
        guard let target else { return }
        folderHoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, pendingFolder == target, let draggingTab,
                  let tab = model.coordinator.tabStore.tab(id: draggingTab) else { return }
            dropFolder = target
            hoverExpanded.insert(target)
            refreshDragLayout(for: tab, at: dragPoint)
        }
    }

    private func reorderGesture(_ tab: BrowserTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarReordering"))
            .updating($draggingTab) { _, state, _ in state = tab.id }
            .onChanged { value in
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                if frozenFrames.isEmpty { beginDrag(tab) }
                dragTranslation = CGSize(width: tab.isFavorite ? value.translation.width : 0,
                                         height: value.translation.height)
                updateFolderHover(at: value.location)
                refreshDragLayout(for: tab, at: value.location)
            }
            .onEnded { value in
                defer { endDrag() }
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                guard let destination = destinationSection(at: value.location) else { return }
                refreshDragLayout(for: tab, at: value.location)
                let folderID = destination == .pinned ? containerFolder(at: value.location) : nil
                if let drop = dragLayout?.insertion(at: value.location) {
                    _ = model.placeTab(tab.id, in: destination, folderID: folderID, before: drop.before)
                } else if destination != section(of: tab) || folderID != tab.folderID {
                    _ = model.placeTab(tab.id, in: destination, folderID: folderID, before: nil)
                }
            }
    }

    private var receivingFavorite: Bool {
        guard let draggingTab, let tab = model.coordinator.tabStore.tab(id: draggingTab),
              let destination = destinationSection(at: dragPoint) else { return false }
        return destination == .favorites && !tab.isFavorite
    }

    @ViewBuilder
    private var crossSectionPreview: some View {
        if let draggingTab, let tab = model.coordinator.tabStore.tab(id: draggingTab) {
            Text(tab.isFavorite ? String(tab.displayTitle.prefix(1)).uppercased() : tab.displayTitle)
                .font(.callout).lineLimit(1)
                .frame(width: dragSourceFrame.width, height: dragSourceFrame.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 5, y: 2)
                .position(x: dragSourceFrame.midX + dragTranslation.width, y: dragSourceFrame.midY + dragTranslation.height)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private struct DropAreas: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func dropArea(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: DropAreas.self, value: [key: geometry.frame(in: .named("sidebarReordering"))])
        }.allowsHitTesting(false)
    }

    private func section(of tab: BrowserTab) -> TabStore.Section {
        tab.isFavorite ? .favorites : (tab.pinnedURL == nil ? .regular : .pinned)
    }

    private func destinationSection(at point: CGPoint) -> TabStore.Section? {
        if dropAreas["favorites"]?.contains(point) == true { return .favorites }
        guard let viewport = sectionFrames[false], viewport.contains(point),
              let regular = dropAreas["regular"] else { return nil }
        return point.y >= regular.minY ? .regular : .pinned
    }

    private func dropHighlight(_ section: TabStore.Section) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor.opacity(draggingTab != nil && destinationSection(at: dragPoint) == section ? 0.12 : 0))
            .allowsHitTesting(false)
    }

    private func previewOffset(_ id: UUID) -> CGSize {
        guard let draggingTab, let dragLayout else { return .zero }
        if draggingTab == id { return .zero }
        if dragLayout.slots.contains(where: { $0.id == id }) {
            return dragLayout.offset(for: id, at: dragPoint)
        }
        // Descendants travel with a folder's block when a tab crosses it.
        var parent = model.coordinator.tabStore.tab(id: id)?.folderID
            ?? model.coordinator.folders.first(where: { $0.id == id })?.parentID
        var seen: Set<UUID> = []
        while let folder = parent, seen.insert(folder).inserted {
            if dragLayout.slots.contains(where: { $0.id == folder }) {
                return dragLayout.offset(for: folder, at: dragPoint)
            }
            parent = model.coordinator.folders.first(where: { $0.id == folder })?.parentID
        }
        return CGSize(width: 0, height: insertionOverflow(at: itemFrame(id)?.minY ?? 0))
    }

    private func insertionOverflow(at y: CGFloat) -> CGFloat {
        guard draggingTab != nil, let dragLayout, dragLayout.foreign, !dragLayout.grid,
              dragLayout.bounds.contains(dragPoint),
              let placeholder = dragLayout.slots.first(where: { $0.id == dragLayout.source }) else { return 0 }
        let bottom = dragLayout.slots.filter { $0.id != dragLayout.source }.last?.frame.maxY
            ?? placeholder.frame.minY - 4
        return y > bottom ? placeholder.frame.height + 4 : 0
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
