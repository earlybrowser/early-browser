// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

struct FolderBounceDisplacementKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var folderBounceDisplacement: CGFloat {
        get { self[FolderBounceDisplacementKey.self] }
        set { self[FolderBounceDisplacementKey.self] = newValue }
    }
}

/// AppKit exposes no public window corner radius. Keep content concentric with
/// the system's standard titled-window corners instead of reading a private
/// selector: 10 pt through macOS 15 and 16 pt from macOS 26.
enum WindowCornerGeometry {
    static func windowRadius(for version: OperatingSystemVersion) -> CGFloat {
        version.majorVersion >= 26 ? 16 : 10
    }
}

struct BrowserSurfaceFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct BrowserWindowView: View {
    /// Folders and pinned tabs share one island geometry at every sidebar width.
    enum PinnedIsland {
        static let height: CGFloat = 34
        static let cornerRadius: CGFloat = 10
        static let iconControlWidth: CGFloat = 24
        static let leadingInset: CGFloat = 4
    }

    @Bindable var model: BrowserWindowModel
    var sidebarAutoHides: Bool { model.preferences.sidebarAutoHides }
    @State var sidebarHovered = false
    @FocusState var revealFocused: Bool
    @State var resizeStartWidth: Double?
    @State var tabFrames: [UUID: CGRect] = [:]
    @State var folderHitFrames: [UUID: CGRect] = [:]
    @State var sectionFrames: [Bool: CGRect] = [:]
    @State var dropAreas: [String: CGRect] = [:]
    // Shared stable identity for a tab or folder being reordered.
    @GestureState var dragGestureItemID: UUID?
    @State var cancelledGestureItemID: UUID?
    @State var dragLayout: SidebarReorderLayout?
    @State var dragPoint: CGPoint = .zero
    @State var dragTranslation: CGSize = .zero
    @State var contentDragTranslationX: CGFloat = 0
    @State var dragSourceFrame: CGRect = .zero
    @State var frozenFrames: [UUID: CGRect] = [:]
    @State var dropFolder: UUID?
    @State var pendingFolder: UUID?
    @State var previousDragPoint: CGPoint?
    @State var insertionContainer: DragContainer?
    @State var insertionSiblings: [UUID] = []
    @State var insertionIndex: Int?
    @State var dragFeedbackTarget: DragFeedbackTarget?
    @State var reservedFolderSlot: UUID?
    @State var revealDropSections = false
    @State var dragSourceItem: SidebarDragItem?
    @State var dragLanding: DragLanding?
    @State var landingLayoutReady = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @Environment(\.colorScheme) var colorScheme
    @State var folderEditor = false
    @State var editingFolder: UUID?
    @State var folderParent: UUID?
    @State var folderName = ""
    @State var folderIcon: SpaceIcon?
    @State var showingFolderIconPicker = false
    /// The folder whose icon Change Icon… is choosing.
    @State var iconFolderID: UUID?
    #if DEBUG
    @State var folderToggleActionCount = 0

    var testRuntimeValue: String {
        "Tabs \(model.openTabs.count) · Views \(model.webViews.liveViewCount) · Created \(model.webViews.creationCount) · \(model.persistence.isSaving ? "Saving" : "Saved")"
    }
    #endif
    @State var hoveredTab: UUID?
    @State var addressHovered = false
    @State var hoveredMedia: UUID?
    @State var hoveredFolder: UUID?
    @State var hoveredFolderGroups: Set<UUID> = []
    @State var folderBounceEvent: FolderBounceEvent?
    @State var sidebarPointer = SidebarPointer()
    @State var windowPointer = SidebarPointer()
    @State var contentWindowFrame: CGRect = .zero
    @State var sidebarWindowFrame: CGRect = .zero
    @FocusState var focusedSidebarControl: SidebarControl?
    var sidebarVisible: Bool {
        !sidebarAutoHides || sidebarHovered || model.sidebarInteractionInProgress || resizeStartWidth != nil
            || model.downloadsPresented
    }
    // GestureState can reset before onEnded. Keep preview identity until the
    // drop transaction has exchanged it for the settlement proxy.
    var draggingTab: UUID? { dragSourceItem?.id }
    var hiddenDragItemID: UUID? { dragLanding?.motion.itemID ?? draggingTab }
    var splitDropLeadingInset: CGFloat {
        sidebarAutoHides && sidebarVisible ? max(0, sidebarWindowFrame.maxX - contentWindowFrame.minX) : 0
    }
    var tabDragIsOverContent: Bool {
        guard case .tab = dragSourceItem else { return false }
        let point = CGPoint(x: sidebarWindowFrame.minX + dragPoint.x, y: sidebarWindowFrame.minY + dragPoint.y)
        return contentWindowFrame.contains(point) && point.x >= contentWindowFrame.minX + splitDropLeadingInset
    }
    var showsFolderDragTargets: Bool {
        guard let viewport = sectionFrames[false], let divider = dropAreas["divider"] else { return false }
        return SidebarFolderPreview.showsDragTargets(isDragging: dragSourceItem != nil, at: dragPoint,
                                                     viewport: viewport, divider: divider)
    }
    var folderDragAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
    var folderExpansionAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.16, bounce: 0.18)
    }
    var sidebarMotion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.20)
    }

    /// An invisible 12 pt grab area over the visible boundary: the 6 pt gap and
    /// page outline beside a pinned sidebar, or a floating sidebar's own edge.
    var sidebarResizeHandle: some View {
        let overhang: CGFloat = sidebarAutoHides ? 6 : 9
        return SidebarResizeEdge(width: model.sidebarWidth,
            onBegin: {
                resizeStartWidth = model.sidebarWidth
                model.sidebarInteractionInProgress = true
            },
            onResize: { translation in
                model.sidebarWidth = SidebarWidth.clamped((resizeStartWidth ?? model.sidebarWidth) + translation)
            },
            onEnd: {
                resizeStartWidth = nil
                model.sidebarInteractionInProgress = false
                model.finishSidebarResize()
            },
            onAdjust: { delta in
                model.sidebarWidth = SidebarWidth.clamped(model.sidebarWidth + delta)
                model.finishSidebarResize()
            })
            .frame(width: 12)
            // Layout, not a render offset: the native view's frame must match.
            .alignmentGuide(HorizontalAlignment.trailing) { $0[HorizontalAlignment.trailing] - overhang }
    }

    // Pointer samples are not observable: redraw only when group membership
    // changes. Retain the last sample to recompute hover after scrolling/layout.
    final class SidebarPointer {
        var location: CGPoint?
    }

    enum SidebarControl: Hashable {
        case address, tab(UUID), close(UUID), media(UUID), favorite(UUID), folder(UUID), folderToggle(UUID)
    }

    struct DragContainer: Equatable {
        let section: TabStore.Section
        let parent: UUID?
    }

    struct DragFeedbackTarget: Equatable {
        let container: DragContainer
        let index: Int?
    }

    struct FolderBounceEvent: Equatable {
        let id = UUID()
        let folders: Set<UUID>
    }

    enum SidebarDragItem {
        case tab(BrowserTab), folder(BrowserFolder)
        var id: UUID {
            switch self { case .tab(let tab): tab.id; case .folder(let folder): folder.id }
        }
    }

    struct DragLanding: Identifiable {
        var motion: SidebarDragSettlement
        let item: SidebarDragItem
        let releasedSection: TabStore.Section
        let section: TabStore.Section
        let folderID: UUID?
        var id: UUID { motion.id }
    }

    enum SidebarItem: Identifiable {
        case pinnedStart, pinnedEnd, divider, newTab
        case tab(BrowserTab, Int)
        case folder(BrowserFolder, Int)
        case folderEnd(BrowserFolder, Int)
        /// A live folder's note below its pins (reading, signed out…).
        case liveStatus(BrowserFolder, Int)

        var id: String {
            switch self {
            case .pinnedStart: "pinned-start"
            case .pinnedEnd: "pinned-end"
            case .divider: "divider"
            case .newTab: "new-tab"
            case .tab(let tab, _): "tab-\(tab.id)"
            case .folder(let folder, _): "folder-\(folder.id)"
            case .folderEnd(let folder, _): "folder-end-\(folder.id)"
            case .liveStatus(let folder, _): "live-status-\(folder.id)"
            }
        }

        var draggableID: UUID? {
            switch self {
            case .tab(let tab, _): tab.id
            case .folder(let folder, _): folder.id
            default: nil
            }
        }

        var isPinsBoundary: Bool {
            switch self { case .pinnedStart, .pinnedEnd: true; default: false }
        }
    }

    var sidebarItems: [SidebarItem] {
        sidebarItems(in: model.coordinator.activeSpaceID)
    }

    func sidebarItems(in spaceID: UUID) -> [SidebarItem] {
        let pins = folderItems(in: spaceID, parent: nil, depth: 0)
        return [.pinnedStart] + pins + [.pinnedEnd]
            + [.divider, .newTab] + model.coordinator.tabStore.todayTabs(in: spaceID).map { .tab($0, 0) }
    }

    func folderItems(in spaceID: UUID, parent: UUID?, depth: Int) -> [SidebarItem] {
        guard depth <= 32 else { return [] }
        return model.coordinator.tabStore.pinnedItems(in: spaceID, parentID: parent).flatMap { item -> [SidebarItem] in
            switch item {
            case .tab(let tab):
                return [.tab(tab, depth)]
            case .folder(let folder):
                var items: [SidebarItem] = [.folder(folder, depth)]
                let preview = folderPreview(folder)
                if preview.showsContents {
                    items += folderItems(in: spaceID, parent: folder.id, depth: depth + 1)
                }
                if folder.live != nil, isFolderOpen(folder), !model.isPrivate {
                    items.append(.liveStatus(folder, depth + 1))
                }
                if preview.showsPanel {
                    items.append(.folderEnd(folder, depth))
                }
                return items
            }
        }
    }

    func folderHasChildren(_ id: UUID, in spaceID: UUID? = nil) -> Bool {
        !model.coordinator.tabStore.pinnedItems(in: spaceID ?? model.coordinator.activeSpaceID, parentID: id).isEmpty
    }

    func folderPreview(_ folder: BrowserFolder) -> SidebarFolderPreview {
        SidebarFolderPreview(isExpanded: folder.isExpanded, hasChildren: folderHasChildren(folder.id, in: folder.spaceID),
                             isDragSource: folder.id == hiddenDragItemID, receivesSlot: reservedFolderSlot == folder.id)
    }

    func isFolderOpen(_ folder: BrowserFolder) -> Bool {
        folder.id != draggingTab && folder.isExpanded
    }

    static let windowCornerRadius = WindowCornerGeometry.windowRadius(
        for: ProcessInfo.processInfo.operatingSystemVersion)

    /// Root window padding is 6 pt. For the inner content border to be concentric
    /// with the window frame (constant 6 pt distance everywhere, including corner curves):
    var contentCornerRadius: CGFloat {
        max(Self.windowCornerRadius - 6, 4)
    }

    /// The pinned sidebar belongs to the continuous window chrome, not a
    /// separate rounded island. Only the floating sidebar needs inset corners.
    var sidebarCornerRadius: CGFloat {
        sidebarAutoHides ? max(Self.windowCornerRadius - 3, 4) : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                SplitContentView(model: model, dropTargetLeadingInset: splitDropLeadingInset,
                                 contentCornerRadius: contentCornerRadius)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("browser.content")
                VStack {
                    if let error = model.persistence.error {
                        Text(error).font(.callout).padding(12)
                            .modifier(PageToolSurface(theme: model.chromeTheme, allowsTransparency: model.preferences.translucentChrome))
                            .accessibilityIdentifier("browser.persistenceError")
                    }
                    if let notice = model.notice {
                        HStack {
                            Text(notice)
                            Button("Dismiss") { model.notice = nil }
                        }.font(.callout).padding(12)
                            .modifier(PageToolSurface(theme: model.chromeTheme, allowsTransparency: model.preferences.translucentChrome))
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(surfaceFrame("content"))
            .modifier(BrowserContentSurface.container(cornerRadius: contentCornerRadius,
                split: model.coordinator.activeSplitGroup != nil))
            // A live page receives drops itself (upload areas keep working);
            // empty content opens dropped files and links as new tabs.
            .dropDestination(for: URL.self) { urls, _ in model.openLocations(urls) }
            .padding(.leading, sidebarAutoHides ? 0 : model.sidebarWidth + 6)

            sidebar
                .disabled(model.application?.profileOperationInProgress == true)
                .dropDestination(for: URL.self) { urls, _ in model.openLocations(urls) }
                .background(surfaceFrame("sidebar"))
                .background {
                    if sidebarAutoHides {
                        // Floating chrome must stay legible over web content.
                        BrowserChromeBackground(theme: model.chromeTheme,
                                                floating: true, allowsTransparency: model.preferences.translucentChrome)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: sidebarCornerRadius))
                .overlay {
                    if sidebarAutoHides {
                        RoundedRectangle(cornerRadius: sidebarCornerRadius)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.30 : 0.10), lineWidth: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .shadow(color: .black.opacity(sidebarAutoHides && sidebarVisible ? 0.15 : 0), radius: 8, x: 3)
                .overlay(alignment: .trailing) { sidebarResizeHandle }
                .offset(x: sidebarVisible ? 0 : -(model.sidebarWidth + 20))
                .padding(.leading, sidebarAutoHides ? -3 : 0)
                .padding(.vertical, sidebarAutoHides ? -3 : 0)
                .allowsHitTesting(sidebarVisible)
                .accessibilityHidden(!sidebarVisible)

            if model.coordinator.commandBar != nil {
                ZStack(alignment: .top) {
                    // Only the card intercepts input. Outside clicks dismiss
                    // through its event monitor; scrolls reach the live page.
                    GeometryReader { geometry in
                        CommandBarView(model: model, availableHeight: geometry.size.height)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.horizontal, 32)
                            .padding(.top, CommandBarLayout(availableHeight: geometry.size.height,
                                hasSuggestions: false, statusCount: 0).topInset)
                            .padding(.leading, sidebarAutoHides ? 0 : model.sidebarWidth + 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.tabSwitcher != nil {
                GeometryReader { geometry in
                    TabSwitcherView(model: model, availableWidth: geometry.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.leading, sidebarAutoHides ? 0 : model.sidebarWidth + 6)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(sidebarMotion, value: sidebarAutoHides)
        .animation(sidebarMotion, value: sidebarVisible)
        .padding(6)
        .coordinateSpace(name: "browserWindow")
        .overlay(alignment: .topLeading) {
            if case .tab(let tab) = dragSourceItem, dragLanding == nil, tabDragIsOverContent {
                dragItemPreview(.tab(tab), section: section(of: tab), size: dragSourceFrame.size, lifted: true)
                    .position(x: sidebarWindowFrame.minX + dragSourceFrame.midX + contentDragTranslationX,
                              y: sidebarWindowFrame.minY + dragSourceFrame.midY + dragTranslation.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let flight = model.downloadFlight {
                DownloadFlightView(flight: flight,
                                   theme: model.chromeTheme.focusBorder(isDark: colorScheme == .dark,
                                                                       increasedContrast: contrast == .increased).color) {
                    model.finishDownloadFlight(flight.id)
                }
                .id(flight.id)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onPreferenceChange(BrowserSurfaceFrames.self) { frames in
            if let content = frames["content"], contentWindowFrame != content { contentWindowFrame = content }
            if let sidebar = frames["sidebar"], sidebarWindowFrame != sidebar { sidebarWindowFrame = sidebar }
        }
        .onPreferenceChange(DownloadsButtonFrameKey.self) { frame in
            if model.downloadsButtonFrame != frame { model.downloadsButtonFrame = frame }
        }
        .onPreferenceChange(SiteControlsFrameKey.self) { model.siteControlsFrame = $0 }
        // One shared surface for the outer frame and pinned sidebar. Only the
        // clipped page area is inset into it; no sidebar tint or seam on top.
        .background(BrowserChromeBackground(theme: model.chromeTheme,
                                            allowsTransparency: model.preferences.translucentChrome))
        // The thin chrome border around the sidebar and page behaves like a
        // title bar in every window (ordinary and private): drag to move,
        // double-click to zoom. The chrome above ignores clicks.
        .background(WindowDragRegion())
        .background { if model.isPrivate { PrivateWindowAppearance() } }
        .background(BrowserWindowPointerMonitor { point in
            windowPointer.location = point
            guard sidebarAutoHides else { return }
            let inside = point != nil && (resizeStartWidth != nil
                || SidebarRevealRegion.contains(point, sidebarWidth: model.sidebarWidth, revealed: sidebarHovered))
            if sidebarHovered != inside { sidebarHovered = inside }
        })
        .background(TabSwitcherKeyboardMonitor(model: model))
        .background(PageShortcutMonitor(model: model))
        .background {
            if #available(macOS 15.0, *) { PageTranslationHost(model: model) }
        }
        .background(BrowserWindowActivityMonitor(onCancel: {
            cancelledGestureItemID = dragGestureItemID
            model.cancelWindowInteractions()
            endDrag()
            resizeStartWidth = nil
            sidebarHovered = false
            NSCursor.arrow.set()
        }, isInteracting: model.sidebarInteractionInProgress || model.splitResize != nil))
        .overlay(alignment: .topTrailing) {
            if let toast = model.toast {
                Label {
                    Text(toast.message)
                } icon: {
                    Image(systemName: "checkmark")
                        .foregroundStyle(model.chromeTheme.focusBorder(isDark: colorScheme == .dark,
                                                                       increasedContrast: contrast == .increased).color)
                }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .modifier(PageToolSurface(theme: model.chromeTheme, allowsTransparency: model.preferences.translucentChrome))
                    .padding(20)
                    .allowsHitTesting(false)
                    .accessibilityLabel(toast.message)
                    .accessibilityIdentifier(toast.accessibilityIdentifier)
                    .transition(reduceMotion ? .identity : .opacity)
                    .task(id: toast.id) {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.toast != nil)
        .overlay(alignment: .leading) {
            if sidebarAutoHides && !sidebarVisible {
                Button { sidebarHovered = true } label: { Color.clear }
                    .buttonStyle(.plain)
                    .frame(width: SidebarRevealRegion.edgeWidth)
                    .contentShape(Rectangle())
                    .focused($revealFocused)
                    .onChange(of: revealFocused) { _, focused in
                        if focused {
                            sidebarHovered = true
                            focusedSidebarControl = .address
                        }
                    }
                    .accessibilityLabel("Reveal sidebar")
                    .accessibilityIdentifier("sidebar.reveal")
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            #if DEBUG
            if model.isTesting {
                HStack(spacing: 0) {
                    TestWindowState().frame(width: 1, height: 1)
                    TestFrontWindowState(application: model.application).frame(width: 1, height: 1)
                    // State assertions must not depend on sidebar visibility.
                    TestRuntimeState(value: testRuntimeValue).frame(width: 1, height: 1)
                }
            }
            #endif
        }
        .focusedSceneValue(\.browserWindow, model)
        .sheet(isPresented: Binding(get: { model.renamingTabID != nil }, set: { if !$0 { model.renamingTabID = nil } })) {
            RenameTabSheet(model: model)
        }
        .onAppear { model.activateSelection() }
        .onChange(of: model.canPresentTabSwitcher) { _, allowed in
            if !allowed { model.cancelTabSwitcher(restoreFocus: false) }
        }
        .onChange(of: sidebarVisible, initial: true) { _, visible in
            model.sidebarIsHidden = !visible
            if !visible {
                sidebarPointer.location = nil
                hoveredFolderGroups = []
            }
        }
        .onChange(of: model.sidebarInteractionInProgress) { _, active in
            if !active, sidebarAutoHides {
                sidebarHovered = windowPointer.location.map { $0.x >= 0 && $0.x < model.sidebarWidth + 6 } ?? false
            }
        }
        .onChange(of: model.hasVisibleDialog) { _, dialog in
            if dialog {
                cancelledGestureItemID = dragGestureItemID
                model.cancelWindowInteractions()
                endDrag()
            }
        }
        .sheet(isPresented: $folderEditor) {
          VStack(alignment: .leading, spacing: 16) {
            Text(editingFolder == nil ? "New Folder" : "Rename Folder").font(.headline)
            TextField("Folder name", text: $folderName).accessibilityIdentifier("folder.name")
            if editingFolder == nil {
                HStack(spacing: 12) {
                    Button { showingFolderIconPicker.toggle() } label: {
                        FolderIcon(isOpen: false, themeColor: model.preferences.spaceThemes
                                   ? model.coordinator.activeSpace?.color ?? .gray : .gray,
                                   emblem: folderIcon.flatMap { if case .symbol(let symbol) = $0 { .symbol(symbol.rawValue) } else { nil } })
                            .frame(width: FolderIcon.width, height: FolderIcon.height)
                            .frame(width: 38, height: 38)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
                    }
                    .buttonStyle(.plain)
                    .browserKeyboardFocus(cornerRadius: 10)
                    .accessibilityLabel("Choose folder icon")
                    .accessibilityValue(folderIcon?.accessibilityName ?? "No icon")
                    .accessibilityIdentifier("folder.iconPicker")
                    .popover(isPresented: $showingFolderIconPicker, arrowEdge: .bottom) {
                        SpaceIconPicker(selection: $folderIcon, noneTitle: "No icon", noneSymbol: "folder") {
                            showingFolderIconPicker = false
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Folder icon")
                        Text("Optional. Shown on the folder.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack {
            Button("Cancel") { folderEditor = false }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") {
                let success: Bool
                if let editingFolder { success = model.coordinator.renameFolder(editingFolder, to: folderName) }
                else { success = model.coordinator.createFolder(name: folderName, parentID: folderParent, icon: folderIcon) != nil }
                if success { model.save() } else { model.notice = "Could not save folder. Use a name and a parent with room for a subfolder (eight nesting levels maximum)." }
                folderEditor = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }.padding(24).frame(width: 340).browserReducedMotion()
        }
        .onChange(of: folderEditor) { _, value in model.folderEditorIsPresented = value }
        .sheet(isPresented: Binding(get: { iconFolderID != nil }, set: { if !$0 { iconFolderID = nil } })) {
            if let id = iconFolderID, let folder = model.coordinator.folders.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    SpaceIconPicker(selection: Binding(get: { folder.icon }, set: { icon in
                        if model.coordinator.setFolderIcon(id, icon: icon) { model.save() }
                    }), title: "Choose an icon for “\(folder.name)”", noneTitle: "No icon", noneSymbol: "folder") {
                        iconFolderID = nil
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { iconFolderID = nil }.keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 18).padding(.bottom, 16)
                }
            }
        }
        .sheet(isPresented: $model.historyPresented) { HistoryView(model: model) }
        // Clear History from the menu without opening History first.
        .confirmationDialog("Clear history and website data?",
                            isPresented: Binding(get: { model.clearHistoryPresented && !model.historyPresented },
                                                 set: { model.clearHistoryPresented = $0 })) {
            ClearHistoryButtons(model: model)
        } message: {
            Text(ClearHistoryButtons.message)
        }
        .alert("Clear cache and cookies for \(model.siteDataClearRequest ?? "this website")?",
               isPresented: Binding(get: { model.siteDataClearRequest != nil }, set: { if !$0 { model.siteDataClearRequest = nil } })) {
            Button("Clear", role: .destructive) {
                if let host = model.siteDataClearRequest { Task { await model.clearSiteData(host) } }
            }
            Button("Cancel", role: .cancel) { model.siteDataClearRequest = nil }
        } message: {
            Text(SiteControlsPanel.clearSiteDataMessage)
        }
        .onDisappear {
            model.cancelWindowInteractions()
            endDrag()
            model.cancelSpaceSwipePresentation()
            model.folderEditorIsPresented = false
            model.save()
            model.webViews.discardAll()
        }
        .browserReducedMotion()
    }

    var sidebar: some View {
        let showsFavorites = !model.favorites.isEmpty || revealDropSections
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                navigationControls
                addressBar.background(dropArea("address"))
            }
            .padding(.bottom, 16)
            // Keep a stable layout/gesture identity. Animate the actual reserved
            // height and spacing, not just the target's drawing.
            favoritesSection
                .frame(height: showsFavorites ? favoritesViewportHeight : 0, alignment: .top)
                .clipped()
                .opacity(showsFavorites ? 1 : 0)
                .padding(.bottom, showsFavorites ? 16 : 0)
                .allowsHitTesting(showsFavorites)
                .accessibilityHidden(!showsFavorites)
            spacePager
            #if DEBUG
            if model.isTesting {
                HStack(spacing: 0) {
                    Text(testRuntimeValue)
                        .font(.caption2)
                    // Count actions, not just final state: two unintended toggles
                    // would otherwise look like an unchanged folder in a UI test.
                    Text("\(folderToggleActionCount)").font(.caption2)
                        .accessibilityIdentifier("test.folderToggles")
                        .frame(width: 1, height: 1)
                }
                .padding(.top, 16)
            }
            #endif
            sidebarFooter
                .padding(.top, 16)
        }
        .animation(folderDragAnimation, value: revealDropSections)
        .padding(.horizontal, sidebarAutoHides ? 5 : 2)
        .padding(.top, sidebarAutoHides ? 3 : 0)
        .padding(.bottom, sidebarAutoHides ? 17 : 14)
        .frame(width: model.sidebarWidth + (sidebarAutoHides ? 3 : 0))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Tab") { model.perform(.presentCommandBar(.newTab)) }
            // A private window has no saved pages, folders or other Spaces.
            if !model.isPrivate {
                Button("New Folder") { editFolder(nil, parent: nil) }
                // One per Space: a second would list the same pull requests.
                if let space = model.coordinator.activeSpace,
                   !model.coordinator.tabStore.hasLiveFolder(.githubPullRequests, in: space.id) {
                    Button("GitHub Live Folder") { model.addGitHubLiveFolder() }
                        .help("A folder of your open pull requests on GitHub, kept up to date")
                }
                Divider()
                Button("New Space…") { model.perform(.newSpace) }
                if let space = model.coordinator.activeSpace { SpaceActions(model: model, space: space) }
            }
        }
        .background(SpaceSwipeMonitor(model: model,
            enabled: model.preferences.spaceSwipes && sidebarVisible && hiddenDragItemID == nil && resizeStartWidth == nil && !folderEditor))
        .background {
            if let landing = dragLanding, landingLayoutReady {
                Color.clear.preference(key: SidebarFrames.self, value: [.landingLayout(landing.id): .zero])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("browser.sidebar")
        .coordinateSpace(name: "sidebarReordering")
        .onContinuousHover(coordinateSpace: .named("sidebarReordering")) { phase in
            switch phase {
            case .active(let point): sidebarPointer.location = point
            case .ended: sidebarPointer.location = nil
            }
            refreshFolderPanelHover()
        }
        .overlay(alignment: .topLeading) {
            crossSectionPreview
                .transition(.identity)
                .transaction { $0.animation = nil }
            landingPreview
                .transition(.identity)
        }
        .task(id: dragLanding?.id) {
            guard let id = dragLanding?.id else { return }
            // First commit the order and remove preview offsets atomically.
            // Then animate collapsing unused sections and measure that layout.
            await Task.yield()
            guard !Task.isCancelled, dragLanding?.id == id else { return }
            withAnimation(folderDragAnimation) {
                revealDropSections = false
                landingLayoutReady = true
            }
        }
        .onPreferenceChange(SidebarFrames.self) { snapshot in
            var frames: [UUID: CGRect] = [:]
            var headers: [UUID: CGRect] = [:]
            var sections: [Bool: CGRect] = [:]
            var areas: [String: CGRect] = [:]
            for (key, frame) in snapshot {
                switch key {
                case .item(let id): frames[id] = frame
                case .folderHeader(let id): headers[id] = frame
                case .section(let favorites): sections[favorites] = frame
                case .dropArea(let name): areas[name] = frame
                case .landingLayout: break
                }
            }
            tabFrames = frames
            folderHitFrames = headers
            sectionFrames = sections
            dropAreas = areas
            refreshFolderPanelHover()
            if let landing = dragLanding, snapshot[.landingLayout(landing.id)] != nil {
                settleDragLanding(frames: frames, sections: sections, areas: areas)
            }
            guard draggingTab != nil, dragSourceItem != nil, dragLanding == nil else { return }
            // Rebuild hit testing only after ALL measurements from this layout
            // pass agree; cross-folder moves change headers and ends together.
            frozenFrames = frames
            guard !tabDragIsOverContent else { return }
            // Insertion previews can move a header underneath a stationary
            // pointer. Re-resolve its folder before rebuilding sibling order.
            updateFolderHover(at: dragPoint)
            refreshCurrentDrag()
        }
        .onChange(of: dragGestureItemID) { _, id in
            if id == nil {
                cancelledGestureItemID = nil
                Task { @MainActor in
                    await Task.yield()
                    if dragGestureItemID == nil, let item = dragSourceItem {
                        model.cancelSplitPreview()
                        finishDrag(item: item)
                    }
                }
            }
            else { folderBounceEvent = nil }
        }
        .onChange(of: model.coordinator.activeSpaceID) { _, _ in
            cancelledGestureItemID = dragGestureItemID
            endDrag()
            folderBounceEvent = nil
            hoveredTab = nil
            hoveredFolder = nil
            hoveredFolderGroups = []
            focusedSidebarControl = nil
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { folderBounceEvent = nil }
        }
        .onDisappear {
            sidebarPointer.location = nil
            hoveredFolderGroups = []
            folderBounceEvent = nil
            endDrag()
        }
    }

    func spaceContents(for space: BrowserSpace) -> some View {
        let active = space.id == model.coordinator.activeSpaceID
        let items = sidebarItems(in: space.id)
        let pinIDs = model.coordinator.tabStore.pinnedItems(in: space.id, parentID: nil).map(\.id)
        let pinPreview = SidebarSavedSectionPreview(section: .pinned, itemIDs: pinIDs,
            draggingItemID: active && dragSourceItem != nil ? draggingTab : nil,
            isTargeted: destinationSection(at: dragPoint) == .pinned)
        let showsPins = !pinIDs.isEmpty || (active && revealDropSections)
        let selection = model.coordinator.session.selectionBySpace[space.id]
        return VStack(alignment: .leading, spacing: 16) {
            if model.isPrivate {
                PrivateBrowsingBadge(name: space.name)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(space.name)
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                    .contextMenu {
                        SpaceActions(model: model, space: space)
                        Button("New Space…") { model.perform(.newSpace) }
                    }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    // Pins and Today share a scroll region: many persistent pins
                    // must not push Today or New Tab outside the reachable sidebar.
                    // These rows include animated zero-height drop targets.
                    // Measure the complete stack: lazy visibility estimates can
                    // skip the leading collapsed rows and the controls after
                    // them, and leave stale destination geometry during a drop.
                    VStack(alignment: .leading, spacing: 0) {
                        // One identity domain: moving the same UUID between two
                        // sibling ForEach collections can retain a stale lazy row.
                        ForEach(items) { item in
                            let retainsSourceSlot = pinPreview.sourceSlotID != nil && pinPreview.sourceSlotID == item.draggableID
                            let vacatesRow = !retainsSourceSlot && vacatesSourceRow(item)
                            let hidesBoundary = !showsPins && item.isPinsBoundary
                            // Keep one layout container per item while its
                            // reserved height changes during dragging.
                            VStack(alignment: .leading, spacing: 0) {
                            switch item {
                            case .pinnedStart:
                                VStack(spacing: 0) {
                                    if pinPreview.showsEmptyTarget && pinPreview.sourceSlotID == nil {
                                        emptySavedSectionTarget("Pins", preview: pinPreview,
                                            identifier: "sidebar.pinned.dropTarget")
                                    } else {
                                        Color.clear.frame(height: 4)
                                    }
                                }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: showsPins ? (pinPreview.showsEmptyTarget && pinPreview.sourceSlotID == nil ? pinPreview.height : 4) : 0, alignment: .top)
                                    .clipped()
                                    .background(dropArea("pinned"))
                                    .accessibilityHidden(!showsPins)
                            case .pinnedEnd:
                                Color.clear.frame(height: showsPins ? (active && !pinIDs.isEmpty && needsPinInsertionSpace(in: nil) ? 38 : 4) : 0)
                                    .background(dropArea("pinnedEnd"))
                                    .accessibilityHidden(true)
                            case .divider:
                                HStack(spacing: 6) {
                                    VStack { Divider() }
                                    if active && !model.todayTabs.isEmpty {
                                        // Clears Today only; pins and folders stay, and
                                        // Reopen Closed Tab brings pages back.
                                        Button { model.perform(.clearTodayTabs) } label: {
                                            Label("Clear", systemImage: "arrow.down")
                                                .labelStyle(.titleAndIcon)
                                                .font(.system(size: 11, weight: .medium))
                                                .padding(.horizontal, 6).frame(height: 17)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .browserKeyboardFocus(cornerRadius: 5)
                                        .disabled(!model.canPerform(.clearTodayTabs))
                                        .help("Close all Today tabs in this Space. Pins and Favorites stay.")
                                        .accessibilityLabel("Clear Today Tabs")
                                        .accessibilityIdentifier("sidebar.clearToday")
                                    }
                                }
                                // The same 17 points as the plain divider it replaces.
                                .frame(height: 17)
                                .background(dropArea("divider"))
                            case .newTab:
                                newTabButton
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(dropArea("regular"))
                            case .tab(let tab, let depth):
                                tabRow(tab, selected: tab.id == selection, requestsArtwork: active)
                                    .padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                            case .folder(let folder, let depth):
                                folderRow(folder).padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                            case .liveStatus(let folder, let depth):
                                if let feed = model.pullRequests {
                                    LiveFolderStatusRow(model: model, feed: feed, hasPins: folderHasChildren(folder.id, in: folder.spaceID))
                                        .padding(.leading, CGFloat(min(depth, 8)) * 12)
                                        .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                                }
                            case .folderEnd(let folder, let depth):
                                Color.clear.frame(height: folderPreview(folder).footerHeight)
                                    .padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                                    .anchorPreference(key: FolderBoundaries.self, value: .bounds) {
                                        [.end(folder.id): $0]
                                    }
                                    .offset(previewOffset(folder.id))
                                    .animation(dragSourceItem == nil || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(folder.id))
                                    .background(dropArea("folderEnd.\(folder.id)"))
                                    .accessibilityHidden(true)
                            }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay {
                                if retainsSourceSlot {
                                    // The last lifted pin/folder leaves its existing
                                    // row as the target, even after leaving Pins.
                                    emptySavedSectionTarget("Pins", preview: pinPreview,
                                        identifier: "sidebar.pinned.dropTarget")
                                }
                            }
                            // Keep the gesture mounted while neighboring rows fill
                            // its old space. An emptied section retains one target.
                            .transition(.opacity)
                            .frame(height: hidesBoundary ? 0 : (retainsSourceSlot ? pinPreview.height : (vacatesRow ? 0 : nil)))
                            .padding(.bottom, hidesBoundary || vacatesRow || item.id == items.last?.id ? 0 : SidebarFolderBounce.rowSpacing)
                            .animation(folderDragAnimation, value: vacatesRow)
                            .id(item.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .backgroundPreferenceValue(FolderBoundaries.self) { anchors in
                        pinnedGroupBackgrounds(anchors: anchors)
                    }
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier(active ? "sidebar.tabs" : "sidebar.tabs.preview.\(space.id)")
                .background(sectionFrame(favorites: false))
                .task(id: active ? model.sidebarReveal?.id : nil) {
                    guard let request = model.sidebarReveal, request.spaceID == space.id else { return }
                    // Let the moved row enter the destination layout first.
                    await Task.yield()
                    guard !Task.isCancelled, model.coordinator.activeSpaceID == space.id,
                          model.sidebarReveal?.id == request.id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        scroll.scrollTo(request.itemID, anchor: .center)
                    }
                    model.sidebarReveal = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Neighboring pages keep the same rows and native scroll view when
        // selected, but cannot receive input or publish active drag geometry.
        .disabled(!active)
        .allowsHitTesting(active && model.spaceSwipeProgress == 0 && !model.spaceSwipeIsSettling)
        .accessibilityHidden(!active)
        .transformPreference(SidebarFrames.self) { if !active { $0 = [:] } }
    }

    var spacePager: some View {
        GeometryReader { geometry in
            let progress = reduceMotion ? 0 : model.spaceSwipeProgress
            let activeIndex = model.activeSpaceIndex
            let range = SpaceNavigation.sidebarPageRange(current: activeIndex, count: model.coordinator.spaces.count)
            ZStack(alignment: .topLeading) {
                // Identity belongs to the Space, not to its role as the active
                // page or preview. A completed swipe only changes offsets; it
                // never replaces the arriving page with a fresh lazy list.
                ForEach(Array(model.coordinator.spaces.enumerated()).filter { range.contains($0.offset) }, id: \.element.id) { index, space in
                    spaceContents(for: space)
                        .offset(x: CGFloat(SpaceNavigation.sidebarPagePosition(index: index, current: activeIndex,
                            progress: progress)) * geometry.size.width)
                        .transition(.identity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            // Reordering footer icons changes page indices, not selection.
            // Snap those offscreen positions so the footer's drop animation
            // cannot sweep neighboring tabs/folders through the active page.
            // A real Space swipe keeps the same catalog and still animates.
            .animation(nil, value: model.coordinator.spaces.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var sidebarFooter: some View {
        SpaceFooter(model: model)
    }

}
